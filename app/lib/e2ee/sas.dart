import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'primitives.dart';

/// The 64 emoji a verification shows, by 6-bit value (the table Matrix uses).
const sasEmoji = <({String emoji, String name})>[
  (emoji: '🐶', name: 'Dog'),
  (emoji: '🐱', name: 'Cat'),
  (emoji: '🦁', name: 'Lion'),
  (emoji: '🐎', name: 'Horse'),
  (emoji: '🦄', name: 'Unicorn'),
  (emoji: '🐷', name: 'Pig'),
  (emoji: '🐘', name: 'Elephant'),
  (emoji: '🐰', name: 'Rabbit'),
  (emoji: '🐼', name: 'Panda'),
  (emoji: '🐓', name: 'Rooster'),
  (emoji: '🐧', name: 'Penguin'),
  (emoji: '🐢', name: 'Turtle'),
  (emoji: '🐟', name: 'Fish'),
  (emoji: '🐙', name: 'Octopus'),
  (emoji: '🦋', name: 'Butterfly'),
  (emoji: '🌷', name: 'Flower'),
  (emoji: '🌳', name: 'Tree'),
  (emoji: '🌵', name: 'Cactus'),
  (emoji: '🍄', name: 'Mushroom'),
  (emoji: '🌏', name: 'Globe'),
  (emoji: '🌙', name: 'Moon'),
  (emoji: '☁️', name: 'Cloud'),
  (emoji: '🔥', name: 'Fire'),
  (emoji: '🍌', name: 'Banana'),
  (emoji: '🍎', name: 'Apple'),
  (emoji: '🍓', name: 'Strawberry'),
  (emoji: '🌽', name: 'Corn'),
  (emoji: '🍕', name: 'Pizza'),
  (emoji: '🎂', name: 'Cake'),
  (emoji: '❤️', name: 'Heart'),
  (emoji: '😀', name: 'Smiley'),
  (emoji: '🤖', name: 'Robot'),
  (emoji: '🎩', name: 'Hat'),
  (emoji: '👓', name: 'Glasses'),
  (emoji: '🔧', name: 'Spanner'),
  (emoji: '🎅', name: 'Santa'),
  (emoji: '👍', name: 'Thumbs up'),
  (emoji: '☂️', name: 'Umbrella'),
  (emoji: '⌛', name: 'Hourglass'),
  (emoji: '⏰', name: 'Clock'),
  (emoji: '🎁', name: 'Gift'),
  (emoji: '💡', name: 'Light bulb'),
  (emoji: '📕', name: 'Book'),
  (emoji: '✏️', name: 'Pencil'),
  (emoji: '📎', name: 'Paperclip'),
  (emoji: '✂️', name: 'Scissors'),
  (emoji: '🔒', name: 'Lock'),
  (emoji: '🔑', name: 'Key'),
  (emoji: '🔨', name: 'Hammer'),
  (emoji: '☎️', name: 'Telephone'),
  (emoji: '🏁', name: 'Flag'),
  (emoji: '🚂', name: 'Train'),
  (emoji: '🚲', name: 'Bicycle'),
  (emoji: '✈️', name: 'Aeroplane'),
  (emoji: '🚀', name: 'Rocket'),
  (emoji: '🏆', name: 'Trophy'),
  (emoji: '⚽', name: 'Ball'),
  (emoji: '🎸', name: 'Guitar'),
  (emoji: '🎺', name: 'Trumpet'),
  (emoji: '🔔', name: 'Bell'),
  (emoji: '⚓', name: 'Anchor'),
  (emoji: '🎧', name: 'Headphones'),
  (emoji: '📁', name: 'Folder'),
  (emoji: '📌', name: 'Pin'),
];

class SasParty {
  const SasParty(this.userId, this.deviceId);

  final String userId;
  final String deviceId;

  @override
  bool operator ==(Object other) =>
      other is SasParty && other.userId == userId && other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(userId, deviceId);

  @override
  String toString() => '$userId/$deviceId';
}

/// A message to send to the other device.
class SasMessage {
  const SasMessage(this.type, this.data);

  final String type;
  final Map<String, Object?> data;
}

/// Message types, sent through device inboxes (`data` always has `txn`).
abstract final class SasType {
  /// Initiator -> the other user's (or own other) devices: `{txn, mode}`.
  static const request = 'verification.request';

  /// Responder -> initiator: `{txn, commitment}` (hash of a key it reveals later).
  static const accept = 'verification.accept';

