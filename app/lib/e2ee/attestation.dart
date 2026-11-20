import 'dart:convert';

import 'primitives.dart';

/// A user's signed statement about a contact's identity key: verified by
/// comparing emoji, or (with no key) no longer verified. It is stored on the
/// server so all of the user's devices know it. Only the user's own identity
/// key can make one, so the server cannot forge it; and devices apply only
/// statements newer than the last one they applied, so it cannot undo one by
/// leaving it out or serving an older one.
class Attestation {
  const Attestation({required this.userId, required this.identityKey, required this.at});

  final String userId;

  /// The verified key; null once the user withdrew the verification (they
  /// accepted a new key without verifying it).
  final String? identityKey;

  /// When it was made (milliseconds since the epoch); always later than the
  /// statement it replaces.
  final int at;

  static List<int> _message(String userId, String? identityKey, int at) =>
      utf8.encode('hanashi-verified-v1\n$userId\n${identityKey ?? ''}\n$at');

  Future<String> sign(IdentityKeyPair signer) async => jsonEncode({
    'user': userId,
    'identityKey': identityKey,
    'at': at,
    'signature': base64.encode(await signer.sign(_message(userId, identityKey, at))),
  });

  /// The statement in [data] about [userId], if [signerKey] (base64) signed
  /// it; otherwise null.
  static Future<Attestation?> open(String data, {required String userId, required String signerKey}) async {
    try {
      final map = (jsonDecode(data) as Map).cast<String, Object?>();
      final key = map['identityKey'];
      final at = map['at'];
      final signature = map['signature'];
      if (map['user'] != userId || at is! int || signature is! String) return null;
      if (key != null && (key is! String || key.isEmpty)) return null; // Empty would read as "withdrawn".
      final valid = await verifySignature(
        publicKey: base64.decode(signerKey),
        message: _message(userId, key as String?, at),
        signature: base64.decode(signature),
      );
      return valid ? Attestation(userId: userId, identityKey: key, at: at) : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
