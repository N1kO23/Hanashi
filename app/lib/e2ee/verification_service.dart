import 'dart:async';
import 'dart:convert';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../data/account.dart';
import '../data/remote/api_client.dart';
import '../diagnostics/app_log.dart';
import 'encryption_identity.dart';
import 'primitives.dart';
import 'sas.dart';

const _log = Log('verify');

enum VerificationMode {
  /// A new device of the user, verified by one of their other devices, which
  /// then hands it the account secrets.
  device,

  /// A contact: both confirm each other's identity key.
  user,
}

/// One verification as the UI shows it.
class Verification {
  const Verification({
    required this.txn,
    required this.mode,
    required this.incoming,
    required this.peerUser,
    required this.state,
    this.peerDeviceName,
    this.emoji,
    this.cancelReason,
    this.done = false,
  });

  final String txn;
  final VerificationMode mode;

  /// Requested by the other side.
  final bool incoming;
  final String peerUser;

  /// For device verification: the other device's name, if known.
  final String? peerDeviceName;
  final SasState state;

  /// Indices into [sasEmoji] while comparing.
  final List<int>? emoji;
  final String? cancelReason;

  /// Everything is finished, including handing over the secrets.
  final bool done;
}

/// Runs emoji verifications over device inboxes (see [SasSession]).
///
/// Device verification: a new, unverified device asks the user's other
/// devices; one accepts, both users compare emoji, and the verified device
/// sends the account secrets sealed for that device. User verification: two
/// users' devices confirm each other's identity keys, and each side stores a
/// signed statement (an attestation) that it verified the other.
class VerificationService {
  VerificationService({
    required this.api,
    required this.account,
    required this.identity,
    this.onDeviceVerified,
    this.onUserVerified,
    this.requestLifetime = const Duration(minutes: 10),
  });

  final ApiClient api;
  final Account account;
  final EncryptionIdentity identity;

  /// This device received the account secrets and is verified now.
  final void Function()? onDeviceVerified;

  /// A contact's identity key was confirmed: records it (with an
  /// attestation). Set later when the recorder is created after the service.
  Future<void> Function(String userId, String identityKey)? onUserVerified;

  /// Requests older than this are ignored, and sessions give up.
  final Duration requestLifetime;

  final _entries = <String, _Entry>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  var _closed = false;

  SasParty get _us => SasParty(account.userId, account.deviceId);

  /// Current verifications, newest first, and every change.
  Stream<List<Verification>> watch() async* {
    yield current;
    yield* _changes.stream.map((_) => current);
  }

  List<Verification> get current => [
    for (final e in _entries.values.toList().reversed)
      Verification(
        txn: e.session.txn,
        mode: e.mode,
        incoming: e.incoming,
        peerUser: e.peerUser,
        peerDeviceName: e.peerDeviceName,
        state: e.session.state,
        emoji: e.session.emoji,
        cancelReason: e.session.cancelReason,
        done: e.done,
      ),
  ];

  Verification? find(String txn) => current.where((v) => v.txn == txn).firstOrNull;

  void close() {
    _closed = true;
    _changes.close();
  }

  void _changed() {
    if (!_closed) _changes.add(null);
  }

  // Starting

  /// From a new device: asks the user's other devices to verify this one.
  Future<String> requestDeviceVerification() async {
    final signer = await identity.deviceSigner();
    await api.putDeviceKey(signer.publicKeyBase64); // So the other device can check it.
    final keys = await api.userKeys(account.userId);
    final identityKey = keys.identityKey;
    if (identityKey == null) throw const VerificationException('This account has no encryption set up yet.');
    final txn = newUlid();
    final session = SasSession.initiator(
      txn: txn,
      us: _us,
      ourKeys: {'device:${account.deviceId}': signer.publicKeyBase64},
    )..expectedKeys = {'identity': identityKey};
    _entries[txn] = _Entry(session, VerificationMode.device, incoming: false, peerUser: account.userId);
    _changed();
    final request = session.request(mode: VerificationMode.device.name);
    await api.sendToDevices(to: [(user: account.userId, device: null)], type: request.type, data: request.data);
    return txn;
  }

