/// Cryptographic building blocks for end-to-end encryption, on top of
/// package:cryptography. Group messaging itself uses MLS (package:openmls);
/// these cover identity signatures, secret storage and key backup.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

final _random = Random.secure();
final _aesGcm = AesGcm.with256bits();
final _ed25519 = Ed25519();
final _sha256 = Sha256();

Uint8List randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

Future<Uint8List> sha256(List<int> data) async => Uint8List.fromList((await _sha256.hash(data)).bytes);

/// HKDF-SHA256 with an empty salt.
Future<Uint8List> hkdf(List<int> secret, String info, {int length = 32}) async {
  final key = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: length,
  ).deriveKey(secretKey: SecretKey(secret), info: utf8.encode(info));
  return Uint8List.fromList(await key.extractBytes());
}

/// Thrown when a ciphertext fails authentication: wrong key or tampered data.
class DecryptionFailed implements Exception {
  const DecryptionFailed([this.message = 'Decryption failed']);

  final String message;

  @override
  String toString() => message;
}

/// AES-256-GCM with a random 96-bit nonce. Output: nonce ‖ ciphertext ‖ tag.
Future<Uint8List> aeadSeal(List<int> key, List<int> plaintext, {List<int> aad = const []}) async {
  final box = await _aesGcm.encrypt(plaintext, secretKey: SecretKey(key), nonce: randomBytes(12), aad: aad);
  return Uint8List.fromList(box.concatenation());
}

Future<Uint8List> aeadOpen(List<int> key, List<int> sealed, {List<int> aad = const []}) async {
  if (sealed.length < 12 + 16) {
    throw const DecryptionFailed('Ciphertext is too short');
  }
  try {
    final box = SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16);
    return Uint8List.fromList(await _aesGcm.decrypt(box, secretKey: SecretKey(key), aad: aad));
  } on SecretBoxAuthenticationError {
    throw const DecryptionFailed();
  }
}

// Recovery key

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// 32 random bytes the user writes down. Displayed as Crockford base32 with a
/// 2-byte checksum, in groups of four characters.
class RecoveryKey {
  RecoveryKey(this.bytes) : assert(bytes.length == 32);

  factory RecoveryKey.generate() => RecoveryKey(randomBytes(32));

  final Uint8List bytes;

  static Future<List<int>> _checksum(List<int> bytes) async => (await sha256(bytes)).sublist(0, 2);

  Future<String> encode() async {
    final data = [...bytes, ...await _checksum(bytes)];
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final byte in data) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_crockford[(value >> bits) & 31]);
      }
      value &= (1 << bits) - 1;
    }
    if (bits > 0) out.write(_crockford[(value << (5 - bits)) & 31]);
    final chars = out.toString();
    return [for (var i = 0; i < chars.length; i += 4) chars.substring(i, min(i + 4, chars.length))].join(' ');
  }

  /// Accepts any case, spaces and dashes, and the usual Crockford look-alikes
  /// (O->0, I/L->1). Throws [FormatException] on a typo.
  static Future<RecoveryKey> parse(String input) async {
    final cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    var bits = 0, value = 0;
    final out = <int>[];
    for (final char in cleaned.split('')) {
      final digit = _crockford.indexOf(char);
      if (digit < 0) {
        throw const FormatException('The recovery key contains characters it cannot have');
      }
      value = (value << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((value >> bits) & 0xff);
      }
      value &= (1 << bits) - 1;
    }
    if (out.length != 34) {
      throw const FormatException('The recovery key has the wrong length');
    }
    final key = out.sublist(0, 32);
    final checksum = await _checksum(key);
    if (checksum[0] != out[32] || checksum[1] != out[33]) {
      throw const FormatException('The recovery key has a typo');
    }
    return RecoveryKey(Uint8List.fromList(key));
  }
}

// Secret storage

/// What a verified device holds, and what secret storage keeps on the server
/// encrypted with the recovery key.
class AccountSecrets {
  const AccountSecrets({required this.identitySeed, required this.backupSecret});

  /// Ed25519 seed of the user's identity key.
  final Uint8List identitySeed;

  /// Symmetric key for the message key backup.
  final Uint8List backupSecret;

  factory AccountSecrets.generate() => AccountSecrets(identitySeed: randomBytes(32), backupSecret: randomBytes(32));

  String toJson() => jsonEncode({'identity': base64.encode(identitySeed), 'backup': base64.encode(backupSecret)});

  factory AccountSecrets.fromJson(String json) {
    final map = (jsonDecode(json) as Map).cast<String, Object?>();
    return AccountSecrets(
      identitySeed: base64.decode(map['identity'] as String),
      backupSecret: base64.decode(map['backup'] as String),
    );
  }
}

/// Encrypts [secrets] with the recovery key, bound to [userId].
Future<String> sealSecrets(RecoveryKey recoveryKey, String userId, AccountSecrets secrets) async {
  final key = await hkdf(recoveryKey.bytes, 'hanashi-ssss-v1');
  final sealed = await aeadSeal(key, utf8.encode(secrets.toJson()), aad: utf8.encode(userId));
  return jsonEncode({'v': 1, 'data': base64.encode(sealed)});
}

/// Throws [DecryptionFailed] for a wrong recovery key.
Future<AccountSecrets> openSecrets(RecoveryKey recoveryKey, String userId, String blob) async {
  final map = (jsonDecode(blob) as Map).cast<String, Object?>();
  if (map['v'] != 1) {
    throw const FormatException('Unknown secret storage version');
  }
  final key = await hkdf(recoveryKey.bytes, 'hanashi-ssss-v1');
  final plain = await aeadOpen(key, base64.decode(map['data'] as String), aad: utf8.encode(userId));
  return AccountSecrets.fromJson(utf8.decode(plain));
}

// Identity

/// The user's Ed25519 identity key pair, derived from [AccountSecrets.identitySeed].
class IdentityKeyPair {
  IdentityKeyPair._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;

  String get publicKeyBase64 => base64.encode(publicKey);

  static Future<IdentityKeyPair> fromSeed(List<int> seed) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return IdentityKeyPair._(keyPair, Uint8List.fromList(publicKey.bytes));
  }

  Future<Uint8List> sign(List<int> message) async =>
      Uint8List.fromList((await _ed25519.sign(message, keyPair: _keyPair)).bytes);

  /// Signs the record that marks one of the user's devices as verified.
  Future<String> signDevice({required String userId, required String deviceId, required String mlsSigKey}) async =>
      base64.encode(await sign(deviceRecordMessage(userId, deviceId, mlsSigKey)));
}

Future<bool> verifySignature({required List<int> publicKey, required List<int> message, required List<int> signature}) {
  return _ed25519.verify(
    message,
    signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
  );
}

/// Whether [device] carries a valid signature by [identityKey] (base64).
Future<bool> isDeviceVerified({
  required String identityKey,
  required String userId,
  required DeviceKeyInfo device,
}) async {
  final signature = device.signature;
  if (signature == null) return false;
  try {
    return await verifySignature(
      publicKey: base64.decode(identityKey),
      message: deviceRecordMessage(userId, device.deviceId, device.mlsSigKey),
      signature: base64.decode(signature),
    );
  } on FormatException {
    return false;
  }
}

/// Human-comparable form of an identity key, e.g. "4K7Q M2XD ...".
Future<String> identityFingerprint(String identityKeyBase64) async {
  final digest = await sha256(base64.decode(identityKeyBase64));
  final key = await RecoveryKey(digest).encode();
  return key.split(' ').take(8).join(' ');
}