  /// Both: `{txn, key}`, the initiator's first.
  static const key = 'verification.key';

  /// Both, after their user confirmed the emoji: `{txn, mac}`.
  static const mac = 'verification.mac';

  /// Device verification: the account secrets for the new device, `{txn, data}`.
  static const secrets = 'verification.secrets';

  /// Either: `{txn, reason}`. With `acceptedBy`, another device took the request.
  static const cancel = 'verification.cancel';
}

enum SasState {
  /// Initiator: waiting for a device to accept. Responder: waiting for its user.
  requested,

  /// Exchanging keys.
  exchanging,

  /// Emoji are shown; waiting for this side's user.
  comparing,

  /// This user confirmed; waiting for the other side's confirmation.
  waitingForOther,
  verified,
  cancelled,
}

/// Thrown for messages that break the protocol; the session is cancelled.
class SasFailure implements Exception {
  const SasFailure(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Emoji verification between two devices, modelled on Matrix's SAS: an
/// X25519 exchange whose result both users compare as 7 emoji. The responder
/// commits to its key before seeing the initiator's, so neither side can
/// choose a key to make a substituted exchange show the same emoji. Once both
/// users confirm, each side proves with a MAC which keys it vouches for
/// (an identity key, or a new device's key); a mismatch cancels.
///
/// Transport-independent: [handle] takes a received message, and the methods
/// return what to send.
class SasSession {
  SasSession.initiator({
    required this.txn,
    required this.us,
    required this.ourKeys,
  }) : initiator = true,
       them = null;

  SasSession.responder({
    required this.txn,
    required this.us,
    required SasParty this.them,
    required this.ourKeys,
  }) : initiator = false;

  final String txn;
  final SasParty us;
  final bool initiator;

  /// The other device; for an initiator, known once a device accepts.
  SasParty? them;

  /// What this side vouches for: key ID -> base64 key.
  final Map<String, String> ourKeys;

  /// What the other side must vouch for; set before this user confirms.
  Map<String, String>? expectedKeys;

  SasState state = SasState.requested;
  String? cancelReason;

  /// Seven indices into [sasEmoji], once keys are exchanged.
  List<int>? emoji;

  final _x25519 = X25519();
  SimpleKeyPair? _ephemeral;
  String? _ourPublic;
  String? _theirPublic;
  String? _theirCommitment;
  Uint8List? _shared;
  String? _pendingMac;
  var _confirmed = false;

  static const _protocol = 'HANASHI_SAS_V1';

  /// Initiator: the request to send.
  SasMessage request({required String mode}) =>
      SasMessage(SasType.request, {'txn': txn, 'mode': mode});

  /// Responder: the user accepted.
  Future<SasMessage> accept() async {
    _expect(!initiator && state == SasState.requested, 'Nothing to accept');
    await _newKey();
    state = SasState.exchanging;
    return SasMessage(SasType.accept, {
      'txn': txn,
      'commitment': await _commitment(_ourPublic!),
    });
  }

  /// Handles a message from [from]; returns what to send in reply.
  Future<List<SasMessage>> handle(
    String type,
    Map<String, Object?> data,
    SasParty from,
  ) async {
    if (state == SasState.cancelled || state == SasState.verified)
      return const [];
    if (data['txn'] != txn) return const [];
    if (type == SasType.cancel) {
      state = SasState.cancelled;
      cancelReason = data['reason'] as String? ?? 'Cancelled';
      return const [];
    }
    if (them != null && from != them)
      return const []; // Another device; ignore.
    try {
      switch (type) {
        case SasType.accept when initiator && state == SasState.requested:
          them = from;
          _theirCommitment = _string(data, 'commitment');
          await _newKey();
          state = SasState.exchanging;
          return [
            SasMessage(SasType.key, {'txn': txn, 'key': _ourPublic}),
          ];
        case SasType.key
            when state == SasState.exchanging && _theirPublic == null:
          final key = _string(data, 'key');
          if (initiator && await _commitment(key) != _theirCommitment) {
            throw const SasFailure('The other device changed its key');
          }
          _theirPublic = key;
          await _agree();
          state = SasState.comparing;
          return initiator
              ? const []
              : [
                  SasMessage(SasType.key, {'txn': txn, 'key': _ourPublic}),
                ];
        case SasType.mac
            when state == SasState.comparing ||
                state == SasState.waitingForOther:
          _pendingMac = _string(data, 'mac');
          if (_confirmed) await _checkMac();
          return const [];
        default:
          // Out of turn (e.g. delivered twice): ignored. Only the expected
          // message moves the session on.
          return const [];
      }
    } on SasFailure catch (e) {
      return [cancel(e.reason)];
    }
  }

  /// This user confirmed the emoji match; returns our MAC.
  Future<List<SasMessage>> confirm() async {
    _expect(state == SasState.comparing, 'Nothing to confirm');
    _expect(expectedKeys != null, 'Expected keys not set');
    _confirmed = true;
    state = SasState.waitingForOther;
    final mac = await _mac(us, ourKeys);
    final out = [
      SasMessage(SasType.mac, {'txn': txn, 'mac': mac}),
    ];
    if (_pendingMac != null) {
      try {
        await _checkMac();
      } on SasFailure catch (e) {
        out.add(cancel(e.reason));
      }
    }
    return out;
  }

  /// Ends the verification (the user declined, the emoji differ, ...).
  SasMessage cancel(String reason) {
    state = SasState.cancelled;
    cancelReason = reason;
    return SasMessage(SasType.cancel, {'txn': txn, 'reason': reason});
  }

  /// Seals [secret] for the other device; only after verification.
  Future<String> seal(List<int> secret) async {
    _expect(state == SasState.verified, 'Not verified');
    return base64.encode(
      await aeadSeal(
        await _key('SECRETS', 32),
        secret,
        aad: utf8.encode('$_protocol|$txn'),
      ),
    );
  }

  /// Opens what the other device [seal]ed. Throws [DecryptionFailed].
  Future<Uint8List> open(String sealed) async {
    _expect(state == SasState.verified, 'Not verified');
    return aeadOpen(
      await _key('SECRETS', 32),
      base64.decode(sealed),
      aad: utf8.encode('$_protocol|$txn'),
    );
  }

  // Internals

  void _expect(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  static String _string(Map<String, Object?> data, String field) {
    final value = data[field];
    if (value is! String || value.isEmpty) throw SasFailure('Missing $field');
    return value;
  }

  Future<void> _newKey() async {
    final keyPair = _ephemeral = await _x25519.newKeyPair();
    _ourPublic = base64.encode((await keyPair.extractPublicKey()).bytes);
  }

  Future<String> _commitment(String publicKey) async => base64.encode(
    await sha256(utf8.encode('$_protocol|COMMIT|$txn|$publicKey')),
  );

  Future<void> _agree() async {
    final List<int> theirs;
    try {
      theirs = base64.decode(_theirPublic!);
    } on FormatException {
      throw const SasFailure('Malformed key');
    }
    if (theirs.length != 32) throw const SasFailure('Malformed key');
    final shared = await _x25519.sharedSecretKey(
      keyPair: _ephemeral!,
      remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
    );
    _shared = Uint8List.fromList(await shared.extractBytes());
    final bytes = await _key('EMOJI', 6);
    var bits = 0;
    for (final b in bytes) {
      bits = (bits << 8) | b;
    }
    // The first 42 of the 48 bits, 6 per emoji.
    emoji = [for (var i = 0; i < 7; i++) (bits >> (42 - 6 * i)) & 0x3f];
  }

  /// Everything both sides agree on, in initiator -> responder order.
  String get _transcript {
    final initiatorParty = initiator ? us : them!;
    final responderParty = initiator ? them! : us;
    final initiatorKey = initiator ? _ourPublic : _theirPublic;
    final responderKey = initiator ? _theirPublic : _ourPublic;
    return '$_protocol|$initiatorParty|$initiatorKey|$responderParty|$responderKey|$txn';
  }

  Future<Uint8List> _key(String purpose, int length) =>
      hkdf(_shared!, '$_transcript|$purpose', length: length);

  Future<String> _mac(SasParty sender, Map<String, String> keys) async {
    final macKey = await _key('MAC|$sender', 32);
    final canonical = ([
      for (final e in keys.entries) '${e.key}=${e.value}',
    ]..sort()).join('\n');
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(canonical),
      secretKey: SecretKey(macKey),
    );
    return base64.encode(mac.bytes);
  }

  Future<void> _checkMac() async {
    final expected = await _mac(them!, expectedKeys!);
    if (!_constantTimeEquals(expected, _pendingMac!)) {
      throw const SasFailure('The keys do not match');
    }
    state = SasState.verified;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