  /// From a verified device: asks [userId]'s devices to verify each other.
  Future<String> requestUserVerification(String userId) async {
    final own = await identity.localIdentity();
    if (own == null) throw const VerificationException('Verify this device first.');
    final theirs = (await api.userKeys(userId)).identityKey;
    if (theirs == null) throw VerificationException('$userId has not set up encryption yet.');
    final txn = newUlid();
    final session = SasSession.initiator(txn: txn, us: _us, ourKeys: {'identity': own.publicKeyBase64})
      ..expectedKeys = {'identity': theirs};
    _entries[txn] = _Entry(session, VerificationMode.user, incoming: false, peerUser: userId);
    _changed();
    final request = session.request(mode: VerificationMode.user.name);
    await api.sendToDevices(to: [(user: userId, device: null)], type: request.type, data: request.data);
    return txn;
  }

  // The user's answers

  /// Accepts an incoming request.
  Future<void> accept(String txn) async {
    final entry = _entries[txn];
    if (entry == null) return;
    final message = await entry.session.accept();
    _changed();
    await _send(entry, [message]);
  }

  /// The emoji match.
  Future<void> confirm(String txn) async {
    final entry = _entries[txn];
    if (entry == null) return;
    final replies = await entry.session.confirm();
    _changed();
    await _send(entry, replies);
    await _afterProgress(entry);
  }

  /// Declines a request, cancels, or says the emoji do not match.
  Future<void> cancel(String txn, {String reason = 'Cancelled'}) async {
    final entry = _entries[txn];
    if (entry == null) return;
    final state = entry.session.state;
    if (state == SasState.cancelled || state == SasState.verified) return;
    final message = entry.session.cancel(reason);
    _log.info('Verification $txn with ${entry.peerUser} cancelled here: $reason');
    _changed();
    if (entry.session.them != null) {
      await _send(entry, [message]);
    } else {
      // Not accepted yet: tell every device that got the request.
      await api.sendToDevices(to: [(user: entry.peerUser, device: null)], type: message.type, data: message.data);
    }
  }

  /// Forgets a finished or cancelled verification.
  void dismiss(String txn) {
    _entries.remove(txn);
    _changed();
  }

  // Messages from other devices

  /// Fetches and handles waiting messages, for a device that does not sync
  /// yet (an unverified one). Others get them through [handle].
  Future<void> pollInbox() async {
    final items = [
      for (final item in await api.inbox())
        if (item.type.startsWith('verification.')) item,
    ];
    for (final item in items) {
      await handle(item);
    }
    if (items.isNotEmpty) await api.ackInbox([for (final item in items) item.id]);
  }

  Future<void> handle(InboxItem item) async {
    if (_closed) return;
    final data = item.data;
    final txn = data['txn'];
    if (txn is! String) return;
    final from = SasParty(item.fromUser, item.fromDevice);
    if (item.type == SasType.request) return _onRequest(item, txn, from);
    final entry = _entries[txn];
    if (entry == null) return;
    if (item.type == SasType.cancel && data['acceptedBy'] != null) {
      // Another device accepted the request: drop it here (unless that is us).
      if (data['acceptedBy'] != account.deviceId) dismiss(txn);
      return;
    }
    if (item.type == SasType.secrets) return _onSecrets(entry, data, from);
    final before = entry.session.state;
    final replies = await entry.session.handle(item.type, data, from);
    if (entry.session.state != before) {
      _log.info(
        'Verification $txn with ${from.userId}/${from.deviceId}: ${before.name} -> ${entry.session.state.name}'
        '${entry.session.state == SasState.cancelled ? ' (${entry.session.cancelReason})' : ''}',
      );
    }
    _changed();
    await _send(entry, replies);
    await _afterProgress(entry);
  }

