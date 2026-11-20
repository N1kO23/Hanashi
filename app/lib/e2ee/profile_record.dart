import 'dart:convert';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'padding.dart';
import 'primitives.dart';

/// A user's profile as the server keeps it: one record per user, encrypted
/// with their profile key and signed with their identity key. The server can
/// neither read it nor forge it, and devices refuse versions older than the
/// newest they have seen, so it cannot bring an old one back either.
class ProfileRecord {
  const ProfileRecord({required this.user, required this.version, required this.ct, required this.signature});

  final String user;
  final int version;
  final Uint8List ct;
  final Uint8List signature;

  static List<int> _aad(String user, int version) => utf8.encode('hanashi-profile-v1|$user|$version');

  static Future<List<int>> _message(String user, int version, List<int> ct) async =>
      utf8.encode('hanashi-profile-v1\n$user\n$version\n${base64.encode(await sha256(ct))}');

  static Future<ProfileRecord> seal(
    ProfileDocument document, {
    required String user,
    required int version,
    required List<int> key,
    required IdentityKeyPair signer,
  }) async {
    final ct = await aeadSeal(key, encodePaddedJson(document.toJson()), aad: _aad(user, version));
    return ProfileRecord(
      user: user,
      version: version,
      ct: ct,
      signature: await signer.sign(await _message(user, version, ct)),
    );
  }

  /// Whether [identityKey] (base64) signed this record.
  Future<bool> isSignedBy(String identityKey) async => verifySignature(
    publicKey: base64.decode(identityKey),
    message: await _message(user, version, ct),
    signature: signature,
  );

  /// Throws [DecryptionFailed] with the wrong key, [FormatException] for
  /// something that is not a profile.
  Future<ProfileDocument> open(List<int> key) async {
    final json = jsonDecode(utf8.decode(await aeadOpen(key, ct, aad: _aad(user, version))));
    if (json is! Map) throw const FormatException('Not a profile');
    return ProfileDocument.fromJson(json.cast<String, Object?>());
  }

  /// Throws [FormatException] for anything else, also for a record of someone
  /// other than [user].
  factory ProfileRecord.fromJson(Map<String, Object?> json, {required String user}) {
    final (who, version, ct, signature) = (json['user'], json['version'], json['ct'], json['signature']);
    if (who != user || version is! int || ct is! String || signature is! String) {
      throw const FormatException('Not a profile record');
    }
    return ProfileRecord(user: user, version: version, ct: base64.decode(ct), signature: base64.decode(signature));
  }

  Map<String, Object?> toJson() => {'version': version, 'ct': base64.encode(ct), 'signature': base64.encode(signature)};
}
