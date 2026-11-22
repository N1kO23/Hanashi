import 'dart:convert';
import 'dart:typed_data';

import '../data/remote/api_client.dart';
import 'padding.dart';
import 'primitives.dart';

/// Seals the user's account data: small blobs (such as their own profile
/// picture) that all of their devices share through the server. The key
/// comes from the backup secret, which every verified device of the user
/// holds and the server never sees.
class AccountDataCipher {
  AccountDataCipher._(this._key, this._userId);

  final Uint8List _key;
  final String _userId;

  static Future<AccountDataCipher> forSecret(List<int> backupSecret, String userId) async =>
      AccountDataCipher._(await hkdf(backupSecret, 'hanashi-account-data-v1'), userId);

  Future<String> seal(String name, Map<String, Object?> value) async =>
      base64.encode(await aeadSeal(_key, encodePaddedJson(value), aad: _aad(name)));

  /// Throws [DecryptionFailed] for data sealed with another secret (an older
  /// identity), for another user or under another name.
  Future<Map<String, Object?>> open(String name, String sealed) async {
    final Uint8List bytes;
    try {
      bytes = base64.decode(sealed);
    } on FormatException {
      throw const DecryptionFailed('Malformed account data');
    }
    final plain = await aeadOpen(_key, bytes, aad: _aad(name));
    return (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
  }

  List<int> _aad(String name) => utf8.encode('hanashi-account-data-v1|$_userId|$name');
}

/// One of the user's account data blobs as a device last read it.
class AccountDataRead {
  const AccountDataRead(this.value, {required this.version, required this.sequence});

  /// Null: none yet, or sealed under an earlier identity.
  final Map<String, Object?>? value;

  /// The server's version, to change it from.
  final int version;

  /// Counts the changes inside the sealed blob: this one the server cannot
  /// touch, so it can be checked to never go back.
  final int sequence;
}

/// Reads and changes account data so that nothing gets lost: a device changes
/// a blob only from the version it read, and the server cannot serve an older
/// one unnoticed, as each carries a sealed [AccountDataRead.sequence].
class AccountData {
  AccountData({required this.api, required this.cipher, required this.loadSequence, required this.saveSequence});

  final ApiClient api;
  final AccountDataCipher cipher;

  /// The highest sequence this device saw of a blob, 0 for none, and keeping it.
  final Future<int> Function(String name) loadSequence;
  final Future<void> Function(String name, int sequence) saveSequence;

  static const _attempts = 8;

  /// Null if the server shows one older than this device has seen, or none at
  /// all: what the device has stays (it comes back, or is overwritten by a newer
  /// change).
  Future<AccountDataRead?> read(String name) async {
    final stored = await api.accountData(name);
    final seen = await loadSequence(name);
    if (stored == null) return seen > 0 ? null : AccountDataRead(null, version: 0, sequence: seen);
    final Map<String, Object?> opened;
    try {
      opened = await cipher.open(name, stored.data);
    } on DecryptionFailed {
      return AccountDataRead(null, version: stored.version, sequence: seen); // An earlier identity's: gone with it.
    } on FormatException {
      return AccountDataRead(null, version: stored.version, sequence: seen);
    }
    final (sequence, data) = (opened['n'], opened['data']);
    if (sequence is! int || data is! Map) return AccountDataRead(null, version: stored.version, sequence: seen);
    if (sequence < seen) return null;
    await saveSequence(name, sequence);
    return AccountDataRead(data.cast<String, Object?>(), version: stored.version, sequence: sequence);
  }

  /// Writes what [change] makes of the blob as it is on the server (null: there
  /// is none); with another device changing it meanwhile, it runs again on
  /// what that one wrote. It returns what was written; if [change] returns
  /// null, nothing is. Throws an `ApiException` when offline.
  Future<Map<String, Object?>?> update(
    String name,
    Map<String, Object?>? Function(Map<String, Object?>? current) change,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final seen = await loadSequence(name);
      final current = await read(name);
      final stored =
          current ?? AccountDataRead(null, version: (await api.accountData(name))?.version ?? 0, sequence: seen);
      final next = change(stored.value);
      if (next == null) return null;
      final sequence = (current?.sequence ?? seen) + 1;
      try {
        await api.putAccountData(name, await cipher.seal(name, {'n': sequence, 'data': next}), version: stored.version);
        await saveSequence(name, sequence);
        return next;
      } on ApiException catch (e) {
        if (e.code != 'version_conflict' || attempt >= _attempts) rethrow;
      }
    }
  }
}
