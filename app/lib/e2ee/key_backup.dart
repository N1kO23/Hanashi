import 'dart:convert';
import 'dart:typed_data';

import 'content.dart';
import 'primitives.dart';

/// Encrypts message content keys for the account's key backup on the
/// server, so a device that joins later can read the history. Only the
/// user's verified devices hold the backup secret; the server cannot read
/// or forge entries.
///
/// Entry: AES-256-GCM under HKDF(backup secret, "hanashi-backup-v1"), with
/// the message ID as associated data, so an entry cannot be moved to
/// another message.
class KeyBackupCipher {
  KeyBackupCipher._(this._key);

  final Uint8List _key;

  static Future<KeyBackupCipher> forSecret(List<int> backupSecret) async =>
      KeyBackupCipher._(await hkdf(backupSecret, 'hanashi-backup-v1'));

  Future<String> seal(String messageId, ContentKey key) async =>
      base64.encode(await aeadSeal(_key, key.toBytes(), aad: _aad(messageId)));

  /// Throws [DecryptionFailed] for an entry made with another secret or for
  /// another message.
  Future<ContentKey> open(String messageId, String entry) async {
    final Uint8List sealed;
    try {
      sealed = base64.decode(entry);
    } on FormatException {
      throw const DecryptionFailed('Malformed backup entry');
    }
    return ContentKey.fromBytes(await aeadOpen(_key, sealed, aad: _aad(messageId)));
  }

  static List<int> _aad(String messageId) => utf8.encode('hanashi-backup-v1|$messageId');
}
