import 'dart:convert';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'padding.dart';
import 'primitives.dart';

/// What the MLS application message carries for one chat message: the key
/// that encrypts its content, and a hash binding that ciphertext.
class ContentKey {
  const ContentKey({required this.key, required this.ctHash});

  final Uint8List key;
  final Uint8List ctHash;

  Map<String, Object?> toJson() => {'k': base64.encode(key), 'h': base64.encode(ctHash)};

  Uint8List toBytes() => utf8.encode(jsonEncode(toJson()));

  factory ContentKey.fromBytes(List<int> bytes) {
    final map = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    return ContentKey(key: base64.decode(map['k'] as String), ctHash: base64.decode(map['h'] as String));
  }

  /// Throws [FormatException] unless [json] is a 32-byte key and hash.
  factory ContentKey.fromJson(Object? json) {
    final (k, h) = json is Map ? (json['k'], json['h']) : (null, null);
    if (k is! String || h is! String) throw FormatException('Not a content key', json);
    final key = ContentKey(key: base64.decode(k), ctHash: base64.decode(h));
    if (key.key.length != 32 || key.ctHash.length != 32) throw FormatException('Not a content key', json);
    return key;
  }
}

/// The keys of a chat's earlier messages, as shared with someone just added
/// (see [Envelope.historyType]): `{"keys": {messageId: {"k", "h"}}}`.
Uint8List encodeHistoryKeys(Map<String, ContentKey> keys) => utf8.encode(
  jsonEncode({
    'keys': {for (final MapEntry(:key, :value) in keys.entries) key: value.toJson()},
  }),
);

/// Throws [FormatException] for anything [encodeHistoryKeys] does not make.
Map<String, ContentKey> decodeHistoryKeys(List<int> bytes) {
  final json = jsonDecode(utf8.decode(bytes));
  final keys = json is Map ? json['keys'] : null;
  if (keys is! Map) throw const FormatException('Not a history share');
  final out = <String, ContentKey>{};
  for (final MapEntry(:key, :value) in keys.entries) {
    if (key is! String || !isUlid(key)) throw FormatException('Not a message ID', key);
    out[key] = ContentKey.fromJson(value);
  }
  return out;
}

/// Content is not padded past this, so that it still fits in an envelope's
/// body (64 KiB, with `ct` in base64 and the MLS message beside it).
const maxPaddedContent = 47 << 10;

/// Encrypts a message's content (`{type, body}`) under a fresh random key,
/// padded so that the server sees only roughly how long it is.
Future<({ContentKey contentKey, Uint8List ct})> sealContent(Map<String, Object?> inner, Uint8List aad) async {
  final key = randomBytes(32);
  final ct = await aeadSeal(key, encodePaddedJson(inner, max: maxPaddedContent), aad: aad);
  return (contentKey: ContentKey(key: key, ctHash: await sha256(ct)), ct: ct);
}

/// Throws [DecryptionFailed] if [ct] does not match the key and hash.
Future<Map<String, Object?>> openContent(ContentKey contentKey, Uint8List ct, Uint8List aad) async {
  final hash = await sha256(ct);
  if (!_equal(hash, contentKey.ctHash)) throw const DecryptionFailed('Content does not match its key');
  final plain = await aeadOpen(contentKey.key, ct, aad: aad);
  return (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
}

/// The message [wire] carries, decrypted with its content key (from MLS or
/// from the key backup). Throws [DecryptionFailed] if they do not match.
Future<Envelope> openMessage(EncryptedEnvelope wire, ContentKey key) async {
  final inner = await openContent(key, wire.ct, wire.contentAad);
  // What this device makes for itself (a line saying the group was renamed,
  // say) is never taken from someone else.
  if (Envelope.localTypes.contains(inner['type'])) {
    return Envelope(
      id: wire.id,
      conv: wire.conv,
      from: wire.from,
      ts: wire.ts,
      type: Envelope.refusedType,
      body: const {},
    );
  }
  return Envelope.fromJson({
    'v': Envelope.version,
    'id': wire.id,
    'conv': wire.conv,
    'from': wire.from,
    'ts': wire.ts,
    'type': inner['type'],
    'body': inner['body'],
  });
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
