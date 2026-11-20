import 'dart:convert';
import 'dart:typed_data';

import 'ulid.dart';
import 'user_id.dart';

/// A message as it travels: end-to-end encrypted (envelope version 3).
///
/// `mls` is an MLS application message carrying the content key; `ct` is the
/// content ([Envelope]'s type and body) encrypted with that key. The server
/// sees only this outer header.
///
/// [type] is [chat] for what belongs in a conversation's history, or [control]
/// for what only the devices of its members act on (a profile key, say): built
/// the same way, but the server leaves it out of history.
class EncryptedEnvelope {
  const EncryptedEnvelope({
    required this.id,
    required this.conv,
    required this.from,
    required this.device,
    required this.ts,
    required this.epoch,
    required this.mls,
    required this.ct,
    this.type = chat,
  });

  static const version = 3;
  static const chat = 'mls.app';
  static const control = 'mls.control';

  final String type;
  final String id;
  final String conv;
  final String from;

  /// The sending device.
  final String device;
  final int ts;

  /// MLS epoch the message was encrypted in.
  final int epoch;
  final Uint8List mls;
  final Uint8List ct;

  /// Associated data binding the content ciphertext to this header.
  Uint8List get contentAad => utf8.encode('hanashi-msg-v2|$id|$conv|$from|$device');

  /// Parses and validates; throws [FormatException]. Mirrors the Go server.
  factory EncryptedEnvelope.fromJson(Map<String, Object?> json) {
    if (json['v'] != version) throw const FormatException('v must be 3: messages must be end-to-end encrypted');
    final id = json['id'], conv = json['conv'], from = json['from'], device = json['device'], ts = json['ts'];
    if (id is! String || !isUlid(id)) throw FormatException('id must be a ULID', id);
    if (conv is! String || conv.isEmpty) throw FormatException('conv must be a string', conv);
    if (from is! String || UserId.tryParse(from) == null) throw FormatException('from must be name@host', from);
    if (device is! String || !isUlid(device)) throw FormatException('device must be a device ID', device);
    if (ts is! int) throw FormatException('ts must be an int', ts);
    final type = json['type'];
    if (type != chat && type != control) throw const FormatException('type must be "mls.app" or "mls.control"');
    final body = json['body'];
    if (body is! Map) throw const FormatException('body must be an object');
    final epoch = body['epoch'];
    if (epoch is! int || epoch < 0) throw FormatException('body.epoch must be a non-negative int', epoch);
    Uint8List decode(String key) {
      final value = body[key];
      try {
        final bytes = value is String ? base64.decode(value) : null;
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } on FormatException {
        // Reported below.
      }
      throw FormatException('body.$key must be non-empty base64', value);
    }

    return EncryptedEnvelope(
      id: id,
      conv: conv,
      from: from,
      device: device,
      ts: ts,
      epoch: epoch,
      mls: decode('mls'),
      ct: decode('ct'),
      type: type as String,
    );
  }

  Map<String, Object?> toJson() => {
    'v': version,
    'id': id,
    'conv': conv,
    'from': from,
    'device': device,
    'ts': ts,
    'type': type,
    'body': {'epoch': epoch, 'mls': base64.encode(mls), 'ct': base64.encode(ct)},
  };
}