  Future<void> _onRequest(InboxItem item, String txn, SasParty from) async {
    if (_entries.containsKey(txn)) return;
    if (DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(item.createdAt)) > requestLifetime) return;
    final own = await identity.localIdentity();
    if (own == null) return; // An unverified device cannot vouch for anything.
    final mode = item.data['mode'];
    final Map<String, String> expected;
    String? deviceName;
    if (mode == VerificationMode.device.name && from.userId == account.userId) {
      final device = (await api.userKeys(account.userId)).devices.where((d) => d.deviceId == from.deviceId).firstOrNull;
      if (device == null) return; // It registered no key: nothing to check against.
      expected = {'device:${from.deviceId}': device.mlsSigKey};
      deviceName = (await api.devices()).where((d) => d.id == from.deviceId).firstOrNull?.name;
    } else if (mode == VerificationMode.user.name && from.userId != account.userId) {
      final theirs = (await api.userKeys(from.userId)).identityKey;
      if (theirs == null) return;
      expected = {'identity': theirs};
    } else {
      return;
    }
    final session = SasSession.responder(txn: txn, us: _us, them: from, ourKeys: {'identity': own.publicKeyBase64})
      ..expectedKeys = expected;
    _entries[txn] = _Entry(
      session,
      mode == VerificationMode.device.name ? VerificationMode.device : VerificationMode.user,
      incoming: true,
      peerUser: from.userId,
      peerDeviceName: deviceName,
    );
    _log.info('Verification $txn requested by ${from.userId}/${from.deviceId} ($mode)');
    _changed();
  }

  Future<void> _send(_Entry entry, List<SasMessage> messages) async {
    final them = entry.session.them;
    if (them == null) return;
    for (final m in messages) {
      await api.sendToDevices(to: [(user: them.userId, device: them.deviceId)], type: m.type, data: m.data);
    }
  }

  Future<void> _afterProgress(_Entry entry) async {
    final session = entry.session;
    if (!entry.incoming && session.them != null && !entry.announced) {
      // The other devices that got the request can drop it.
      entry.announced = true;
      final taken = SasMessage(SasType.cancel, {
        'txn': session.txn,
        'reason': 'Accepted on another device',
        'acceptedBy': session.them!.deviceId,
      });
      await api.sendToDevices(to: [(user: entry.peerUser, device: null)], type: taken.type, data: taken.data);
    }
    if (session.state != SasState.verified || entry.finishing) return;
    entry.finishing = true;
    switch (entry.mode) {
      case VerificationMode.device when entry.incoming:
        // We vouched for the new device: hand it the account secrets.
        final secrets = await identity.localSecrets();
        if (secrets == null) return;
        final sealed = await session.seal(utf8.encode(secrets.toJson()));
        await _send(entry, [
          SasMessage(SasType.secrets, {'txn': session.txn, 'data': sealed}),
        ]);
        entry.done = true;
      case VerificationMode.device:
        break; // Done once the secrets arrive.
      case VerificationMode.user:
        await onUserVerified?.call(entry.peerUser, session.expectedKeys!['identity']!);
        entry.done = true;
    }
    _changed();
  }

  Future<void> _onSecrets(_Entry entry, Map<String, Object?> data, SasParty from) async {
    final session = entry.session;
    if (entry.mode != VerificationMode.device || entry.incoming || session.state != SasState.verified) return;
    if (from != session.them || entry.done) return;
    try {
      final secrets = AccountSecrets.fromJson(utf8.decode(await session.open(data['data'] as String)));
      await identity.adoptSecrets(secrets);
      entry.done = true;
      _changed();
      onDeviceVerified?.call();
    } on Object catch (e) {
      _log.warning('The keys from ${from.userId}/${from.deviceId} did not work', e);
      session.cancel(e is VerificationException ? e.message : 'The keys from the other device did not work');
      _changed();
    }
  }
}

class _Entry {
  _Entry(this.session, this.mode, {required this.incoming, required this.peerUser, this.peerDeviceName});

  final SasSession session;
  final VerificationMode mode;
  final bool incoming;
  final String peerUser;
  final String? peerDeviceName;

  /// The initiator told the other devices who accepted.
  var announced = false;
  var finishing = false;
  var done = false;
}
