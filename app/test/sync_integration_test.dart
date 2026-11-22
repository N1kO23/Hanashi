// End-to-end tests with the real Go server and MariaDB, real HTTP/WebSocket
// clients, real MLS and the real local database: one user on several devices
// and their contacts, all end-to-end encrypted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Hmac, SecretKey;
import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:hanashi/app_storage.dart';
import 'package:hanashi/data/account.dart';
import 'package:hanashi/data/attachments.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/data/packs/sticker_pack.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi/data/remote/link_previews.dart';
import 'package:hanashi/data/server_chat_repository.dart';
import 'package:hanashi/data/sync_lock.dart';
import 'package:hanashi/diagnostics/app_log.dart';
import 'package:hanashi/e2ee/group_state.dart';
import 'package:hanashi/e2ee/profile_record.dart';
import 'package:hanashi/e2ee/attestation.dart';
import 'package:hanashi/e2ee/encryption_identity.dart';
import 'package:hanashi/e2ee/file_cipher.dart';
import 'package:hanashi/e2ee/mls_service.dart';
import 'package:hanashi/e2ee/padding.dart';
import 'package:hanashi/e2ee/primitives.dart';
import 'package:hanashi/e2ee/sas.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:hanashi/e2ee/verification_service.dart';
import 'package:hanashi/notifications/notification_center.dart';
import 'package:hanashi/push/background_sync.dart';
import 'package:hanashi/ui/widgets/format.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:openmls/openmls.dart';

import 'support/fake_display.dart';
import 'support/go_server.dart';
import 'support/sticker_packs.dart';

const _timeout = Duration(seconds: 20);

enum _CommitTrouble {
  none,

  /// The server needs a newer app.
  tooOld,

  /// A proxy answers in the server's place, which never hears of the commit.
  neverArrives,

  /// The server takes the commit, and a proxy loses its answer.
  answerLost,

  /// The server is out of reach: nothing gets there, and it cannot be asked.
  unreachable,

  /// The server takes the commit, and then is out of reach before it answers.
  goneAfterTaking,

  /// A proxy gives up at once while the request is still on its way: it gets
  /// to the server a moment later. Once only.
  slowArrival,
}

/// Gets in the way of a device's commits as told.
class _CommitTroubleClient extends http.BaseClient {
  final _inner = http.Client();
  var trouble = _CommitTrouble.none;

  /// How many requests the trouble has got in the way of.
  var troubled = 0;

  /// The IDs of the new groups asked for, every time one is.
  final asked = <String>[];

  /// Gets in the way of one request only.
  var once = false;

  static bool _carriesCommit(http.BaseRequest request) {
    final path = request.url.path;
    return request.method == 'POST' &&
        (path == '/conversations' || path.endsWith('/commits') || path.endsWith('/members'));
  }

  static http.StreamedResponse _answer(int status, String body) =>
      http.StreamedResponse(Stream.value(utf8.encode(body)), status);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (trouble == _CommitTrouble.tooOld && (path.endsWith('/commits') || path.endsWith('/group-info'))) {
      return _answer(426, '{"error":"client_too_old"}');
    }
    final outOfReach = trouble == _CommitTrouble.unreachable || trouble == _CommitTrouble.goneAfterTaking;
    if (outOfReach && path.endsWith('/group-info')) throw http.ClientException('Network is unreachable');
    if (!_carriesCommit(request)) return _inner.send(request);
    if (path == '/conversations' && request is http.Request) asked.add(jsonDecode(request.body)['id'] as String);
    switch (trouble) {
      case _CommitTrouble.slowArrival:
        troubled++;
        trouble = _CommitTrouble.none;
        final late = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = (request as http.Request).bodyBytes;
        unawaited(Future<void>.delayed(const Duration(milliseconds: 500), () => _inner.send(late)));
        return _answer(502, '<html>Bad Gateway</html>');
      case _CommitTrouble.unreachable:
        troubled++;
        throw http.ClientException('Network is unreachable');
      case _CommitTrouble.goneAfterTaking:
        troubled++;
        final response = await _inner.send(request);
        await response.stream.drain<void>();
        throw http.ClientException('Connection closed');
      case _CommitTrouble.neverArrives:
        troubled++;
        return _answer(502, '<html>Bad Gateway</html>');
      case _CommitTrouble.answerLost:
        troubled++;
        if (once) trouble = _CommitTrouble.none;
        final response = await _inner.send(request);
        await response.stream.drain<void>();
        return _answer(502, '<html>Bad Gateway</html>');
      case _CommitTrouble.none || _CommitTrouble.tooOld:
        return _inner.send(request);
    }
  }
}

/// Long enough for a device to have acted on a commit with no clear answer.
const _settling = Duration(milliseconds: 3500);

/// Recovery keys of the test users, so later devices can verify.
final _recoveryKeys = <String, RecoveryKey>{};

Future<GoServer> _startServer() async {
  final server = await GoServer.start();
  addTearDown(server.dispose);
  return server;
}

/// One verified device: its own secure store, MLS database and local cache.
class _Device {
  _Device(this.account, this.api, this.store, this.identity, this.clock, [this.client, AppDatabase? db])
    : db = db ?? AppDatabase(NativeDatabase.memory());

  final Account account;
  final ApiClient api;
  final MemorySecureStore store;
  final EncryptionIdentity identity;
  final DateTime Function() clock;

  /// What the repository's requests go through, if not straight to the server.
  final http.Client? client;
  final dir = Directory.systemTemp.createTempSync('hanashi_device_');

  /// Emoji verification with other devices and contacts.
  late final verification = VerificationService(
    api: api,
    account: account,
    identity: identity,
    onDeviceVerified: () => deviceVerified.complete(),
    onUserVerified: (user, identityKey) => repo.markVerified(user, identityKey),
  );
  final deviceVerified = Completer<void>();

  /// The repository found this device no longer verified (reset elsewhere).
  final unverified = Completer<void>();

  /// The same places the app (and its push engine) use.
  late final storage = AppStorage(
    mediaDir: Directory('${dir.path}/media'),
    supportDir: dir,
  );
  /// Its local cache.
  final AppDatabase db;
  late ServerChatRepository repo;
  final signedOut = Completer<void>();

  String get me => account.userId;

  ServerChatRepository _repository(void Function() onSignedOut) =>
      ServerChatRepository(
        db: db,
        account: account,
        identity: identity,
        onSignedOut: onSignedOut,
        mediaDir: storage.mediaDir,
        packsDir: stickerPacksDir(storage.supportDir),
        tempDir: Directory('${dir.path}/tmp'),
        mlsDbPath: mlsDbPath(storage.supportDir, account.deviceId),
        clock: clock,
        api: client == null ? null : ApiClient(account.serverUrl, token: account.token, client: client),
        onVerificationMessage: verification.handle,
        onUnverified: () {
          if (!unverified.isCompleted) unverified.complete();
        },
      );

  /// Signs in, sets up (first device) or verifies (later devices) encryption,
  /// and starts syncing. With [verify] false the device stays unverified and
  /// does not sync.
  static Future<_Device> signIn(
    GoServer server,
    String name, {
    bool register = false,
    bool verify = true,
    DateTime Function() clock = DateTime.now,
    http.Client? client,
    AppDatabase? db,
  }) async {
    final anonymous = ApiClient(server.url);
    final auth = register
        ? await anonymous.register(
            name: name,
            password: 'password123',
            deviceName: 'test',
            platform: 'test',
          )
        : await anonymous.login(
            name: name,
            password: 'password123',
            deviceName: 'test',
            platform: 'test',
          );
    anonymous.close();
    final account = Account(
      serverUrl: server.url,
      userId: auth.userId,
      displayName: name,
      token: auth.token,
      deviceId: auth.deviceId,
    );
    final api = ApiClient(server.url, token: auth.token);
    final store = MemorySecureStore();
    await account.write(store);
    final identity = EncryptionIdentity(
      api: api,
      account: account,
      store: store,
    );
    final device = _Device(account, api, store, identity, clock, client, db);
    addTearDown(device.close);
    device.repo = device._repository(() => device.signedOut.complete());
    if (register) {
      _recoveryKeys[name] = await identity.setUp();
    } else if (verify) {
      await identity.status();
      await identity.verifyWithRecoveryKey(_recoveryKeys[name]!);
    } else {
      return device;
    }
    device.repo.start();
    await device.online();
    return device;
  }

  Future<void> online() => repo
      .watchConnection()
      .firstWhere((s) => s == ConnectionStatus.online)
      .timeout(_timeout);

  /// Restarts sync (as after an app restart), keeping all local state.
  Future<void> restart() async {
    await repo.dispose();
    repo = _repository(() {});
    repo.start();
    await online();
  }

  Future<List<ChatMessage>> waitForMessages(
    String conv,
    bool Function(List<ChatMessage>) test,
  ) => repo.watchMessages(conv).firstWhere(test).timeout(_timeout);

  Future<ConversationSummary> waitForConversation(
    bool Function(ConversationSummary) test,
  ) async =>
      (await repo
              .watchConversations()
              .map((l) => l.where(test))
              .firstWhere((l) => l.isNotEmpty)
              .timeout(_timeout))
          .first;

  /// The users/devices currently in the conversation's MLS group.
  Future<Set<String>> leavesOf(String conv) => leaves(conv);

  Future<Set<String>> leaves(String conv) async => {
    for (final leaf in await repo.groups.mls.members(conv))
      '${leaf.userId}/${leaf.deviceId}',
  };

  var _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await repo.dispose();
    await db.close();
    api.close();
    await dir.delete(recursive: true);
  }
}

/// A device's cache that, once [letGo] is set, holds back marking a message
/// sent until it completes: a send stopped half way, after the server took it.
class _HeldMarkingSent extends AppDatabase {
  _HeldMarkingSent() : super(NativeDatabase.memory());

  Completer<void>? letGo;

  /// The ID of the first message held back.
  final reached = Completer<String>();

  @override
  Future<void> markSent(String id, int seq) async {
    final hold = letGo;
    if (hold != null) {
      if (!reached.isCompleted) reached.complete(id);
      await hold.future;
    }
    return super.markSent(id, seq);
  }
}

/// Without the group's timeline lines ("Kumiko added Sota").
List<ChatMessage> _chat(List<ChatMessage> messages) => [
  for (final m in messages)
    if (!m.envelope.isGroupLine) m,
];

List<String?> _texts(List<ChatMessage> messages) => [
  for (final m in messages) m.envelope.text,
];

bool _allDecrypted(List<ChatMessage> messages) =>
    messages.every((m) => m.envelope.type != Envelope.encryptedType);

/// Polls until [condition] holds.
/// Makes the two contacts as the app does: [asker] asks, [accepter] says yes,
/// and starts their direct chat right after; its ID.
Future<String> _becomeContacts(_Device asker, _Device accepter) async {
  await Future.wait([asker.repo.started, accepter.repo.started]);
  if (await asker.repo.requestContact(accepter.me) == ContactState.accepted) {
    // They had asked too: the asker said yes.
    return asker.repo.openDirectConversation(accepter.me);
  }
  await accepter.repo.watchContacts().firstWhere((c) => c[asker.me] == ContactState.incoming).timeout(_timeout);
  await accepter.repo.acceptContact(asker.me);
  return accepter.repo.openDirectConversation(asker.me);
}

/// A group of [creator] and [members], who become contacts first.
Future<String> _newGroup(_Device creator, String title, List<_Device> members) async {
  for (final member in members) {
    await _becomeContacts(member, creator);
  }
  return creator.repo.createGroup(title, [for (final m in members) m.me]);
}

Future<void> _eventually(
  FutureOr<bool> Function() condition, {
  String reason = '',
}) async {
  final deadline = DateTime.now().add(_timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Waits for the device's verification [txn] to pass [test].
Future<Verification> _verification(_Device device, String txn, bool Function(Verification v) test) => device
    .verification
    .watch()
    .map((list) => list.where((v) => v.txn == txn && test(v)).firstOrNull)
    .firstWhere((v) => v != null)
    .timeout(_timeout)
    .then((v) => v!);

/// Waits until the device knows [user]'s profile as [test] wants it.
Future<UserProfile> _profileOf(_Device device, String user, bool Function(UserProfile p) test) => device.repo
    .watchProfiles()
    .map((l) => l.where((p) => p.id == user && test(p)).firstOrNull)
    .firstWhere((p) => p != null)
    .timeout(_timeout)
    .then((p) => p!);

/// Polls until [probe] returns a value.
Future<T> _poll<T extends Object>(
  Future<T?> Function() probe, {
  String reason = '',
}) async {
  final deadline = DateTime.now().add(_timeout);
  while (true) {
    final value = await probe();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    // Every simulated device has its own in-memory database on purpose.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    await Openmls.init();
  });

  test('one account on two devices and a contact: encrypted, in sync, unreadable to the server', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);

    // Kumiko starts a chat; both of Sota's devices are welcomed into it.
    final conv = await _becomeContacts(phone, kumiko);
    await kumiko.repo.sendText(conv, 'Sota, are you free later?');
    for (final device in [phone, desktop]) {
      final summary = await device.waitForConversation(
        (c) => c.id == conv && c.unreadCount == 1,
      );
      expect(summary.title, 'kumiko');
      final messages = await device.waitForMessages(
        conv,
        (l) => l.length == 1 && _allDecrypted(l),
      );
      expect(_texts(messages), ['Sota, are you free later?']);
    }
    expect(await phone.leaves(conv), {
      'kumiko@test.local/${kumiko.account.deviceId}',
      'sota@test.local/${phone.account.deviceId}',
      'sota@test.local/${desktop.account.deviceId}',
    });

    // Reading on the desktop clears the badge on the phone.
    await desktop.repo.markRead(conv);
    await phone.waitForConversation((c) => c.id == conv && c.unreadCount == 0);

    // Replying from the phone: it shows up once everywhere, decrypted.
    await phone.repo.sendText(conv, 'Yes, after five.');
    for (final device in [phone, desktop, kumiko]) {
      final messages = await device.waitForMessages(
        conv,
        (l) =>
            l.length == 2 &&
            l.every((m) => m.state == DeliveryState.sent) &&
            _allDecrypted(l),
      );
      expect(_texts(messages), [
        'Sota, are you free later?',
        'Yes, after five.',
      ]);
    }

    // The server only ever saw ciphertext.
    final raw = jsonEncode((await kumiko.api.sync(0)).toJson());
    expect(raw, isNot(contains('free later')));
    expect(raw, isNot(contains('after five')));
    expect(raw, contains('"type":"mls.app"'));
  });

  test('an offline device catches up; a newly verified device joins and reads new messages', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(phone, kumiko);
    await kumiko.repo.sendText(conv, 'one');
    await phone.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));

    // The phone goes away (app closed) while messages keep arriving.
    await phone.repo.dispose();
    await kumiko.repo.sendText(conv, 'two');
    await kumiko.repo.sendText(conv, 'three');
    await kumiko.waitForMessages(
      conv,
      (l) => l.length == 3 && l.every((m) => m.seq != null),
    );
    await phone.restart();
    expect(
      _texts(
        await phone.waitForMessages(
          conv,
          (l) => l.length == 3 && _allDecrypted(l),
        ),
      ),
      ['one', 'two', 'three'],
    );

    // A brand-new device verifies with the recovery key and joins the group
    // itself. It reads what was said before it existed from the key backup
    // the phone keeps, and new messages through the group.
    final laptop = await _Device.signIn(server, 'sota');
    await _eventually(
      () async =>
          (await laptop.leaves(conv))
              .contains('sota@test.local/${laptop.account.deviceId}'),
      reason: 'laptop joins the group',
    );
    await kumiko.repo.sendText(conv, 'four');
    final seen = await laptop.waitForMessages(
      conv,
      (l) => l.length == 4 && _allDecrypted(l),
    );
    expect(_texts(seen), ['one', 'two', 'three', 'four']);
    // Everyone else accepted the new device: it can also send.
    await laptop.repo.sendText(conv, 'hello from the laptop');
    await kumiko.waitForMessages(
      conv,
      (l) => l.length == 5 && l.last.envelope.text == 'hello from the laptop',
    );
    await phone.waitForMessages(
      conv,
      (l) => l.length == 5 && l.last.envelope.text == 'hello from the laptop',
    );
  });

  test('a new device is verified by comparing emoji with another one, and reads the history', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(phone, kumiko);
    await kumiko.repo.sendText(conv, 'from before the laptop');
    await phone.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));

    // No recovery key at hand: the laptop asks the user's other devices.
    final laptop = await _Device.signIn(server, 'sota', verify: false);
    final txn = await laptop.verification.requestDeviceVerification();
    // Not syncing yet, the laptop polls its inbox.
    final polling = Timer.periodic(const Duration(milliseconds: 200), (_) => laptop.verification.pollInbox());
    addTearDown(polling.cancel);

    final request = await _verification(phone, txn, (v) => v.state == SasState.requested);
    expect((request.incoming, request.mode, request.peerDeviceName), (true, VerificationMode.device, 'test'));
    await phone.verification.accept(txn);
    final onLaptop = await _verification(laptop, txn, (v) => v.state == SasState.comparing);
    final onPhone = await _verification(phone, txn, (v) => v.state == SasState.comparing);
    expect(onLaptop.emoji, hasLength(7));
    expect(onLaptop.emoji, onPhone.emoji);

    await phone.verification.confirm(txn);
    await laptop.verification.confirm(txn);
    await laptop.deviceVerified.future.timeout(_timeout);
    expect(await laptop.identity.status(), EncryptionStatus.verified);
    expect((await _verification(phone, txn, (v) => v.done)).state, SasState.verified);

    // With the account secrets, the laptop reads what was said before it.
    laptop.repo.start();
    await laptop.online();
    final history = await laptop.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));
    expect(_texts(history), ['from before the laptop']);
  });

  test('contacts verify each other; a verified contact\'s new key stops sending until verified again', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    Future<void> verifyKumiko() async {
      final txn = await phone.verification.requestUserVerification(kumiko.me);
      final request = await _verification(kumiko, txn, (v) => v.state == SasState.requested);
      expect((request.mode, request.peerUser), (VerificationMode.user, phone.me));
      await kumiko.verification.accept(txn);
      final a = await _verification(phone, txn, (v) => v.state == SasState.comparing);
      final b = await _verification(kumiko, txn, (v) => v.state == SasState.comparing);
      expect(a.emoji, b.emoji);
      await phone.verification.confirm(txn);
      await kumiko.verification.confirm(txn);
      await _verification(phone, txn, (v) => v.done);
      await _verification(kumiko, txn, (v) => v.done);
    }

    await verifyKumiko();
    Future<void> verified(_Device device, String user, bool expected) =>
        device.repo.watchVerifiedUsers().firstWhere((users) => users.contains(user) == expected).timeout(_timeout);
    await verified(phone, kumiko.me, true);
    await verified(kumiko, phone.me, true);
    // The user's other devices learn it from the signed attestation.
    await verified(desktop, kumiko.me, true);

    // The server cannot undo that: not with a statement the user did not
    // sign (or by leaving it out), nor by serving an older one again.
    final own = (await phone.identity.localIdentity())!;
    final stale = await Attestation(userId: kumiko.me, identityKey: null, at: 1).sign(own);
    for (final data in ['{"user":"${kumiko.me}","identityKey":null,"at":9999999999999}', stale]) {
      await phone.api.putAttestation(kumiko.me, data);
      await phone.repo.refreshTrust();
      await desktop.repo.refreshTrust();
      expect(await phone.repo.watchVerifiedUsers().first, contains(kumiko.me));
      expect(await desktop.repo.watchVerifiedUsers().first, contains(kumiko.me));
    }

    // Kumiko resets her encryption: a new identity key.
    await kumiko.identity.setUp(reset: true);
    await kumiko.restart();
    await phone.repo.watchIdentityChanges().firstWhere((users) => users.contains(kumiko.me)).timeout(_timeout);
    await verified(phone, kumiko.me, false);
    await phone.repo.sendText(conv, 'are you still you?');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect((await phone.waitForMessages(conv, (l) => l.isNotEmpty)).last.state, DeliveryState.pending);

    // Verifying her again trusts the new key, and the message goes out.
    await verifyKumiko();
    await verified(phone, kumiko.me, true);
    await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'are you still you?'));
    expect(await phone.repo.watchIdentityChanges().first, isEmpty);
  });

  test('contacts of two servers verify each other with emoji', () async {
    final (a, b) = await GoServer.pair();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final phone = await _Device.signIn(a, 'sota', register: true);
    final desktop = await _Device.signIn(a, 'sota');
    final kumiko = await _Device.signIn(b, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    final txn = await phone.verification.requestUserVerification(kumiko.me);
    final request = await _verification(kumiko, txn, (v) => v.state == SasState.requested);
    expect((request.mode, request.peerUser), (VerificationMode.user, phone.me));
    await kumiko.verification.accept(txn);
    final mine = await _verification(phone, txn, (v) => v.state == SasState.comparing);
    final hers = await _verification(kumiko, txn, (v) => v.state == SasState.comparing);
    expect(mine.emoji, hers.emoji);
    await phone.verification.confirm(txn);
    await kumiko.verification.confirm(txn);
    await _verification(phone, txn, (v) => v.done);
    await _verification(kumiko, txn, (v) => v.done);

    Future<void> verified(_Device device, String user) =>
        device.repo.watchVerifiedUsers().firstWhere((users) => users.contains(user)).timeout(_timeout);
    await verified(phone, kumiko.me);
    await verified(kumiko, phone.me);
    await verified(desktop, kumiko.me);
  });

  test('accepting a verified contact\'s new key ends the verification on every device', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);
    await desktop.waitForConversation((c) => c.id == conv);

    final txn = await phone.verification.requestUserVerification(kumiko.me);
    await _verification(kumiko, txn, (v) => v.state == SasState.requested);
    await kumiko.verification.accept(txn);
    await _verification(phone, txn, (v) => v.state == SasState.comparing);
    await _verification(kumiko, txn, (v) => v.state == SasState.comparing);
    await phone.verification.confirm(txn);
    await kumiko.verification.confirm(txn);
    await _verification(phone, txn, (v) => v.done);
    Future<void> verified(_Device device, String user, bool expected) =>
        device.repo.watchVerifiedUsers().firstWhere((users) => users.contains(user) == expected).timeout(_timeout);
    await verified(desktop, kumiko.me, true);

    await kumiko.identity.setUp(reset: true);
    await kumiko.restart();
    await phone.repo.watchIdentityChanges().firstWhere((users) => users.contains(kumiko.me)).timeout(_timeout);
    await phone.repo.acceptIdentityChange(kumiko.me);
    // The attestation for her old key is gone, so the next trust refresh
    // (on every reconnect) does not bring the old key back.
    await phone.repo.refreshTrust();
    expect(await phone.repo.watchIdentityChanges().first, isEmpty);
    await verified(phone, kumiko.me, false);
    await phone.repo.sendText(conv, 'from the phone');
    await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'from the phone'));

    // The other device takes the new key as unverified too.
    await verified(desktop, kumiko.me, false);
    await desktop.repo.sendText(conv, 'from the desktop');
    await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'from the desktop'));
    expect(await desktop.repo.watchIdentityChanges().first, isEmpty);
  });

  test('an unverified contact\'s new key is taken, with a notice in the chat', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    await kumiko.identity.setUp(reset: true);
    await kumiko.restart();
    final notice = await phone.waitForMessages(
      conv,
      (l) => l.any((m) => m.envelope.type == Envelope.membershipType && m.envelope.body['change'] == 'keyChanged'),
    );
    expect(notice.last.senderId, kumiko.me);
    expect(await phone.repo.watchIdentityChanges().first, isEmpty);
    await phone.repo.sendText(conv, 'hello again');
    await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'hello again'));
  });

  test('a contact resets on a new device, twice: everyone keeps up, and it can send at once', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final hiroko = await _Device.signIn(server, 'hiroko', register: true);
    var kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final group = await _newGroup(phone, 'Club', [kumiko, hiroko]);
    final direct = await _becomeContacts(kumiko, phone);
    for (final device in [kumiko, hiroko, desktop]) {
      await device.waitForConversation((c) => c.id == group);
    }
    await kumiko.waitForConversation((c) => c.id == direct);
    final readers = {
      group: [phone, desktop, hiroko],
      direct: [phone, desktop],
    };

    for (final round in [1, 2]) {
      // Switching accounts in the app: signed out, signed in again, and
      // without the recovery key, reset.
      await kumiko.api.logout();
      await kumiko.close();
      kumiko = await _Device.signIn(server, 'kumiko', verify: false);
      expect(await kumiko.identity.status(), EncryptionStatus.unverified);
      await kumiko.identity.setUp(reset: true);
      kumiko.repo.start();
      await kumiko.online();

      // All the contacts' devices remove her old device at once, and she
      // joins: they must not hold each other up.
      for (final conv in readers.keys) {
        await kumiko.repo.sendText(conv, 'round $round');
      }
      for (final MapEntry(key: conv, value: devices) in readers.entries) {
        for (final device in devices) {
          final messages = await device.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'round $round'));
          final notices = messages.where(
            (m) => m.envelope.type == Envelope.membershipType && m.envelope.body['change'] == 'keyChanged',
          );
          expect(notices, hasLength(round));
          expect(_allDecrypted(messages), isTrue);
        }
        expect(await kumiko.leaves(conv), {
          for (final device in devices) '${device.me}/${device.account.deviceId}',
          '${kumiko.me}/${kumiko.account.deviceId}',
        });
      }
    }
  });

  test('a device that finds another one committing tries again soon, and holds up nothing meanwhile', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final direct = await _becomeContacts(kumiko, phone);
    final group = await _newGroup(phone, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == group);
    // Another device is in the middle of changing the direct chat's group.
    final other = await _Device.signIn(server, 'sota', verify: false);
    await other.identity.status();
    await other.identity.verifyWithRecoveryKey(_recoveryKeys['sota']!);
    final held = await other.api.lease(direct);

    final laptop = await _Device.signIn(server, 'kumiko');
    await _eventually(
      () async => (await laptop.leaves(group)).contains('${laptop.me}/${laptop.account.deviceId}'),
      reason: 'the laptop joins the other chat',
    );
    await phone.repo.sendText(group, 'meanwhile');
    await laptop.repo
        .watchMessages(group)
        .firstWhere((l) => l.any((m) => m.envelope.text == 'meanwhile'))
        .timeout(const Duration(seconds: 5));
    await laptop.repo.sendText(direct, 'from the laptop');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect((await laptop.waitForMessages(direct, (l) => l.isNotEmpty)).last.state, DeliveryState.pending);

    // Done (or given up) without an event that would tell the laptop.
    await other.api.releaseLease(direct, held);
    await phone.waitForMessages(direct, (l) => l.any((m) => m.envelope.text == 'from the laptop'));
  });

  test('the most detailed log says what happened, without messages or secrets', () async {
    await AppLog.instance.setLevel(LogLevel.debug);
    addTearDown(AppLog.instance.reset);
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);
    const text = 'Meet me behind the gym';
    await phone.repo.sendText(conv, text);
    await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == text));
    // A new device: the message from before it joined comes from the backup.
    final laptop = await _Device.signIn(server, 'kumiko');
    await laptop.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == text));

    final log = await AppLog.instance.read();
    for (final line in [
      'Opening ${laptop.me} on device ${laptop.account.deviceId}',
      'Joined $conv from a Welcome by ${phone.me}/${phone.account.deviceId}',
      'Joined $conv at epoch',
      'Cannot read ',
      'this device is not in its group',
      'messages waited for keys; 1 read now',
      'D api: POST /conversations/$conv/lease',
      'D sync: Sent ',
    ]) {
      expect(log, contains(line));
    }
    for (final secret in [
      text,
      'password123',
      phone.account.token,
      kumiko.account.token,
      laptop.account.token,
      await _recoveryKeys['kumiko']!.encode(),
    ]) {
      expect(log.contains(secret), isFalse, reason: 'the log must not hold it');
    }
  });

  test("after a reset, the account's other running device stays out of the chats until verified again", () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);
    await desktop.waitForConversation((c) => c.id == conv);

    // Reset on the phone while the desktop app stays open. The desktop used
    // to rejoin as often as the others removed it: hundreds of commits.
    await phone.identity.setUp(reset: true);
    await phone.restart();
    await desktop.unverified.future.timeout(_timeout);
    final stayed = {'${phone.me}/${phone.account.deviceId}', '${kumiko.me}/${kumiko.account.deviceId}'};
    await _eventually(() async => (await kumiko.leaves(conv)).length == 2, reason: 'the desktop is removed');
    expect(await kumiko.leaves(conv), stayed);
    final settled = await kumiko.repo.groups.localEpoch(conv);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(await kumiko.repo.groups.localEpoch(conv), settled, reason: 'no more commits');
    expect(await kumiko.leaves(conv), stayed);

    await phone.repo.sendText(conv, 'still here');
    await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'still here'));
  });

  test('a device that missed a commit for good rebuilds its group instead of holding its messages', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    // While Kumiko's app is closed, Sota's laptop joins the chat; she never
    // gets that commit (her place in the event stream is past it).
    await kumiko.repo.dispose();
    final laptop = await _Device.signIn(server, 'sota');
    final laptopLeaf = '${laptop.me}/${laptop.account.deviceId}';
    await _eventually(() async => (await phone.leaves(conv)).contains(laptopLeaf), reason: 'the laptop joins');
    var cursor = await kumiko.db.cursor();
    while (true) {
      final page = await kumiko.api.sync(cursor);
      cursor = page.cursor;
      if (!page.more) break;
    }
    await kumiko.db.applyEvents(const [], me: kumiko.me, cursor: cursor);
    kumiko.repo = kumiko._repository(() {});
    kumiko.repo.start();
    await kumiko.online();
    expect(await kumiko.leaves(conv), isNot(contains(laptopLeaf)));

    await kumiko.repo.sendText(conv, 'are you there?');
    for (final device in [phone, laptop]) {
      await device.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'are you there?'));
    }
    expect(await kumiko.leaves(conv), contains(laptopLeaf));
  });

  test('emoji that do not match leave the new device unverified', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final laptop = await _Device.signIn(server, 'sota', verify: false);
    final txn = await laptop.verification.requestDeviceVerification();
    final polling = Timer.periodic(const Duration(milliseconds: 200), (_) => laptop.verification.pollInbox());
    addTearDown(polling.cancel);

    await _verification(phone, txn, (v) => v.state == SasState.requested);
    await phone.verification.accept(txn);
    await _verification(phone, txn, (v) => v.state == SasState.comparing);
    await _verification(laptop, txn, (v) => v.state == SasState.comparing);
    await laptop.verification.confirm(txn);
    await phone.verification.cancel(txn, reason: 'The emoji did not match');
    final cancelled = await _verification(laptop, txn, (v) => v.state == SasState.cancelled);
    expect(cancelled.cancelReason, 'The emoji did not match');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await laptop.identity.localSecrets(), isNull);
    expect(await laptop.identity.status(), EncryptionStatus.unverified);
  });

  test(
    'a device renews its keys after a week; the conversation goes on',
    () async {
      final server = await _startServer();
      var now = DateTime.now();
      final phone = await _Device.signIn(
        server,
        'sota',
        register: true,
        clock: () => now,
      );
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final conv = await _becomeContacts(kumiko, phone);
      await phone.repo.sendText(conv, 'before');
      await kumiko.waitForMessages(
        conv,
        (l) => l.length == 1 && _allDecrypted(l),
      );
      final epoch = await kumiko.repo.groups.mls.epoch(conv);

      // A week later, the phone's next message is followed by a self-update
      // commit that replaces its keys in the group.
      now = now.add(const Duration(days: 8));
      await phone.repo.sendText(conv, 'a week later');
      await _eventually(
        () async => await kumiko.repo.groups.mls.epoch(conv) > epoch,
        reason: 'Kumiko merges the update',
      );
      final commits = (await kumiko.api.sync(0)).events.where(
        (e) =>
            e.type == EventType.mlsCommit &&
            e.data['device'] == phone.account.deviceId,
      );
      expect(
        commits,
        hasLength(1),
      ); // Creating the group needed none: everyone joined by Welcome.

      await phone.repo.sendText(conv, 'with new keys');
      await kumiko.waitForMessages(
        conv,
        (l) => l.length == 3 && _allDecrypted(l),
      );
      await kumiko.repo.sendText(conv, 'still reading you');
      expect(
        _texts(
          await phone.waitForMessages(
            conv,
            (l) => l.length == 4 && _allDecrypted(l),
          ),
        ),
        ['before', 'a week later', 'with new keys', 'still reading you'],
      );
    },
  );

  test('a push while the app is closed: synced, notified, and readable when it opens', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(phone, kumiko);
    await kumiko.repo.sendText(conv, 'hi');
    await phone.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));

    final pushes = await _PushService.start();
    await phone.api.putPushSubscription(endpoint: '${pushes.url}/phone');
    final display = FakeDisplay();
    Future<void> handlePush() => syncForPush(
      db: phone.db,
      store: phone.store,
      storage: phone.storage,
      notifier: display,
    );
    final notifications = NotificationCenter(
      db: phone.db,
      me: phone.me,
      notifier: display,
    );
    await notifications.update(); // Notifications start now.

    // Connected: the server does not push, and a push that arrives anyway
    // only nudges the running app (no second copy of its MLS state).
    await kumiko.repo.sendText(conv, 'still there?');
    await phone.waitForMessages(conv, (l) => l.length == 2 && _allDecrypted(l));
    await handlePush();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pushes.received, 0);
    expect(display.shown, isEmpty);

    // The app closes; the server notices the connection is gone.
    await phone.repo.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await kumiko.repo.sendText(conv, 'Sota, are you asleep?');
    await pushes.waitFor(1).timeout(_timeout);
    await handlePush();
    final shown = display.shown.single;
    expect(shown.title, 'kumiko');
    expect(shown.lines.map((l) => l.text), [
      'still there?',
      'Sota, are you asleep?',
    ]);

    // Opening the app shows the message, which was decrypted in the
    // background: MLS message keys work only once.
    await phone.restart();
    final messages = await phone.waitForMessages(conv, (l) => l.length == 3);
    expect(_texts(messages).last, 'Sota, are you asleep?');
    expect(_allDecrypted(messages), isTrue);
    await kumiko.repo.sendText(conv, 'good morning');
    await phone.waitForMessages(conv, (l) => l.length == 4 && _allDecrypted(l));

    // Reading the chat removes the notification.
    await phone.repo.markRead(conv);
    await notifications.update();
    expect(display.active, isEmpty);
  });

  test('a contact request, and the answer to one, reach a closed app as notifications', () async {
    final server = await _startServer();
    final sota = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    await Future.wait([sota.repo.started, kumiko.repo.started, naoko.repo.started]);
    final pushes = await _PushService.start();
    await sota.api.putPushSubscription(endpoint: '${pushes.url}/sota');
    final display = FakeDisplay();
    final notifications = NotificationCenter(db: sota.db, me: sota.me, notifier: display);
    await notifications.update(); // Notifications start now.
    Future<void> handlePush() =>
        syncForPush(db: sota.db, store: sota.store, storage: sota.storage, notifier: display);

    // Sota asks Naoko, and closes the app.
    await sota.repo.requestContact(naoko.me);
    await sota.repo.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await kumiko.repo.requestContact(sota.me);
    await pushes.waitFor(1).timeout(_timeout);
    await handlePush();
    final request = display.activeContacts[kumiko.me]!;
    expect((request.notice, request.body), (ContactNotice.request, '${kumiko.me} wants to be your contact'));

    await naoko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);
    await naoko.repo.acceptContact(sota.me);
    await pushes.waitFor(2).timeout(_timeout);
    await handlePush();
    final answer = display.activeContacts[naoko.me]!;
    expect((answer.notice, answer.body), (ContactNotice.accepted, 'Accepted your contact request'));
    expect(display.contacts, hasLength(2));

    // Answering the request in the app takes its notification away.
    await sota.restart();
    await sota.repo.acceptContact(kumiko.me);
    await sota.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.accepted).timeout(_timeout);
    await notifications.update();
    expect(display.activeContacts.keys, [naoko.me]);
  });

  test('chat settings follow the user to their other devices; a push honours a muted chat and Focus', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final laptop = await _Device.signIn(server, 'sota');
    final conv = await _becomeContacts(phone, kumiko);
    Future<void> say(String text) async {
      await kumiko.repo.sendText(conv, text);
      await laptop.waitForMessages(conv, (l) => _texts(l).contains(text)); // On the server.
    }

    await say('hi');
    await laptop.repo.setChatSettings(conv, const ChatSettings(notify: ChatNotify.off));
    await phone.repo.watchChatSettings().firstWhere((s) => s[conv]?.notify == ChatNotify.off).timeout(_timeout);
    // The server holds only ciphertext.
    final stored = await phone.api.accountData('chats');
    expect(utf8.decode(base64.decode(stored!.data), allowMalformed: true), isNot(contains(conv)));

    // The phone's app closes; pushes sync it without notifying: the chat is muted.
    final display = FakeDisplay();
    Future<void> handlePush() =>
        syncForPush(db: phone.db, store: phone.store, storage: phone.storage, notifier: display);
    await NotificationCenter(db: phone.db, me: phone.me, notifier: display).update(); // From now on.
    await phone.repo.dispose();
    await say('are you there?');
    await handlePush();
    expect(display.shown, isEmpty);

    // Unmuted on the laptop, which also goes into Focus: what comes waits...
    await laptop.repo.setChatSettings(conv, ChatSettings.empty);
    await laptop.repo.setPresenceMode(PresenceMode.focus);
    await say('hello?');
    await handlePush();
    expect(display.shown, isEmpty);
    // ...until Focus ends, and shows without a sound.
    await laptop.repo.setPresenceMode(PresenceMode.auto);
    await handlePush();
    expect(display.shown.single.lines.last.text, 'hello?');
    expect(display.shown.single.audible, isFalse);
  });

  test('group chats: create, add, rename, typing, leave', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    final yoko = await _Device.signIn(server, 'yoko', register: true);
    Map<String, Object?> lineBody(ChatMessage m) => m.envelope.body;
    bool hasLine(List<ChatMessage> l, String change) => l.any(
      (m) => m.envelope.isGroupLine && lineBody(m)['change'] == change,
    );

    final club = await _newGroup(phone, 'Club', [kumiko, naoko]);
    await phone.repo.sendText(club, 'Meeting at five');
    for (final device in [kumiko, naoko]) {
      final summary = await device.waitForConversation(
        (c) => c.id == club && c.unreadCount == 1,
      );
      expect((summary.title, summary.conversation.isGroup), ('Club', true));
      final messages = await device.waitForMessages(
        club,
        (l) => _texts(l).contains('Meeting at five') && hasLine(l, 'created'),
      );
      final created = messages.firstWhere((m) => m.envelope.isGroupLine);
      expect(created.senderId, phone.me);
    }

    // Kumiko adds Yoko, who reads what is said from then on, even by a
    // member whose device learns about Yoko only when its message is refused.
    await _becomeContacts(yoko, kumiko);
    await kumiko.repo.addMember(club, yoko.me);
    await naoko.repo.sendText(club, 'Welcome, Yoko!');
    await yoko.waitForMessages(
      club,
      (l) => l.any((m) => m.envelope.text == 'Welcome, Yoko!'),
    );
    final added = await phone.waitForMessages(club, (l) => hasLine(l, 'added'));
    final line = added.firstWhere((m) => lineBody(m)['change'] == 'added');
    expect((line.senderId, lineBody(line)['user']), (kumiko.me, yoko.me));

    await naoko.repo.renameGroup(club, 'Club Room');
    await phone.waitForConversation(
      (c) => c.id == club && c.title == 'Club Room',
    );
    await yoko.waitForMessages(club, (l) => hasLine(l, 'renamed'));

    // A description goes the same way, and renaming keeps it.
    await kumiko.repo.setGroupDescription(club, '  After school.\nBring snacks.  ');
    await phone.waitForConversation((c) => c.id == club && c.description == 'After school.\nBring snacks.');
    await naoko.repo.renameGroup(club, 'The Club Room');
    await yoko.waitForConversation(
      (c) => c.id == club && c.title == 'The Club Room' && c.description == 'After school.\nBring snacks.',
    );
    final described = await yoko.waitForMessages(club, (l) => hasLine(l, 'description'));
    expect(described.firstWhere((m) => lineBody(m)['change'] == 'description').senderId, kumiko.me);
    await kumiko.repo.setGroupDescription(club, null);
    await phone.waitForConversation((c) => c.id == club && c.title == 'The Club Room' && c.description == null);
    await phone.waitForMessages(club, (l) => hasLine(l, 'descriptionRemoved'));

    final typing = phone.repo
        .watchTyping(club)
        .firstWhere((users) => users.contains(kumiko.me));
    kumiko.repo.sendTyping(club);
    await typing.timeout(_timeout);

    // Naoko leaves: the group is gone from her devices, and the others take
    // her devices out of the group, so she cannot read what follows.
    await naoko.repo.leaveGroup(club);
    await _eventually(
      () async => await naoko.db.conversation(club) == null,
      reason: 'gone for Naoko',
    );
    expect(await naoko.repo.groups.mls.hasGroup(club), isFalse);
    for (final device in [phone, kumiko, yoko]) {
      await _eventually(
        () async =>
            !(await device.leaves(club))
                .any((leaf) => leaf.startsWith(naoko.me)),
        reason: "Naoko's devices removed",
      );
    }
    await phone.waitForMessages(club, (l) => hasLine(l, 'left'));
    await phone.repo.sendText(club, 'after Naoko left');
    for (final device in [kumiko, yoko]) {
      await device.waitForMessages(
        club,
        (l) => l.any((m) => m.envelope.text == 'after Naoko left'),
      );
    }
  });

  test('the outbox delivers exactly once across a server restart', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    await server.stop();
    await phone.repo
        .watchConnection()
        .firstWhere((s) => s != ConnectionStatus.online)
        .timeout(_timeout);
    await phone.repo.sendText(conv, 'sent while the server was down');
    expect(
      (await phone.waitForMessages(conv, (l) => l.isNotEmpty)).single.state,
      DeliveryState.pending,
    );

    await server.restart();
    expect(
      _texts(
        await kumiko.waitForMessages(
          conv,
          (l) => l.isNotEmpty && _allDecrypted(l),
        ),
      ),
      ['sent while the server was down'],
    );
    await phone.waitForMessages(
      conv,
      (l) => l.single.state == DeliveryState.sent,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await kumiko.repo.watchMessages(conv).first, hasLength(1));
  });

  test('a device that stops while sending marks what it sent before its database closes', () async {
    final server = await _startServer();
    final db = _HeldMarkingSent();
    final kumiko = await _Device.signIn(server, 'kumiko', register: true, db: db);
    final sota = await _Device.signIn(server, 'sota', register: true);
    final conv = await _becomeContacts(kumiko, sota);
    await kumiko.waitForConversation((c) => c.id == conv);

    // The server has the message; marking it sent waits while the device stops.
    db.letGo = Completer();
    await kumiko.repo.sendText(conv, 'See you tomorrow');
    final held = await db.reached.future.timeout(_timeout);
    var disposed = false;
    final disposing = kumiko.repo.dispose().then((_) => disposed = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(disposed, isFalse, reason: 'it waits for the message under way');

    db.letGo!.complete();
    await disposing;
    final row = await db.messageRow(held);
    expect(row?.state, DeliveryState.sent);
    expect(row?.seq, isNotNull);
  });

  test('a server as it comes refuses apps from before 0.9.0, and only those', () async {
    final server = await _startServer();
    final info = await ApiClient(server.url).serverInfo();
    expect(info.minClient, 5, reason: 'apps from 0.9.0 on');

    final http = HttpClient();
    addTearDown(http.close);
    Future<(int, String)> signUp(String? level) async {
      final request = await http.postUrl(Uri.parse('${server.url}/auth/register'));
      if (level != null) request.headers.set(clientLevelHeader, level);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'name': 'old${level ?? ''}', 'password': 'password123', 'deviceName': 'old', 'platform': 'test'}));
      final response = await request.close();
      final body = (jsonDecode(await response.transform(utf8.decoder).join()) as Map)['error'] as String? ?? '';
      return (response.statusCode, body);
    }

    // Saying no level counts as level 0.
    expect(await signUp(null), (426, 'client_too_old'));
    expect(await signUp('4'), (426, 'client_too_old'));
    expect((await signUp('5')).$1, 200);
    // And later apps.
    expect((await signUp('${clientLevel + 1}')).$1, 200);
  });

  test('a server that needs a newer app loses nothing until the app is updated', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    await server.restart(minClient: clientLevel + 1);
    await phone.repo
        .watchConnection()
        .firstWhere((s) => s == ConnectionStatus.updateRequired)
        .timeout(_timeout);
    await phone.repo.sendText(conv, 'written before updating');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      (await phone.waitForMessages(conv, (l) => l.isNotEmpty)).single.state,
      DeliveryState.pending,
    );
    expect(phone.signedOut.isCompleted, isFalse);
    expect(phone.unverified.isCompleted, isFalse);
    expect(await phone.repo.groups.mls.hasGroup(conv), isTrue);

    // Their updated apps, here as a server that takes these again.
    await server.restart();
    await phone.restart();
    await kumiko.restart();
    expect(
      _texts(await kumiko.waitForMessages(conv, (l) => l.isNotEmpty && _allDecrypted(l))),
      ['written before updating'],
    );
    await phone.waitForMessages(conv, (l) => l.single.state == DeliveryState.sent);
  });

  test('a commit refused for the app being too old leaves the group alone', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);

    client.trouble = _CommitTrouble.tooOld;
    await expectLater(
      sota.repo.renameGroup(club, 'Never named'),
      throwsA(isA<ApiException>().having((e) => e.isClientTooOld, 'isClientTooOld', isTrue)),
    );
    expect(await sota.repo.groups.mls.hasGroup(club), isTrue, reason: 'nothing here is broken');

    client.trouble = _CommitTrouble.none;
    await sota.restart();
    await sota.repo.sendText(club, 'after updating');
    await kumiko.waitForMessages(club, (l) => l.any((m) => m.envelope.text == 'after updating'));
    await sota.waitForMessages(
      club,
      (l) => l.any((m) => m.envelope.text == 'after updating' && m.state == DeliveryState.sent),
    );
  });

  test('a commit that went through though its answer was lost stays, with no rebuild', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);
    final epoch = (await sota.repo.groups.localEpoch(club))!;

    client.trouble = _CommitTrouble.answerLost;
    await expectLater(sota.repo.renameGroup(club, 'Club Room'), throwsA(isA<ApiException>()));
    client.trouble = _CommitTrouble.none;
    await Future<void>.delayed(_settling);

    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    expect(await sota.repo.groups.localEpoch(club), epoch + 1, reason: 'a rebuild would be one more');
    expect((await sota.api.groupInfo(club)).epoch, epoch + 1);
    expect(await sota.db.unsettledCommit(club), isNull);
    final lines = (await sota.repo.watchMessages(club).first).where(
      (m) => m.envelope.type == Envelope.membershipType && m.envelope.body['change'] == 'renamed',
    );
    expect(lines.single.senderId, sota.me, reason: 'its own timeline says so too');

    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
    await kumiko.repo.sendText(club, 'from kumiko');
    await sota.waitForMessages(club, (l) => _texts(l).contains('from kumiko'));
    // Not stuck waiting: the next change goes through as usual.
    await sota.repo.renameGroup(club, 'Club Room 2');
    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club Room 2');
  });

  test('a commit that never reached the server is undone by a rebuild', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);

    client.trouble = _CommitTrouble.neverArrives;
    await expectLater(sota.repo.renameGroup(club, 'Never named'), throwsA(isA<ApiException>()));
    client.trouble = _CommitTrouble.none;
    await Future<void>.delayed(_settling);

    final local = await sota.repo.groups.localEpoch(club);
    expect(local, (await sota.api.groupInfo(club)).epoch, reason: 'back with everyone else');
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club');
    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
    await kumiko.repo.sendText(club, 'from kumiko');
    await sota.waitForMessages(club, (l) => _texts(l).contains('from kumiko'));
    // It changes nothing until a member has told it what the group is now.
    await _eventually(
      () async => (await sota.db.groupStateRow(club))?.hash == (await kumiko.db.groupStateRow(club))?.hash,
      reason: 'Kumiko seals the state for Sota',
    );
    await sota.repo.renameGroup(club, 'Club Room');
    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club Room');
  });

  test('a commit with no clear answer gives way to one that counted first', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);

    client.trouble = _CommitTrouble.neverArrives;
    await expectLater(sota.repo.renameGroup(club, 'Never named'), throwsA(isA<ApiException>()));
    client.trouble = _CommitTrouble.none;
    await kumiko.repo.renameGroup(club, 'Her name');

    await sota.waitForConversation((c) => c.id == club && c.title == 'Her name');
    await _eventually(
      () async => (await sota.db.groupStateRow(club))?.hash == (await kumiko.db.groupStateRow(club))?.hash,
      reason: 'they agree on the state again',
    );
    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
    await kumiko.repo.sendText(club, 'from kumiko');
    await sota.waitForMessages(club, (l) => _texts(l).contains('from kumiko'));
  });

  test('a commit is settled even if the app closes before it finds out', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);
    final epoch = (await sota.repo.groups.localEpoch(club))!;

    // It went through, and the app knows nothing of that when it comes back.
    client.trouble = _CommitTrouble.answerLost;
    await expectLater(sota.repo.renameGroup(club, 'Club Room'), throwsA(isA<ApiException>()));
    client.trouble = _CommitTrouble.none;
    await sota.restart();
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    expect(await sota.repo.groups.localEpoch(club), epoch + 1, reason: 'a rebuild would be one more');
    expect(await sota.db.unsettledCommit(club), isNull);
    expect(
      (await sota.repo.watchMessages(club).first).where((m) => m.envelope.body['change'] == 'renamed'),
      hasLength(1),
    );

    // It never arrived, and the same again.
    client.trouble = _CommitTrouble.neverArrives;
    await expectLater(sota.repo.renameGroup(club, 'Never named'), throwsA(isA<ApiException>()));
    client.trouble = _CommitTrouble.none;
    await sota.restart();
    await _eventually(() async => await sota.db.unsettledCommit(club) == null, reason: 'it finds out');
    await _eventually(
      () async => await sota.repo.groups.localEpoch(club) == (await sota.api.groupInfo(club)).epoch,
      reason: 'back with everyone else',
    );
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
  });

  test('a new group whose answer was lost is simply made, without rejoining it', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    await _becomeContacts(kumiko, sota);

    client
      ..trouble = _CommitTrouble.answerLost
      ..once = true;
    final club = await sota.repo.createGroup('Club', [kumiko.me]);
    client.trouble = _CommitTrouble.none;

    await sota.waitForConversation((c) => c.id == club && c.title == 'Club');
    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club');
    expect(await sota.db.unsettledCommit(club), isNull);
    await Future<void>.delayed(_settling);
    expect(await sota.repo.groups.localEpoch(club), 1, reason: 'rejoining would be one more');
    expect((await sota.db.groupStateRow(club))!.hash, (await kumiko.db.groupStateRow(club))!.hash);

    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
    await kumiko.repo.sendText(club, 'from kumiko');
    await sota.waitForMessages(club, (l) => _texts(l).contains('from kumiko'));
    await sota.repo.renameGroup(club, 'Club Room');
    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club Room');
  });

  test('a new group that did not get through is made once the server can be reached', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    await _becomeContacts(kumiko, sota);
    client.asked.clear(); // Their direct chat.

    client.trouble = _CommitTrouble.neverArrives;
    await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
    final club = (await sota.db.unsettledConversations()).single;
    client.trouble = _CommitTrouble.none;

    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club');
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club');
    await _eventually(() async => await sota.db.unsettledCommit(club) == null, reason: 'it finds out');
    expect(client.asked.toSet(), {club}, reason: 'always the same one');
    expect(await sota.repo.groups.localEpoch(club), 1, reason: 'rejoining would be one more');
    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
  });

  test('a new group that did not get through is made after a restart too, or dropped if refused', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    await _becomeContacts(kumiko, sota);
    await _becomeContacts(naoko, sota);

    client.trouble = _CommitTrouble.unreachable;
    await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
    await expectLater(sota.repo.createGroup('Refused', [naoko.me]), throwsA(isA<ApiException>()));
    final pending = await sota.db.unsettledConversations();
    expect(pending, hasLength(2));
    // Meanwhile Naoko is no longer a contact, so that one cannot be made.
    await naoko.repo.removeContact(sota.me);
    client.trouble = _CommitTrouble.none;

    await sota.restart();
    await _eventually(() async => (await sota.db.unsettledConversations()).isEmpty, reason: 'it finds out');
    final club = (await kumiko.waitForConversation((c) => c.title == 'Club')).id;
    expect(pending, contains(club));
    final refused = pending.firstWhere((id) => id != club);
    expect(await sota.repo.groups.mls.hasGroup(refused), isFalse);
    expect([for (final c in await naoko.repo.watchConversations().first) c.title], isNot(contains('Refused')));
  });

  test('a new group that reaches the server after the proxy gave up is made once', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    await _becomeContacts(kumiko, sota);

    client.trouble = _CommitTrouble.slowArrival;
    final club = await sota.repo.createGroup('Club', [kumiko.me]);
    await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club');
    await Future<void>.delayed(_settling);
    expect([for (final c in await kumiko.repo.watchConversations().first) if (c.title == 'Club') c.id], [club]);
    expect(await kumiko.repo.groups.localEpoch(club), 1, reason: 'one Welcome, joined once');
    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
  });

  group('asking for the same group again after no clear answer', () {
    Future<(_Device, _Device, _CommitTroubleClient)> contacts() async {
      final server = await _startServer();
      final client = _CommitTroubleClient();
      final sota = await _Device.signIn(server, 'sota', register: true, client: client);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      await _becomeContacts(kumiko, sota);
      client.asked.clear(); // Their direct chat.
      return (sota, kumiko, client);
    }

    Future<List<String>> clubs(_Device device) async => [
      for (final c in await device.repo.watchConversations().first)
        if (c.title == 'Club') c.id,
    ];

    test('finds the one that went through', () async {
      final (sota, kumiko, client) = await contacts();
      client.trouble = _CommitTrouble.goneAfterTaking;
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      client.trouble = _CommitTrouble.none;

      final club = await sota.repo.createGroup('Club', [kumiko.me]);
      await sota.waitForConversation((c) => c.id == club && c.title == 'Club');
      await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club');
      await Future<void>.delayed(_settling);
      expect(await clubs(sota), [club]);
      expect(await clubs(kumiko), [club]);
      expect(await sota.repo.groups.localEpoch(club), 1, reason: 'rejoining would be one more');
      await sota.repo.sendText(club, 'from sota');
      await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
    });

    test('finds it too if the device worked it out by itself first', () async {
      final (sota, kumiko, client) = await contacts();
      client.trouble = _CommitTrouble.goneAfterTaking;
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      final club = (await sota.db.unsettledConversations()).single;
      client.trouble = _CommitTrouble.none;
      await _eventually(() async => await sota.db.unsettledCommit(club) == null, reason: 'it finds out');

      expect(await sota.repo.createGroup('Club', [kumiko.me]), club);
      expect(await clubs(sota), [club]);
      // Only that once: wanting another one later gets another one.
      final second = await sota.repo.createGroup('Club', [kumiko.me]);
      expect(second, isNot(club));
    });

    test('makes the first one if it never arrived', () async {
      final (sota, kumiko, client) = await contacts();
      client.trouble = _CommitTrouble.unreachable;
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      final first = (await sota.db.unsettledConversations()).single;
      client.trouble = _CommitTrouble.none;

      final club = await sota.repo.createGroup('Club', [kumiko.me]);
      expect(club, first);
      await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club');
      expect(await clubs(kumiko), [club]);
    });

    test('makes no other while the server cannot say', () async {
      final (sota, kumiko, client) = await contacts();
      client.trouble = _CommitTrouble.unreachable;
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      expect(await sota.db.unsettledConversations(), hasLength(1));
      expect(client.asked.toSet(), hasLength(1), reason: 'every try asks for the same one');
    });

    test('finds it after a restart too', () async {
      final (sota, kumiko, client) = await contacts();
      client.trouble = _CommitTrouble.goneAfterTaking;
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      final club = (await sota.db.unsettledConversations()).single;
      client.trouble = _CommitTrouble.none;
      await _eventually(() async => await sota.db.unsettledCommit(club) == null, reason: 'it finds out');

      await sota.restart();
      expect(await sota.repo.createGroup('Club', [kumiko.me]), club);
      expect(await clubs(sota), [club]);
    });

    test('leaves other groups alone', () async {
      final (sota, kumiko, client) = await contacts();
      client.trouble = _CommitTrouble.unreachable;
      await expectLater(sota.repo.createGroup('Club', [kumiko.me]), throwsA(isA<ApiException>()));
      client.trouble = _CommitTrouble.none;
      final other = await sota.repo.createGroup('Other club', [kumiko.me]);
      await kumiko.waitForConversation((c) => c.id == other && c.title == 'Other club');
    });
  });

  group('an app that stopped in the middle of a commit', () {
    Future<(_Device, _Device, String)> club() async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await kumiko.waitForConversation((c) => c.id == club);
      return (sota, kumiko, club);
    }

    test('before merging it: nothing happened, and no rebuild', () async {
      final (sota, kumiko, conv) = await club();
      final epoch = (await sota.repo.groups.localEpoch(conv))!;
      await sota.db.noteUnsettledCommit(conv, epoch: epoch);

      await sota.restart();
      await _eventually(() async => await sota.db.unsettledCommit(conv) == null, reason: 'the note goes');
      await Future<void>.delayed(_settling);
      expect(await sota.repo.groups.localEpoch(conv), epoch, reason: 'a rebuild would be one more');
      await sota.repo.sendText(conv, 'from sota');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('from sota'));
    });

    test("before merging it, with another's commit next: taken as usual", () async {
      final (sota, kumiko, conv) = await club();
      final epoch = (await sota.repo.groups.localEpoch(conv))!;
      await sota.db.noteUnsettledCommit(conv, epoch: epoch);

      await kumiko.repo.renameGroup(conv, 'Her name');
      await sota.waitForConversation((c) => c.id == conv && c.title == 'Her name');
      await Future<void>.delayed(_settling);
      expect(await sota.repo.groups.localEpoch(conv), epoch + 1, reason: 'a rebuild would be one more');
      expect(await sota.db.unsettledCommit(conv), isNull);
    });

    test('after merging it, before sending it: back with everyone else', () async {
      final (sota, kumiko, conv) = await club();
      final epoch = (await sota.repo.groups.localEpoch(conv))!;
      await sota.db.noteUnsettledCommit(conv, epoch: epoch);
      await sota.repo.groups.mls.commit(conv, authenticatedData: const CommitClaim.unknown().encode());
      expect(await sota.repo.groups.localEpoch(conv), epoch + 1);

      await sota.restart();
      await _eventually(
        () async =>
            await sota.db.unsettledCommit(conv) == null &&
            await sota.repo.groups.localEpoch(conv) == (await sota.api.groupInfo(conv)).epoch,
        reason: 'it rebuilds',
      );
      await sota.repo.sendText(conv, 'from sota');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('from sota'));
      await kumiko.repo.sendText(conv, 'from kumiko');
      await sota.waitForMessages(conv, (l) => _texts(l).contains('from kumiko'));
    });

    test('while rejoining: joins again', () async {
      final (sota, kumiko, conv) = await club();
      final epoch = (await sota.repo.groups.localEpoch(conv))!;
      await sota.db.noteUnsettledCommit(conv, epoch: epoch);
      await sota.repo.groups.mls.deleteGroup(conv);

      await sota.restart();
      await _eventually(() async => await sota.repo.groups.mls.hasGroup(conv), reason: 'it joins');
      await _eventually(() async => await sota.db.unsettledCommit(conv) == null, reason: 'the note goes');
      await sota.repo.sendText(conv, 'from sota');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('from sota'));
    });

    test('every commit is noted while it is under way, and the note goes after', () async {
      final (sota, _, conv) = await club();
      final epoch = (await sota.repo.groups.localEpoch(conv))!;
      final seen = <int?>[];
      final done = sota.db.select(sota.db.unsettledCommits).watch().listen((rows) {
        for (final row in rows) {
          seen.add(row.epoch);
        }
      });
      addTearDown(done.cancel);
      await sota.repo.renameGroup(conv, 'Club Room');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, contains(epoch));
      expect(await sota.db.unsettledCommit(conv), isNull);
    });
  });

  test('a message this version cannot make sense of does not stop the upkeep of its group', () async {
    final server = await _startServer();
    final sota = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);

    // Waiting for keys, kept as it came, in a form this version does not read.
    final id = newUlid();
    await sota.db.into(sota.db.messages).insert(
      MessagesCompanion.insert(
        id: id,
        convId: club,
        sender: kumiko.me,
        ts: 1,
        envelope: jsonEncode(
          Envelope(id: id, conv: club, from: kumiko.me, ts: 1, type: Envelope.encryptedType, body: const {}).toJson(),
        ),
        state: DeliveryState.sent,
        seq: const Value(1),
        wire: Value(jsonEncode({'v': 1, 'id': id, 'conv': club})),
      ),
    );
    await sota.restart();
    await kumiko.repo.renameGroup(club, 'Club Room');
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    expect((await sota.waitForConversation((c) => c.id == club)).securityIssue, isNull);
    await kumiko.repo.sendText(club, 'still here');
    await sota.waitForMessages(club, (l) => _texts(l).contains('still here'));
  });

  group('a device that never saw someone in a chat', () {
    /// [user]'s only device signs out and is removed from [conv], and [device]
    /// forgets that they were ever in it: as a device that joined it while none
    /// of theirs was there.
    Future<void> neverSaw(_Device device, String conv, _Device user) async {
      await user.repo.dispose();
      await user.api.logout();
      final leaf = '${user.me}/${user.account.deviceId}';
      await _eventually(() async => !(await device.leaves(conv)).contains(leaf), reason: 'its device removed');
      await device.db.customStatement('DELETE FROM group_users WHERE conv_id = ? AND user_id = ?', [conv, user.me]);
    }

    test('takes the other one of a chat of two from their own contact list', () async {
      final server = await _startServer();
      final phone = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final conv = await _becomeContacts(kumiko, phone);
      await kumiko.waitForConversation((c) => c.id == conv);
      await neverSaw(kumiko, conv, phone);

      final laptop = await _Device.signIn(server, 'sota');
      final laptopLeaf = '${laptop.me}/${laptop.account.deviceId}';
      await _eventually(() async => (await kumiko.leaves(conv)).contains(laptopLeaf), reason: 'the laptop joins');
      await laptop.waitForConversation((c) => c.id == conv);
      final epoch = (await laptop.api.groupInfo(conv)).epoch;
      await Future<void>.delayed(_settling);
      expect((await laptop.api.groupInfo(conv)).epoch, epoch, reason: 'and stays');
      await kumiko.repo.sendText(conv, 'hello laptop');
      await laptop.waitForMessages(conv, (l) => _texts(l).contains('hello laptop'));
    });

    test('in a group still refuses them, and the device refused stops trying soon', () async {
      final server = await _startServer();
      final phone = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      final club = await _newGroup(phone, 'Club', [kumiko, naoko]);
      await kumiko.waitForConversation((c) => c.id == club);
      await naoko.waitForConversation((c) => c.id == club);
      await neverSaw(kumiko, club, phone);
      final start = (await kumiko.api.groupInfo(club)).epoch;

      final laptop = await _Device.signIn(server, 'sota');
      final issue = await laptop.waitForConversation((c) => c.id == club && c.securityIssue != null);
      expect(issue.securityIssue, contains('keeps removing'));
      final after = (await kumiko.api.groupInfo(club)).epoch;
      await Future<void>.delayed(_settling);
      expect((await kumiko.api.groupInfo(club)).epoch, after, reason: 'no more joining for now');
      expect(after - start, lessThanOrEqualTo(2 * 3 + 2), reason: 'three tries, each a join and a removal');
    });
  });

  group('lines about members', () {
    /// The group's lines about members, `from change user`, with `(server)` for
    /// those only the server's events say.
    Future<List<String>> lines(_Device device, String conv) async => [
      for (final m in await device.repo.watchMessages(conv).first)
        if (m.envelope.isGroupLine && const {'created', 'added', 'left'}.contains(m.envelope.body['change']))
          '${m.envelope.from.split('@').first} ${m.envelope.body['change']}'
              '${m.envelope.body['user'] == null ? '' : ' ${(m.envelope.body['user'] as String).split('@').first}'}'
              '${m.envelope.type == Envelope.memberType ? '' : ' (server)'}',
    ];

    Future<void> showing(_Device device, String conv, List<String> expected) => _eventually(
      () async => (await lines(device, conv)).join('\n') == expected.join('\n'),
      reason: '${device.me} shows $expected',
    );

    test('every change of members is said by whoever made it', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await _becomeContacts(naoko, sota);
      await sota.repo.addMember(club, naoko.me);
      await naoko.waitForConversation((c) => c.id == club);
      await naoko.repo.leaveGroup(club);

      const all = ['sota created', 'sota added naoko', 'naoko left'];
      await showing(kumiko, club, all);
      await showing(sota, club, all);
    });

    test('someone added later, and a new device, see the lines from before', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await kumiko.waitForMessages(club, (l) => l.any((m) => m.envelope.type == Envelope.memberType));
      await _becomeContacts(naoko, sota);
      await sota.repo.addMember(club, naoko.me);

      await naoko.waitForConversation((c) => c.id == club);
      await naoko.repo.loadOlderMessages(club);
      await showing(naoko, club, ['sota created', 'sota added naoko']);
      final laptop = await _Device.signIn(server, 'kumiko');
      await laptop.waitForConversation((c) => c.id == club);
      await laptop.repo.loadOlderMessages(club);
      await showing(laptop, club, ['sota created', 'sota added naoko']);
    });

    test('someone of another server added later sees the lines from before too', () async {
      final (a, b) = await GoServer.pair();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final sota = await _Device.signIn(a, 'sota', register: true);
      final kumiko = await _Device.signIn(a, 'kumiko', register: true);
      final naoko = await _Device.signIn(b, 'naoko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await kumiko.waitForMessages(club, (l) => l.any((m) => m.envelope.type == Envelope.memberType));
      await _becomeContacts(naoko, sota);
      await sota.repo.addMember(club, naoko.me);

      // Her server had nothing of the club: it has it from the start now.
      await naoko.waitForConversation((c) => c.id == club && c.title == 'Club');
      await naoko.repo.loadOlderMessages(club);
      await showing(naoko, club, ['sota created', 'sota added naoko']);
    });

    test('a group across servers: members of either add, talk and leave', () async {
      final (a, b) = await GoServer.pair();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final sota = await _Device.signIn(a, 'sota', register: true);
      final naoko = await _Device.signIn(a, 'naoko', register: true);
      final kumiko = await _Device.signIn(b, 'kumiko', register: true);
      final yoko = await _Device.signIn(b, 'yoko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko, naoko]);

      await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club');
      await sota.repo.sendText(club, 'From a.test');
      await kumiko.repo.sendText(club, 'From b.test');
      for (final device in [sota, naoko, kumiko]) {
        await device.waitForMessages(club, (l) => _texts(l).contains('From a.test') && _texts(l).contains('From b.test'));
      }

      // Kumiko adds Yoko, of her server, through his.
      await _becomeContacts(yoko, kumiko);
      await kumiko.repo.addMember(club, yoko.me);
      await naoko.repo.sendText(club, 'Welcome, Yoko!');
      await yoko.waitForMessages(club, (l) => _texts(l).contains('Welcome, Yoko!'));

      await kumiko.repo.leaveGroup(club);
      await showing(sota, club, ['sota created', 'kumiko added yoko', 'kumiko left']);
      await yoko.repo.sendText(club, 'Still here');
      await sota.waitForMessages(club, (l) => _texts(l).contains('Still here'));
    });

    test('a change only the server tells of says so', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await kumiko.waitForConversation((c) => c.id == club);
      // As an app from before members said so themselves would leave.
      await kumiko.api.leaveConversation(club);

      await showing(sota, club, ['sota created', 'kumiko left (server)']);
      final line = (await sota.repo.watchMessages(club).first).lastWhere((m) => m.envelope.isGroupLine);
      expect(describeGroupChange(line.envelope, me: sota.me, nameOf: (id) => id.split('@').first), 'kumiko left (according to the server)');
    });

    test('nobody can send a line this device makes for itself', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await kumiko.waitForConversation((c) => c.id == club);

      final forged = Envelope(
        id: newUlid(),
        conv: club,
        from: kumiko.me,
        ts: DateTime.now().millisecondsSinceEpoch,
        type: Envelope.membershipType,
        body: const {'change': 'renamed', 'title': 'Taken over'},
      );
      await kumiko.repo.send(PendingMessage(forged));
      final got = await sota.waitForMessages(club, (l) => l.any((m) => m.id == forged.id));
      final message = got.singleWhere((m) => m.id == forged.id);
      expect(message.envelope.type, Envelope.refusedType);
      expect(message.envelope.isGroupLine, isFalse);
      expect((await sota.waitForConversation((c) => c.id == club)).title, 'Club');
    });
  });

  test('the direct chat started on accepting a contact survives a lost answer', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    await kumiko.repo.requestContact(sota.me);
    await sota.repo
        .watchContacts()
        .firstWhere((c) => c[kumiko.me] == ContactState.incoming)
        .timeout(_timeout);

    client
      ..trouble = _CommitTrouble.answerLost
      ..once = true;
    await sota.repo.acceptContact(kumiko.me);
    // Waits for the chat that accepting started.
    final conv = await sota.repo.openDirectConversation(kumiko.me);
    expect(client.troubled, 1);
    client.trouble = _CommitTrouble.none;

    expect(await sota.db.unsettledCommit(conv), isNull);
    await kumiko.waitForConversation((c) => c.id == conv);
    await sota.repo
        .watchContacts()
        .firstWhere((c) => c[kumiko.me] == ContactState.accepted)
        .timeout(_timeout);
    await Future<void>.delayed(_settling);
    expect(await sota.repo.groups.localEpoch(conv), 1, reason: 'rejoining would be one more');
    await sota.repo.sendText(conv, 'from sota');
    await kumiko.waitForMessages(conv, (l) => _texts(l).contains('from sota'));
    await kumiko.repo.sendText(conv, 'from kumiko');
    await sota.waitForMessages(conv, (l) => _texts(l).contains('from kumiko'));
  });

  test('adding someone to a group survives a lost answer', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final yoko = await _Device.signIn(server, 'yoko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await _becomeContacts(yoko, sota);
    await kumiko.waitForConversation((c) => c.id == club);
    final epoch = (await sota.repo.groups.localEpoch(club))!;

    client.trouble = _CommitTrouble.answerLost;
    await expectLater(sota.repo.addMember(club, yoko.me), throwsA(isA<ApiException>()));
    client.trouble = _CommitTrouble.none;

    await yoko.waitForConversation((c) => c.id == club && c.title == 'Club');
    await _eventually(() async => await sota.db.unsettledCommit(club) == null, reason: 'it finds out');
    await Future<void>.delayed(_settling);
    expect(await sota.repo.groups.localEpoch(club), epoch + 1, reason: 'a rebuild would be one more');
    expect(await sota.db.groupUsersOf(club), contains(yoko.me));
    await sota.repo.sendText(club, 'welcome');
    await yoko.waitForMessages(club, (l) => _texts(l).contains('welcome'));
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('welcome'));
    await yoko.repo.sendText(club, 'thanks');
    await sota.waitForMessages(club, (l) => _texts(l).contains('thanks'));
  });

  test('rejoining a group survives a lost answer, with one place in it at the end', () async {
    final server = await _startServer();
    final client = _CommitTroubleClient();
    final sota = await _Device.signIn(server, 'sota', register: true, client: client);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await kumiko.waitForConversation((c) => c.id == club);

    // The next commit makes Sota's device rebuild; its rejoining goes through
    // without the answer getting back.
    client.trouble = _CommitTrouble.answerLost;
    sota.repo.groups.needsRecovery.add(club);
    await kumiko.repo.renameGroup(club, 'Club Room');
    await _eventually(() async => client.troubled > 0, reason: 'it tries to rejoin');
    client.trouble = _CommitTrouble.none;

    await _eventually(
      () async =>
          await sota.repo.groups.mls.hasGroup(club) &&
          await sota.db.unsettledCommit(club) == null &&
          (await kumiko.repo.groups.mls.members(club)).where((leaf) => leaf.userId == sota.me).length == 1 &&
          await sota.repo.groups.localEpoch(club) == (await sota.api.groupInfo(club)).epoch,
      reason: 'it is back, once',
    );
    await sota.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    await sota.repo.sendText(club, 'from sota');
    await kumiko.waitForMessages(club, (l) => _texts(l).contains('from sota'));
    await kumiko.repo.sendText(club, 'from kumiko');
    await sota.waitForMessages(club, (l) => _texts(l).contains('from kumiko'));
  });

  test(
    'a device signed out from another device is removed from its groups',
    () async {
      final server = await _startServer();
      final phone = await _Device.signIn(server, 'sota', register: true);
      final desktop = await _Device.signIn(server, 'sota');
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final conv = await _becomeContacts(phone, kumiko);
      await kumiko.repo.sendText(conv, 'hi');
      await phone.waitForMessages(
        conv,
        (l) => l.length == 1 && _allDecrypted(l),
      );
      await desktop.waitForMessages(
        conv,
        (l) => l.length == 1 && _allDecrypted(l),
      );

      await desktop.repo.revokeDevice(phone.account.deviceId);
      await phone.signedOut.future.timeout(_timeout);
      final phoneLeaf = 'sota@test.local/${phone.account.deviceId}';
      for (final device in [desktop, kumiko]) {
        await _eventually(
          () async => !(await device.leaves(conv)).contains(phoneLeaf),
          reason: 'revoked leaf removed',
        );
      }
      // The group still works for everyone left (no fork from both racing to remove it).
      await kumiko.repo.sendText(conv, 'after the revoke');
      expect(
        (await desktop.waitForMessages(
          conv,
          (l) => l.length == 2 && _allDecrypted(l),
        )).last.envelope.text,
        'after the revoke',
      );
      await desktop.repo.sendText(conv, 'still here');
      await kumiko.waitForMessages(
        conv,
        (l) => l.length == 3 && l.last.envelope.text == 'still here',
      );
    },
  );

  test('a device the user never verified is caught and removed', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(phone, kumiko);
    await kumiko.repo.sendText(conv, 'hi');
    await phone.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));

    // Someone with Kumiko's password adds a device that Kumiko never
    // verified. The server does not let it into the group...
    final rogue = await _Device.signIn(server, 'kumiko', verify: false);
    final signer = await rogue.identity.deviceSigner();
    await rogue.api.putDeviceKey(signer.publicKeyBase64);
    await expectLater(
      rogue.api.lease(conv),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'not_verified')),
    );
    // ...but a malicious one would, vouching for it with a made-up signature.
    await server.sql([
      "UPDATE device_keys SET signature = '${base64.encode(Uint8List(64))}', signed_version = 1 "
          "WHERE device_id = '${rogue.account.deviceId}'",
    ]);
    final mls = await MlsService.open(
      dbPath: ':memory:',
      dbKey: randomBytes(32),
      signer: signer,
      userId: rogue.me,
      deviceId: rogue.account.deviceId,
    );
    addTearDown(mls.close);
    final lease = await rogue.api.lease(conv);
    final info = await rogue.api.groupInfo(conv);
    final join = await mls.externalJoin(info.data, authenticatedData: const CommitClaim.unknown().encode());
    await rogue.api.commit(
      conv,
      Commit(
        leaseId: lease.id,
        epoch: lease.epoch,
        mls: join.commit,
        groupInfo: join.groupInfo ?? await mls.groupInfo(conv),
      ),
    );

    final rogueLeaf = 'kumiko@test.local/${rogue.account.deviceId}';
    for (final device in [phone, kumiko]) {
      await _eventually(
        () async => !(await device.leaves(conv)).contains(rogueLeaf),
        reason: 'rogue device removed',
      );
    }
    // Messages sent afterwards are not readable to it.
    await phone.repo.sendText(conv, 'not for the rogue device');
    await kumiko.waitForMessages(
      conv,
      (l) =>
          l.length == 2 && l.last.envelope.text == 'not for the rogue device',
    );
    final removal = (await rogue.api.sync(0)).events
        .lastWhere((e) => e.type == EventType.mlsCommit);
    final result = await mls.process(
      conv,
      base64.decode(removal.data['mls'] as String),
    );
    expect(result.stagedCommitInfo?.selfRemoved, isTrue);
  });

  test('what is written while another engine holds the device waits, and goes once this one opens', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await phone.repo.dispose();
    // A push's engine is syncing, say.
    final other = SyncLock(phone.account.deviceId);
    expect(other.tryAcquire(), isTrue);
    phone.repo = phone._repository(() {});
    phone.repo.start();

    await phone.repo.sendText(conv, 'written meanwhile');
    await phone.repo.loadOlderMessages(conv);
    final pending = await phone.waitForMessages(conv, (l) => _texts(l).contains('written meanwhile'));
    expect(pending.single.state, DeliveryState.pending);
    await other.close();
    await kumiko.waitForMessages(conv, (l) => _texts(l).contains('written meanwhile'));
  });

  test('older history loads on demand', () async {
    final server = await _startServer();
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final phone = await _Device.signIn(server, 'sota', register: true);
    final conv = await _becomeContacts(phone, kumiko);
    for (var i = 0; i < 40; i++) {
      await kumiko.repo.sendText(conv, 'm$i');
    }
    await phone.waitForMessages(
      conv,
      (l) => l.length == 40 && _allDecrypted(l),
    );

    final laptop = await _Device.signIn(server, 'sota');
    expect(
      await laptop.waitForMessages(conv, (l) => l.isNotEmpty),
      hasLength(30),
    ); // Snapshot holds the latest 30.
    await laptop.repo.loadOlderMessages(conv);
    // Sent before the laptop existed, and readable through the key backup.
    final all = await laptop.waitForMessages(
      conv,
      (l) => l.length == 40 && _allDecrypted(l),
    );
    expect(_texts(all).first, 'm0');
  });

  test('the key backup holds what your devices read, and only that', () async {
    final server = await _startServer();
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    final phone = await _Device.signIn(server, 'sota', register: true);
    final club = await _newGroup(kumiko, 'Club', [naoko]);
    await _becomeContacts(phone, kumiko);
    await kumiko.repo.sendText(club, 'before Sota joined');
    await naoko.waitForMessages(club, (l) => _chat(l).length == 1 && _allDecrypted(l));

    // Kumiko does not share the history.
    await kumiko.repo.addMember(club, phone.me, shareHistory: false);
    await kumiko.repo.sendText(club, 'welcome, Sota');
    await phone.waitForMessages(
      club,
      (l) => l.any((m) => m.envelope.text == 'welcome, Sota'),
    );
    await phone.repo.loadOlderMessages(club);
    // No device of Sota's could ever read the first message, nor Kumiko's
    // line saying she made the group.
    final onPhone = _chat(
      await phone.waitForMessages(club, (l) => _chat(l).length == 3),
    );
    expect(
      [for (final m in onPhone) m.envelope.type],
      [Envelope.encryptedType, Envelope.encryptedType, 'text'],
    );

    // The phone backs up what it read; the server gets only ciphertext.
    final welcome = onPhone.last.id;
    final entry = await _poll(
      () async => (await phone.api.queryKeyBackup([welcome]))[welcome],
      reason: 'backed up',
    );
    expect(
      utf8.decode(base64.decode(entry), allowMalformed: true),
      isNot(contains('welcome')),
    );

    // A new device reads the same as the phone, and no more.
    final laptop = await _Device.signIn(server, 'sota');
    await laptop.waitForMessages(
      club,
      (l) => l.any((m) => m.envelope.text == 'welcome, Sota'),
    );
    await laptop.repo.loadOlderMessages(club);
    final onLaptop = _chat(
      await laptop.waitForMessages(club, (l) => _chat(l).length == 3),
    );
    expect(
      [for (final m in onLaptop) m.envelope.text],
      [null, null, 'welcome, Sota'],
    );
  });

  test('replies, reactions, edits and deletions reach every device, new ones included', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    await kumiko.repo.sendText(conv, 'See you at 5?');
    final question = (await phone.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l))).single;
    await phone.repo.sendText(conv, 'Yes!', replyTo: question.id);
    final reply = (await kumiko.waitForMessages(conv, (l) => l.length == 2)).last;
    expect((reply.envelope.text, reply.replyTo!.id, reply.replyTo!.text), ('Yes!', question.id, 'See you at 5?'));

    await kumiko.repo.react(reply.id, '👍');
    await desktop.repo.react(question.id, '❤️');
    await kumiko.repo.editMessage(question.id, 'See you at 6?');
    // Only the sender can change a message.
    await phone.repo.editMessage(question.id, 'mine now');
    await phone.repo.deleteMessage(question.id);
    for (final device in [phone, desktop, kumiko]) {
      final messages = await device.waitForMessages(
        conv,
        (l) => l.length == 2 && l.first.edited && l.first.reactions.isNotEmpty && l.last.reactions.isNotEmpty,
      );
      expect(_texts(messages), ['See you at 6?', 'Yes!']);
      expect(messages.first.reactions, {'❤️': [phone.me]});
      expect(messages.last.reactions, {'👍': [kumiko.me]});
      // The quote follows the edit.
      expect(messages.last.replyTo!.text, 'See you at 6?');
    }

    await kumiko.repo.deleteMessage(question.id);
    for (final device in [phone, desktop, kumiko]) {
      final messages = await device.waitForMessages(conv, (l) => l.first.isDeleted);
      expect(messages.first.reactions, isEmpty);
      expect(messages.last.replyTo!.text, 'This message was deleted');
    }
    // Nothing of the question is left on Sota's phone.
    final rows = await phone.db.select(phone.db.messages).get();
    expect([for (final r in rows) r.envelope].where((e) => e.contains('See you')), isEmpty);

    // A new device restores all of it from the key backup, and never gets
    // the deleted message or its edit: the server dropped them.
    await phone.repo.flushKeyBackup();
    await kumiko.repo.flushKeyBackup();
    final laptop = await _Device.signIn(server, 'sota');
    final restored = await laptop.waitForMessages(
      conv,
      (l) => l.length == 1 && _allDecrypted(l) && l.single.reactions.isNotEmpty && l.single.replyTo!.text != 'See you at 5?',
    );
    expect(_texts(restored), ['Yes!']);
    expect(restored.single.replyTo!.text, 'This message was deleted');
    expect(await laptop.db.messageRow(question.id), isNull);
  });

  test('profile pictures travel encrypted to the people you chat with; names change everywhere', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    final picture = File('${phone.dir.path}/me.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 640, height: 480)..clear(img.ColorRgb8(250, 150, 170))));
    await phone.repo.setAvatar(picture.path);
    final avatar = (await _profileOf(kumiko, phone.me, (p) => p.avatar != null)).avatar!;
    expect((await _profileOf(desktop, phone.me, (p) => p.avatar != null)).avatar!.hash, avatar.hash);
    // Kumiko gets the square picture; the server only ever saw ciphertext.
    final seen = img.decodeJpg((await kumiko.repo.mediaBytes(avatar))!)!;
    expect((seen.width, seen.height), (256, 256));
    final stored = await (await kumiko.api.openMedia(avatar.hash)).stream.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(img.decodeImage(Uint8List.fromList(stored)), isNull);
    // Profiles are not chat messages.
    expect(await kumiko.repo.watchMessages(conv).first, isEmpty);
    expect((await kumiko.api.history(conv)).messages, isEmpty);

    // Someone new learns it at once, without any message.
    final club = await _newGroup(phone, 'Club', [naoko]);
    await naoko.waitForConversation((c) => c.id == club);
    expect((await _profileOf(naoko, phone.me, (p) => p.avatar != null)).avatar!.hash, avatar.hash);

    await phone.repo.setDisplayName('Sota of Minato');
    for (final device in [desktop, kumiko, naoko]) {
      await _profileOf(device, phone.me, (p) => p.displayName == 'Sota of Minato');
    }
    await desktop.repo.setAvatar(null);
    for (final device in [phone, kumiko, naoko]) {
      final profile = await _profileOf(device, phone.me, (p) => p.avatar == null);
      expect(profile.displayName, 'Sota of Minato');
    }
  });

  test('your profile picture reaches your other devices, with no chat in common', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final picture = File('${phone.dir.path}/me.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 300)..clear(img.ColorRgb8(90, 150, 220))));
    await phone.repo.setAvatar(picture.path);
    final avatar = (await _profileOf(phone, phone.me, (p) => p.avatar != null)).avatar!;

    // A new device learns it from the stored record...
    final laptop = await _Device.signIn(server, 'sota');
    expect((await _profileOf(laptop, phone.me, (p) => p.avatar != null)).avatar!.hash, avatar.hash);
    expect(img.decodeJpg((await laptop.repo.mediaBytes(avatar))!)!.width, 256);
    // ...and hears when another device changes it.
    await laptop.repo.setAvatar(null);
    await _profileOf(phone, phone.me, (p) => p.avatar == null);
    // The server holds only ciphertext.
    final stored = await phone.api.profile(phone.me);
    final record = ProfileRecord.fromJson(stored!, user: phone.me);
    expect(utf8.decode(record.ct, allowMalformed: true), isNot(contains('displayName')));
  });

  test('status message and birthday travel encrypted, to the people you chat with and your other devices', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await kumiko.waitForConversation((c) => c.id == conv);

    const card = ProfileCard(statusMessage: 'Only the best for you!', birthday: Birthday(3, 24));
    await phone.repo.setProfileCard(card);
    await _profileOf(kumiko, phone.me, (p) => p.card == card);
    // The server holds only ciphertext.
    final file = AppDatabase.mediaRefOf((await phone.db.profileRow(phone.me))!.card)!;
    final stored = await (await phone.api.openMedia(file.hash)).stream.toBytes();
    expect(utf8.decode(stored, allowMalformed: true), isNot(contains('Only the best')));
    final laptop = await _Device.signIn(server, 'sota');
    await _profileOf(laptop, phone.me, (p) => p.card == card);

    // A new picture keeps the card; clearing the card keeps the picture.
    final picture = File('${phone.dir.path}/me.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 300)..clear(img.ColorRgb8(90, 150, 220))));
    await laptop.repo.setAvatar(picture.path);
    await _profileOf(kumiko, phone.me, (p) => p.avatar != null && p.card == card);
    await phone.repo.setProfileCard(ProfileCard.empty);
    await _profileOf(kumiko, phone.me, (p) => p.avatar != null && p.card.isEmpty);
  });

  test('who is online: idle, in focus or invisible, told only to the people you chat with', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    Future<void> sees(_Device device, String user, Presence status) => device.repo
        .watchPresence()
        .firstWhere((p) => (p[user] ?? Presence.offline) == status)
        .timeout(_timeout);
    Future<void> mode(_Device device, PresenceMode mode) =>
        device.repo.watchPresenceMode().firstWhere((m) => m == mode).timeout(_timeout);

    // Sharing a chat now, each sees the other.
    await _becomeContacts(kumiko, phone);
    await sees(kumiko, phone.me, Presence.online);
    await sees(phone, kumiko.me, Presence.online);

    phone.repo.setActive(false);
    await sees(kumiko, phone.me, Presence.idle);
    phone.repo.setActive(true);
    await sees(kumiko, phone.me, Presence.online);
    await phone.repo.setPresenceMode(PresenceMode.focus);
    await sees(kumiko, phone.me, Presence.focus);

    // The mode is the account's: its other devices know it and can change it.
    final laptop = await _Device.signIn(server, 'sota');
    await mode(laptop, PresenceMode.focus);
    await laptop.repo.setPresenceMode(PresenceMode.invisible);
    await sees(kumiko, phone.me, Presence.offline);
    await mode(phone, PresenceMode.invisible);
    await laptop.repo.setPresenceMode(PresenceMode.auto);
    await sees(kumiko, phone.me, Presence.online);

    // Naoko shares no chat with Sota, so she is never told.
    expect((await naoko.repo.watchPresence().first)[phone.me], isNull);
    // Offline once no device of his is connected.
    await phone.close();
    await laptop.close();
    await sees(kumiko, phone.me, Presence.offline);
  });

  test('photos, videos and files are encrypted before upload and decrypted on arrival', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final desktop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);

    final files = Directory.systemTemp.createTempSync('hanashi_files_');
    addTearDown(() => files.delete(recursive: true));
    final photo = File('${files.path}/cat.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.Image(width: 1200, height: 800)
            ..clear(img.ColorRgb8(200, 120, 160)),
        ),
      );
    final clip = File('${files.path}/clip.mp4')
      ..writeAsBytesSync(List.filled(4096, 7));
    final doc = File('${files.path}/notes.txt')
      ..writeAsStringSync('Meeting at five.');

    await phone.repo.sendAttachment(conv, path: photo.path, name: 'cat.png');
    await phone.repo.sendAttachment(conv, path: clip.path, name: 'clip.mp4');
    await phone.repo.sendAttachment(conv, path: doc.path, name: 'notes.txt');

    final received = await kumiko.waitForMessages(
      conv,
      (l) => l.length == 3 && _allDecrypted(l),
    );
    final [image, video, file] = [for (final m in received) m.envelope];
    expect(image.messageType, MessageType.image);
    final imageRef = image.media!;
    expect((imageRef.width, imageRef.height), (1200, 800));
    expect(imageRef.key, isNotNull);
    expect(video.messageType, MessageType.video);
    expect(file.media!.name, 'notes.txt');

    // What the server stores is ciphertext.
    final stored = await (await kumiko.api.openMedia(file.media!.hash)).stream
        .toBytes();
    expect(
      utf8.decode(stored, allowMalformed: true),
      isNot(contains('Meeting at five')),
    );

    await desktop.waitForMessages(
      conv,
      (l) => l.length == 3 && _allDecrypted(l),
    );
    for (final device in [kumiko, desktop]) {
      expect(
        (await device.repo.mediaBytes(imageRef))!,
        photo.readAsBytesSync(),
      );
      final thumb = img.decodeJpg(
        (await device.repo.mediaBytes(imageRef.thumb!))!,
      )!;
      // Small enough to stay as large as it is.
      expect((thumb.width, thumb.height), (1200, 800));
      expect(
        utf8.decode((await device.repo.mediaBytes(file.media!))!),
        'Meeting at five.',
      );
    }
    // Nothing decrypted is kept: not by those who got them, nor by the
    // sender, whose cache has them too, nor the thumbnail it made.
    final made = Directory('${phone.dir.path}/tmp');
    expect(made.existsSync() ? made.listSync().where((e) => e.path.contains('-thumb')) : const [], isEmpty);
    for (final device in [phone, kumiko, desktop]) {
      final kept = [
        for (final entry in device.storage.mediaDir.listSync(recursive: true))
          if (entry is File) entry,
      ];
      expect(kept, isNotEmpty, reason: device.me);
      for (final file in kept) {
        final bytes = file.readAsBytesSync();
        expect(utf8.decode(bytes.sublist(0, 4), allowMalformed: true), 'MTF2', reason: file.path);
        expect(bytes, isNot(photo.readAsBytesSync()), reason: file.path);
        expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('Meeting at five.')), reason: file.path);
      }
    }
  });

  test('a link preview goes with its text; its pictures are encrypted like any attachment', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);

    final dir = Directory.systemTemp.createTempSync('hanashi_link_picture_');
    addTearDown(() => dir.delete(recursive: true));
    final cover = img.encodePng(img.Image(width: 1200, height: 630)..clear(img.ColorRgb8(30, 60, 90)));
    final file = File('${dir.path}/downloaded')..writeAsBytesSync(cover);
    final picture = (await linkThumbnail(cover))!;
    const url = 'https://news.example/cats';
    await phone.repo.sendText(
      conv,
      'Read $url',
      link: LinkPreviewDraft(
        url: url,
        kind: LinkKind.page,
        title: 'Cats',
        site: 'Pet News',
        picture: picture,
        media: LinkMediaFile(path: file.path, mime: 'image/png', size: cover.length, width: 1200, height: 630),
      ),
    );

    final [message] = await kumiko.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));
    final link = message.envelope.link!;
    expect((link.url, link.kind, link.title, link.site), (url, LinkKind.page, 'Cats', 'Pet News'));
    final thumb = link.thumb!;
    expect((thumb.width, thumb.height, thumb.mime), (1200, 630, 'image/jpeg'));
    expect(thumb.key, isNotNull);
    expect((await kumiko.repo.mediaBytes(thumb))!, picture.bytes);
    // The sender shows it without downloading; the server has ciphertext.
    expect((await phone.repo.localMediaBytes(thumb))!, picture.bytes);
    final stored = await (await kumiko.api.openMedia(thumb.hash)).stream.toBytes();
    const jpeg = [0xFF, 0xD8];
    expect(picture.bytes.sublist(0, 2), jpeg);
    expect(stored.sublist(0, 2), isNot(jpeg));

    // The picture as the site has it, for the viewer, which shows the small
    // one until it is here.
    final full = link.media!;
    expect(
      (full.mime, full.width, full.height, full.thumb?.hash, full.thumb?.key),
      ('image/png', 1200, 630, thumb.hash, thumb.key),
    );
    expect((await kumiko.repo.mediaBytes(full))!, cover);
    expect(file.existsSync(), isFalse);
  });

  test("a link's video goes with it, encrypted and padded like any attachment", () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);

    final dir = Directory.systemTemp.createTempSync('hanashi_link_video_');
    addTearDown(() => dir.delete(recursive: true));
    final video = randomBytes(70000);
    final file = File('${dir.path}/downloaded')..writeAsBytesSync(video);
    const url = 'https://fxtwitter.example/kumiko/status/1';
    await phone.repo.sendText(
      conv,
      url,
      link: LinkPreviewDraft(
        url: url,
        kind: LinkKind.gif,
        site: 'FxTwitter',
        color: '#6363ff',
        media: LinkMediaFile(path: file.path, mime: 'video/mp4', size: video.length, width: 320, height: 180),
      ),
    );

    final [message] = await kumiko.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));
    final link = message.envelope.link!;
    expect((link.kind, link.site, link.color), (LinkKind.gif, 'FxTwitter', '#6363ff'));
    final media = link.media!;
    expect((media.mime, media.size, media.width, media.height), ('video/mp4', video.length, 320, 180));
    expect((await kumiko.repo.mediaBytes(media))!, video);
    // The sender keeps its own copy, not the download; the server has ciphertext, padded.
    expect((await phone.repo.localMediaBytes(media))!, video);
    expect(file.existsSync(), isFalse);
    final stored = await (await kumiko.api.openMedia(media.hash)).stream.toBytes();
    expect(stored.length, FileCipher.encryptedSize(padme(video.length + 1)));
  });

  test('devices that join one after another by external commit can all read the chat', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    await phone.repo.sendText(conv, 'Before the others');
    await kumiko.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));

    // Each joins with the GroupInfo the one before it left on the server.
    Future<void> joined(_Device device) => _eventually(
      () async =>
          await device.repo.groups.mls.hasGroup(conv) &&
          (await device.leaves(conv)).contains('${device.me}/${device.account.deviceId}'),
      reason: 'a new device joins by external commit',
    );
    final laptop = await _Device.signIn(server, 'sota');
    await joined(laptop);
    final tablet = await _Device.signIn(server, 'sota');
    await joined(tablet);
    expect(await tablet.repo.watchConnectionProblem().first, isNull);

    await kumiko.repo.sendText(conv, 'After the others');
    for (final device in [laptop, tablet]) {
      await device.waitForMessages(conv, (l) => l.any((m) => m.envelope.text == 'After the others'));
    }
  });

  test('someone added to a group reads what was said before: shared by whoever added them', () async {
    final server = await _startServer();
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    final phone = await _Device.signIn(server, 'sota', register: true);
    final club = await _newGroup(kumiko, 'Club', [naoko]);
    await _becomeContacts(phone, kumiko);
    for (var i = 0; i < 34; i++) {
      await kumiko.repo.sendText(club, 'm$i');
    }
    await naoko.waitForMessages(club, (l) => _chat(l).length == 34 && _allDecrypted(l));
    await naoko.repo.sendText(club, 'from Naoko');
    final fromNaoko = (await naoko.waitForMessages(club, (l) => l.any((m) => m.seq != null && m.envelope.text == 'from Naoko')))
        .last;
    await naoko.repo.editMessage(fromNaoko.id, 'from Naoko, edited');
    await kumiko.waitForMessages(club, (l) => l.any((m) => m.envelope.text == 'from Naoko, edited'));

    // Kumiko adds Sota from a new laptop, which holds only the latest 30
    // messages: the keys to the rest come from her key backup.
    final laptop = await _Device.signIn(server, 'kumiko');
    await laptop.waitForMessages(club, (l) => l.any((m) => m.envelope.text == 'from Naoko, edited') && _allDecrypted(l));
    expect(_texts(_chat(await laptop.repo.watchMessages(club).first)), isNot(contains('m0')));
    await laptop.repo.addMember(club, phone.me);
    bool shared(ChatMessage m) =>
        m.envelope.type == Envelope.membershipType &&
        m.envelope.body['change'] == 'history' &&
        m.senderId == kumiko.me &&
        m.envelope.body['user'] == phone.me;
    for (final device in [naoko, phone]) {
      await device.waitForMessages(club, (l) => l.any(shared));
    }

    // Sota reads all of it, edits included, once it is loaded.
    await phone.repo.loadOlderMessages(club);
    final everything = [for (var i = 0; i < 34; i++) 'm$i', 'from Naoko, edited'];
    final read = await phone.waitForMessages(club, (l) => _chat(l).length == 35 && _allDecrypted(l));
    expect(_texts(_chat(read)), everything);

    // And so does Sota's next device: the keys are in his key backup now.
    final laptopToo = await _Device.signIn(server, 'sota');
    await laptopToo.repo.loadOlderMessages(club);
    final readToo = await laptopToo.waitForMessages(club, (l) => _chat(l).length == 35 && _allDecrypted(l));
    expect(_texts(_chat(readToo)), everything);
  });

  test("a group's picture reaches its members encrypted, and those added later at once", () async {
    final server = await _startServer();
    final sota = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await _becomeContacts(naoko, sota);
    await kumiko.waitForConversation((s) => s.id == club);

    final file = File('${sota.dir.path}/club.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(240, 150, 170))));
    await sota.repo.setGroupPicture(club, file.path);
    final picture = (await kumiko.waitForConversation((s) => s.id == club && s.picture != null)).picture!;
    expect(img.decodeJpg((await kumiko.repo.mediaBytes(picture))!)!.width, 256);
    bool line(ChatMessage m) => m.envelope.type == Envelope.membershipType && m.envelope.body['change'] == 'picture';
    await kumiko.waitForMessages(club, (l) => l.where(line).length == 1);

    // Naoko has it on joining, with no message telling it, and no line about it.
    await sota.repo.addMember(club, naoko.me);
    final told = await naoko.waitForConversation((s) => s.id == club && s.picture != null);
    expect(told.picture!.hash, picture.hash);
    expect((await naoko.repo.watchMessages(club).first).where(line), isEmpty);
    expect((await kumiko.repo.watchMessages(club).first).where(line), hasLength(1));

    await kumiko.repo.setGroupPicture(club, null);
    for (final d in [sota, naoko]) {
      await d.waitForConversation((s) => s.id == club && s.picture == null);
    }
  });

  test("a pack's stickers go as their pictures, the pack beside them; whoever gets one can add the pack", () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final laptop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    final files = Directory.systemTemp.createTempSync('hanashi_packs_');
    addTearDown(() => files.delete(recursive: true));
    bool ready(List<StickerPack> packs) => packs.any((p) => p.id == 'test-pack' && p.state == StickerPackState.ready);

    // Imported on one device, on its own server; the user's other devices get it.
    final added = await phone.repo.importStickerPack(syntheticStickerPack(files).path);
    expect((added.id, added.stickers.length, added.archive!.host), ('test-pack', 8, UserId.parse(phone.account.userId).host));
    final onLaptop = await laptop.repo.watchStickerPacks().firstWhere(ready).timeout(_timeout);
    expect((onLaptop.single.archive!.hash, onLaptop.single.stickers.length), (added.archive!.hash, 8));
    // The server holds only ciphertext: of the pack, and of the list.
    final uploaded = await (await kumiko.api.openMedia(added.archive!.hash)).stream.toBytes();
    expect(uploaded.sublist(0, 2), isNot(utf8.encode('PK')));
    final stored = await phone.api.accountData('packs');
    expect(utf8.decode(base64.decode(stored!.data), allowMalformed: true), isNot(contains('test-pack')));

    // Sent: its picture, with its pack beside it.
    await phone.repo.sendSticker(conv, const StickerRef.named(pack: 'test-pack', id: '05'));
    var got = await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.sticker != null) && _allDecrypted(l));
    final sticker = got.lastWhere((m) => m.envelope.sticker != null).envelope.sticker!;
    final source = sticker.source!;
    expect((sticker.isNamed, source.pack, source.id, source.title), (false, 'test-pack', '05', 'Test pack'));
    expect(source.archive!.hash, added.archive!.hash);
    final shown = img.decodePng((await kumiko.repo.mediaBytes(sticker.media!))!)!;
    expect((shown.width, shown.height, shown.getPixel(0, 0).a, shown.getPixel(64, 64).a), (128, 128, 0, 255));
    // Sent again: the same picture, not uploaded again.
    await phone.repo.sendSticker(conv, const StickerRef.named(pack: 'test-pack', id: '05'));
    got = await kumiko.waitForMessages(
      conv,
      (l) => l.where((m) => m.envelope.sticker != null).length == 2 && _allDecrypted(l),
    );
    expect(got.lastWhere((m) => m.envelope.sticker != null).envelope.sticker!.media!.hash, sticker.media!.hash);

    // Kumiko adds the pack from the sticker: her own copy, on her server, on all her devices.
    final hers = await kumiko.repo.addStickerPack(source);
    expect((hers.id, hers.stickers.length, hers.state), ('test-pack', 8, StickerPackState.ready));
    expect(hers.archive!.hash, isNot(added.archive!.hash));
    // A sticker from a chat never replaces a pack she has.
    expect((await kumiko.repo.addStickerPack(source)).archive!.hash, hers.archive!.hash);
    final tablet = await _Device.signIn(server, 'kumiko');
    final onTablet = await tablet.repo.watchStickerPacks().firstWhere(ready).timeout(_timeout);
    expect(onTablet.single.archive!.hash, hers.archive!.hash);
    // Kept encrypted on both: nothing in their folders reads without the key.
    for (final device in [kumiko, tablet]) {
      final kept = [
        for (final entry in stickerPacksDir(device.storage.supportDir).listSync(recursive: true))
          if (entry is File) entry,
      ];
      expect(kept, hasLength(9), reason: 'the index and 8 pictures');
      for (final file in kept) {
        expect(utf8.decode(file.readAsBytesSync().sublist(0, 4), allowMalformed: true), 'MTF2', reason: file.path);
      }
    }

    // Kept from it, then the pack removed on one device: gone on the
    // others, while what was kept of it stays and still goes.
    await laptop.repo.setStickerSaved(const StickerRef.named(pack: 'test-pack', id: '02'), true);
    await laptop.repo.removeStickerPack('test-pack');
    await phone.repo.watchStickerPacks().firstWhere((l) => l.isEmpty).timeout(_timeout);
    final kept = await phone.repo.watchSavedStickers().firstWhere((l) => l.isNotEmpty).timeout(_timeout);
    expect((kept.single.media != null, kept.single.source!.id), (true, '02'));
    await expectLater(
      phone.repo.sendSticker(conv, const StickerRef.named(pack: 'test-pack', id: '01')),
      throwsA(isA<StickerPackMissing>()),
    );
    await phone.repo.sendSticker(conv, kept.single);
    await kumiko.waitForMessages(
      conv,
      (l) => l.where((m) => m.envelope.sticker != null).length == 3 && _allDecrypted(l),
    );
  });

  test("a pack's sticker sent while offline goes once back, its picture uploaded first", () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);
    final files = Directory.systemTemp.createTempSync('hanashi_packs_');
    addTearDown(() => files.delete(recursive: true));
    await phone.repo.importStickerPack(syntheticStickerPack(files).path);

    await server.stop();
    await phone.repo.watchConnection().firstWhere((s) => s != ConnectionStatus.online).timeout(_timeout);
    await phone.repo.sendSticker(conv, const StickerRef.named(pack: 'test-pack', id: '03'));
    expect((await phone.waitForMessages(conv, (l) => l.isNotEmpty)).last.state, DeliveryState.pending);

    await server.restart();
    final got = await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.sticker != null) && _allDecrypted(l));
    final sticker = got.lastWhere((m) => m.envelope.sticker != null).envelope.sticker!;
    expect(sticker.source!.id, '03');
    expect(await kumiko.repo.mediaBytes(sticker.media!), isNotNull);
  });

  test("the user's own stickers: made from an image once, sent encrypted, and kept on all their devices", () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final laptop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, phone);

    // Larger than a sticker, with a pink square on a transparent ground.
    final files = Directory.systemTemp.createTempSync('hanashi_stickers_');
    addTearDown(() => files.delete(recursive: true));
    final picture = File('${files.path}/cat.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.fillRect(
            img.Image(width: 1200, height: 900, numChannels: 4),
            x1: 300,
            y1: 200,
            x2: 900,
            y2: 700,
            color: img.ColorRgba8(240, 130, 170, 255),
          ),
        ),
      );
    final made = await phone.repo.makeSticker(picture.path);
    expect((made.media!.width, made.media!.height, made.media!.mime), (512, 384, 'image/png'));
    // One of a pack the user does not have stays named, shown once they add it.
    const kept = StickerRef.named(pack: 'a-pack-i-lack', id: '12');
    await phone.repo.setStickerSaved(kept, true);

    // The user's other device has them, newest first, and sends the same upload.
    final onLaptop = await laptop.repo.watchSavedStickers().firstWhere((l) => l.length == 2).timeout(_timeout);
    expect(onLaptop, [kept, made]);
    await laptop.waitForConversation((s) => s.id == conv);
    await laptop.repo.sendSticker(conv, onLaptop.last);
    final got = await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.sticker != null) && _allDecrypted(l));
    final sticker = got.singleWhere((m) => m.envelope.sticker != null).envelope.sticker!;
    expect(sticker, made);
    final shown = img.decodePng((await kumiko.repo.mediaBytes(sticker.media!))!)!;
    // Still transparent around the square.
    expect((shown.width, shown.height, shown.getPixel(0, 0).a, shown.getPixel(256, 192).a), (512, 384, 0, 255));

    // Let go on one device, gone on the other; a device that starts later
    // has what is left.
    await laptop.repo.setStickerSaved(kept, false);
    await phone.repo.watchSavedStickers().firstWhere((l) => l.length == 1).timeout(_timeout);
    final tablet = await _Device.signIn(server, 'sota');
    expect(await tablet.repo.watchSavedStickers().firstWhere((l) => l.isNotEmpty).timeout(_timeout), [made]);

    // The server holds only ciphertext: of the picture, and of the list.
    final uploaded = await (await kumiko.api.openMedia(made.media!.hash)).stream.toBytes();
    expect(img.PngDecoder().isValidFile(uploaded), isFalse);
    final stored = await phone.api.accountData('stickers');
    expect(utf8.decode(base64.decode(stored!.data), allowMalformed: true), isNot(contains('sha256')));
  });

  test('calls: both devices hear of a call; its keys come from the group, the same on both, and move on with it', () async {
    const liveKitKey = 'APItest', liveKitSecret = 'an integration test secret, long enough for HMAC';
    final server = await GoServer.start(environment: {
      // Nothing is spoken: LiveKit is only told of, by the webhooks below.
      'HANASHI_LIVEKIT_URL': 'ws://127.0.0.1:9',
      'HANASHI_LIVEKIT_API_URL': 'http://127.0.0.1:9',
      'HANASHI_LIVEKIT_API_KEY': liveKitKey,
      'HANASHI_LIVEKIT_API_SECRET': liveKitSecret,
    });
    addTearDown(server.dispose);
    String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
    // What LiveKit would tell the server, signed as LiveKit signs it.
    Future<void> webhook(String event, String room, _Device device, String sid) async {
      final body = utf8.encode(jsonEncode({
        'event': event,
        'room': {'name': room},
        'participant': {'sid': sid, 'identity': '${device.me}/${device.account.deviceId}'},
      }));
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final claims = {'iss': liveKitKey, 'nbf': now, 'exp': now + 300, 'sha256': base64.encode(await sha256(body))};
      final signed = '${b64(utf8.encode('{"alg":"HS256","typ":"JWT"}'))}.${b64(utf8.encode(jsonEncode(claims)))}';
      final mac = await Hmac.sha256().calculateMac(utf8.encode(signed), secretKey: SecretKey(utf8.encode(liveKitSecret)));
      final response = await http.post(
        Uri.parse('${server.url}/livekit/webhook'),
        headers: {'Authorization': '$signed.${b64(mac.bytes)}'},
        body: body,
      );
      expect(response.statusCode, 200, reason: event);
    }

    final sota = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final conv = await _becomeContacts(kumiko, sota);
    expect(await kumiko.repo.callsAvailable(), isTrue);
    Future<Call> call(_Device device, String id, bool Function(Call) test) => device.repo
        .watchCalls()
        .map((calls) => calls[id])
        .firstWhere((call) => call != null && test(call))
        .timeout(_timeout)
        .then((call) => call!);

    final join = await sota.repo.joinCall(conv);
    final id = join.call.id;
    expect((join.call.direct, join.call.unanswered, join.url, join.token.split('.').length), (true, true, 'ws://127.0.0.1:9', 3));
    expect((await call(kumiko, id, (c) => c.unanswered)).startedBy, sota.me);
    // Its place in the chat, from whoever started it.
    final record = await kumiko.waitForMessages(conv, (l) => l.any((m) => m.envelope.callId == id));
    expect(record.singleWhere((m) => m.envelope.callId == id).senderId, sota.me);

    // The same key on both, from the group; another call's is another.
    final sotaKeys = <CallKey?>[], kumikoKeys = <CallKey?>[];
    final watching = [
      sota.repo.watchCallKeys(conv, id).listen(sotaKeys.add),
      kumiko.repo.watchCallKeys(conv, id).listen(kumikoKeys.add),
    ];
    addTearDown(() async {
      for (final w in watching) {
        await w.cancel();
      }
    });
    await _eventually(() => sotaKeys.lastOrNull != null && kumikoKeys.lastOrNull != null, reason: 'keys');
    final first = sotaKeys.last!;
    expect(kumikoKeys.last!.epoch, first.epoch);
    expect(kumikoKeys.last!.key, first.key);
    expect(first.key, hasLength(32));
    final other = await sota.repo.watchCallKeys(conv, newUlid()).firstWhere((k) => k != null).timeout(_timeout);
    expect(other!.key, isNot(first.key));
    // A commit (Kumiko's laptop joins the chat's group): new keys, the same on both.
    await _Device.signIn(server, 'kumiko');
    await _eventually(
      () => sotaKeys.last!.epoch > first.epoch && kumikoKeys.last?.epoch == sotaKeys.last!.epoch,
      reason: 'keys of the next epoch',
    );
    expect(kumikoKeys.last!.key, sotaKeys.last!.key);
    expect(sotaKeys.last!.key, isNot(first.key));

    // LiveKit says who got in: Kumiko answered. Either hanging up ends it.
    await webhook('participant_joined', id, sota, 'PA_s');
    await webhook('participant_joined', id, kumiko, 'PA_k');
    expect((await call(sota, id, (c) => c.answeredAt != null)).users, {sota.me, kumiko.me});
    await kumiko.repo.leaveCall(id);
    expect((await call(sota, id, (c) => !c.active)).reason, CallEnd.ended);

    // Called back, and declined.
    final back = await kumiko.repo.joinCall(conv);
    await call(sota, back.call.id, (c) => c.unanswered);
    await sota.repo.declineCall(back.call.id);
    expect((await call(kumiko, back.call.id, (c) => !c.active)).reason, CallEnd.declined);
    // A device that connects later hears of both from the server.
    final tablet = await _Device.signIn(server, 'sota');
    final known = await tablet.repo.watchCalls().firstWhere((calls) => calls.length == 2).timeout(_timeout);
    expect({for (final c in known.values) c.reason}, {CallEnd.ended, CallEnd.declined});
  });

  test("custom emojis follow the user, a group's are its members'; messages carry their pictures", () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final laptop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final naoko = await _Device.signIn(server, 'naoko', register: true);
    final conv = await _becomeContacts(kumiko, phone);

    // Made on the phone from an image larger than an emoji, see-through
    // around a square; the laptop has it too, and the server only ciphertext.
    final files = Directory.systemTemp.createTempSync('hanashi_emojis_');
    addTearDown(() => files.delete(recursive: true));
    final image = File('${files.path}/cat.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.fillRect(
            img.Image(width: 600, height: 400, numChannels: 4),
            x1: 200,
            y1: 100,
            x2: 400,
            y2: 300,
            color: img.ColorRgba8(240, 130, 170, 255),
          ),
        ),
      );
    final cat = await phone.repo.uploadEmoji(image.path);
    expect((cat.width, cat.mime), (CustomEmoji.size, 'image/png'));
    await phone.repo.changeEmojis((current) => {...current, 'cat': cat});
    final onLaptop = await laptop.repo.watchEmojis().firstWhere((e) => e.isNotEmpty).timeout(_timeout);
    expect(onLaptop['cat']?.hash, cat.hash);
    final stored = await phone.api.accountData('emojis');
    expect(utf8.decode(base64.decode(stored!.data), allowMalformed: true), isNot(contains('sha256')));

    // Written on the laptop, it goes with its picture; a name nobody has stays text.
    await laptop.waitForConversation((s) => s.id == conv);
    await laptop.repo.sendText(conv, 'Hi :cat: :dog:');
    final got = await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Hi :cat: :dog:'));
    final message = got.singleWhere((m) => m.envelope.text == 'Hi :cat: :dog:');
    expect(message.envelope.emojis.keys, ['cat']);
    final shown = img.decodePng((await kumiko.repo.mediaBytes(message.envelope.emojis['cat']!))!)!;
    expect((shown.width, shown.getPixel(0, 0).a, shown.getPixel(64, shown.height ~/ 2).a), (CustomEmoji.size, 0, 255));

    // Edited once gone from the set, it keeps its picture.
    await phone.repo.changeEmojis((current) => {...current}..remove('cat'));
    await phone.waitForMessages(conv, (l) => l.any((m) => m.id == message.id));
    await phone.repo.editMessage(message.id, 'Bye :cat:');
    final edited = await kumiko.waitForMessages(
      conv,
      (l) => l.any((m) => m.id == message.id && m.envelope.text == 'Bye :cat:'),
    );
    expect(edited.singleWhere((m) => m.id == message.id).envelope.emojis['cat']?.hash, cat.hash);
    await laptop.repo.watchEmojis().firstWhere((e) => e.isEmpty).timeout(_timeout);

    // A group's: any member adds one, every member has it, and a line says who.
    await _becomeContacts(naoko, phone);
    final club = await phone.repo.createGroup('Club', [kumiko.me, naoko.me]);
    await kumiko.waitForConversation((s) => s.id == club);
    final owl = await kumiko.repo.uploadEmoji(image.path);
    await kumiko.repo.changeEmojis((current) => {...current, 'owl': owl}, conversationId: club);
    for (final device in [phone, laptop, naoko]) {
      final emojis = await device.repo
          .watchEmojis(conversationId: club)
          .firstWhere((e) => e.isNotEmpty)
          .timeout(_timeout);
      expect(emojis['owl']?.hash, owl.hash);
      final lines = await device.waitForMessages(club, (l) => l.any((m) => m.envelope.body['change'] == 'emojiAdded'));
      final line = lines.singleWhere((m) => m.envelope.body['change'] == 'emojiAdded');
      expect((line.senderId, line.envelope.body['name']), (kumiko.me, 'owl'));
    }

    // Renaming the group keeps them. Written there, :owl: is the group's;
    // anywhere else, nothing.
    await naoko.repo.renameGroup(club, 'Club Room');
    await phone.waitForConversation((c) => c.id == club && c.title == 'Club Room');
    expect((await phone.repo.watchEmojis(conversationId: club).first).keys, ['owl']);
    await phone.repo.sendText(club, 'Night :owl:');
    final night = await naoko.waitForMessages(club, (l) => _texts(l).contains('Night :owl:'));
    expect(night.singleWhere((m) => m.envelope.text == 'Night :owl:').envelope.emojis['owl']?.hash, owl.hash);
    await phone.repo.sendText(conv, 'Night :owl:');
    final elsewhere = await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Night :owl:'));
    expect(elsewhere.singleWhere((m) => m.envelope.text == 'Night :owl:').envelope.emojis, isEmpty);
  });

  test('GIFs travel as KLIPY links or as files already uploaded, and saved ones follow you', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final laptop = await _Device.signIn(server, 'sota');
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    // The server's KLIPY key, for signed-in apps.
    expect(await phone.repo.klipyApiKey(), 'test-klipy-key');
    const dance = RemoteMedia(
      provider: RemoteMedia.klipy,
      id: 'dance',
      url: 'https://static.klipy.com/ii/dance/md.webp',
      mime: 'image/webp',
      width: 360,
      height: 270,
      title: 'Dance',
    );

    // A GIF file, sent as a photo.
    final files = Directory.systemTemp.createTempSync('hanashi_gifs_');
    addTearDown(() => files.delete(recursive: true));
    final file = File('${files.path}/wave.gif')..writeAsBytesSync(img.encodeGif(img.Image(width: 30, height: 20)));
    final conv = await _becomeContacts(kumiko, phone);
    await phone.repo.sendAttachment(conv, path: file.path, name: 'wave.gif');
    final photo = (await kumiko.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l))).single.envelope;
    expect(photo.media!.mime, 'image/gif');

    // Kumiko saves it and sends it back as a GIF, with one from KLIPY.
    final uploaded = GifRef.media(photo.media!);
    await kumiko.repo.setGifSaved(uploaded, true);
    await kumiko.repo.sendGif(conv, uploaded);
    await kumiko.repo.sendGif(conv, const GifRef.remote(dance));
    final received = await phone.waitForMessages(conv, (l) => l.length == 3 && _allDecrypted(l));
    final [_, own, klipy] = [for (final m in received) m.envelope];
    expect((own.messageType, own.gif!.media!.hash), (MessageType.gif, photo.media!.hash));
    expect((await phone.repo.mediaBytes(own.gif!.media!))!, file.readAsBytesSync());
    expect((klipy.messageType, klipy.gif!.remote!.url, klipy.gif!.remote!.title), (MessageType.gif, dance.url, 'Dance'));

    // Saved GIFs reach the user's other devices.
    await phone.repo.setGifSaved(const GifRef.remote(dance), true);
    await phone.repo.setGifSaved(own.gif!, true);
    final onLaptop = await laptop.repo.watchSavedGifs().firstWhere((l) => l.length == 2).timeout(_timeout);
    expect([for (final g in onLaptop) g.key], [photo.media!.hash, 'klipy:dance']);
    await laptop.repo.setGifSaved(const GifRef.remote(dance), false);
    await phone.repo.watchSavedGifs().firstWhere((l) => l.length == 1).timeout(_timeout);
    // Also those that start later; the server holds only ciphertext.
    final tablet = await _Device.signIn(server, 'sota');
    final onTablet = await tablet.repo.watchSavedGifs().firstWhere((l) => l.isNotEmpty).timeout(_timeout);
    expect(onTablet.single.key, photo.media!.hash);
    final stored = await phone.api.accountData('gifs');
    expect(utf8.decode(base64.decode(stored!.data), allowMalformed: true), isNot(contains('sha256')));
  });

  group('contacts', () {
    test('asking and answering: nothing reaches anyone until they say yes', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final laptop = await _Device.signIn(server, 'sota');
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      await sota.repo.setDisplayName('Sota of Minato');
      await Future.wait([laptop.repo.started, kumiko.repo.started]);

      expect(await sota.repo.requestContact(kumiko.me), ContactState.outgoing);
      await kumiko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);
      await laptop.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.outgoing).timeout(_timeout);
      // Nothing but who asks: no chat yet, no name, no way to message them.
      expect(await kumiko.repo.watchConversations().first, isEmpty);
      expect((await kumiko.db.profileRow(sota.me))!.displayName, 'sota');
      await expectLater(sota.repo.openDirectConversation(kumiko.me), throwsStateError);

      await kumiko.repo.acceptContact(sota.me);
      final conv = await kumiko.repo.openDirectConversation(sota.me);
      await sota.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.accepted).timeout(_timeout);
      await laptop.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.accepted).timeout(_timeout);
      // Both now know who the other is, also without a word said.
      await _profileOf(kumiko, sota.me, (p) => p.displayName == 'Sota of Minato');
      await kumiko.repo.setDisplayName('Kyoyama Kumiko');
      for (final device in [sota, laptop]) {
        await _profileOf(device, kumiko.me, (p) => p.displayName == 'Kyoyama Kumiko');
      }
      expect(await kumiko.repo.watchMessages(conv).first, isEmpty);

      await sota.repo.sendText(conv, 'Hello!');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Hello!'));

      // A device added later has them all, from the encrypted contact list.
      final tablet = await _Device.signIn(server, 'sota');
      await tablet.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.accepted).timeout(_timeout);
      await _profileOf(tablet, kumiko.me, (p) => p.displayName == 'Kyoyama Kumiko');
    });

    test('one who asks is not told no, and two who ask at once become contacts', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      await Future.wait([sota.repo.started, kumiko.repo.started, naoko.repo.started]);

      await sota.repo.requestContact(kumiko.me);
      await kumiko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);
      await kumiko.repo.declineContact(sota.me);
      expect((await kumiko.repo.watchContacts().first).containsKey(sota.me), isFalse);
      expect((await sota.api.contacts()).single.state, ContactState.outgoing);

      await sota.repo.requestContact(naoko.me);
      await naoko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);
      expect(await naoko.repo.requestContact(sota.me), ContactState.accepted);
      await sota.repo.watchContacts().firstWhere((c) => c[naoko.me] == ContactState.accepted).timeout(_timeout);
      final conv = await naoko.repo.openDirectConversation(sota.me);
      await _chatOf(sota, conv);
    });

    test('a contact removed: the chat stays quiet, and they cannot read what you tell next', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      final conv = await _becomeContacts(kumiko, sota);
      final withNaoko = await _becomeContacts(naoko, sota);
      await _chatOf(kumiko, conv);
      await _chatOf(naoko, withNaoko);
      await sota.repo.setDisplayName('Before');
      await _profileOf(kumiko, sota.me, (p) => p.displayName == 'Before');
      await _profileOf(naoko, sota.me, (p) => p.displayName == 'Before');
      final oldKey = (await sota.db.profileRow(sota.me))!.profileKey!;

      await sota.repo.sendText(conv, 'Goodbye');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Goodbye'));
      await sota.repo.removeContact(kumiko.me);
      await kumiko.repo.watchContacts().firstWhere((c) => !c.containsKey(sota.me)).timeout(_timeout);
      // What was said is still there; nothing more can be.
      expect(_texts(await kumiko.repo.watchMessages(conv).first), contains('Goodbye'));
      await kumiko.repo.sendText(conv, 'Why?');
      final failed = await kumiko.waitForMessages(conv, (l) => l.any((m) => m.state == DeliveryState.failed));
      expect(failed.last.envelope.text, 'Why?');
      await expectLater(
        kumiko.api.acceptContact(sota.me),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_request')),
      );

      // The next change gets a new key, which Naoko gets and Kumiko does not.
      await sota.repo.setDisplayName('After');
      expect((await sota.db.profileRow(sota.me))!.profileKey, isNot(oldKey));
      await _profileOf(naoko, sota.me, (p) => p.displayName == 'After');
      expect((await kumiko.db.profileRow(sota.me))!.displayName, 'Before');
      final stored = ProfileRecord.fromJson((await kumiko.api.profile(sota.me))!, user: sota.me);
      await expectLater(stored.open(base64.decode(oldKey)), throwsA(isA<DecryptionFailed>()));

      // Friends again: the same chat, and they learn the new name.
      expect(await _becomeContacts(kumiko, sota), conv);
      await kumiko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.accepted).timeout(_timeout);
      await sota.repo.sendText(conv, 'Sorry');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Sorry'));
      await kumiko.repo.sendText(conv, 'It is fine');
      await sota.waitForMessages(conv, (l) => _texts(l).contains('It is fine'));
    });

    test('users of two servers that federate become contacts and chat, as on one server', () async {
      final (a, b) = await GoServer.pair();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final sota = await _Device.signIn(a, 'sota', register: true);
      final kumiko = await _Device.signIn(b, 'kumiko', register: true);
      expect((sota.me, kumiko.me), ('sota@a.test', 'kumiko@b.test'));
      await sota.repo.setDisplayName('Sota of Minato');
      await Future.wait([sota.repo.started, kumiko.repo.started]);

      expect(await sota.repo.requestContact(kumiko.me), ContactState.outgoing);
      await kumiko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);
      // Of another server, he goes by his whole ID until his own name is known.
      expect((await kumiko.db.profileRow(sota.me))!.displayName, 'sota@a.test');

      // Her app starts their chat on accepting; her server orders it, and his
      // has a copy.
      await kumiko.repo.acceptContact(sota.me);
      final conv = await kumiko.repo.openDirectConversation(sota.me);
      await sota.waitForConversation((c) => c.id == conv);
      expect(await sota.repo.openDirectConversation(kumiko.me), conv);
      await _profileOf(kumiko, sota.me, (p) => p.displayName == 'Sota of Minato');

      await sota.repo.sendText(conv, 'Hello from a.test');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Hello from a.test'));
      await kumiko.repo.sendText(conv, 'Hello from b.test');
      await sota.waitForMessages(conv, (l) => _texts(l).contains('Hello from b.test'));
      expect(_allDecrypted(await sota.repo.watchMessages(conv).first), isTrue);

      // A new device of his joins by itself, through her server.
      final laptop = await _Device.signIn(a, 'sota');
      await laptop.waitForConversation((c) => c.id == conv);
      await kumiko.repo.sendText(conv, 'Hello, laptop');
      await laptop.waitForMessages(conv, (l) => _texts(l).contains('Hello, laptop'));
      await laptop.repo.sendText(conv, 'From the laptop');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('From the laptop'));
    });

    test('a file sent across servers comes from the sender\'s server, through the reader\'s', () async {
      final (a, b) = await GoServer.pair();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final sota = await _Device.signIn(a, 'sota', register: true);
      final kumiko = await _Device.signIn(b, 'kumiko', register: true);
      await Future.wait([sota.repo.started, kumiko.repo.started]);
      await sota.repo.requestContact(kumiko.me);
      await kumiko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);
      await kumiko.repo.acceptContact(sota.me);
      final conv = await kumiko.repo.openDirectConversation(sota.me);
      await sota.waitForConversation((c) => c.id == conv);

      final files = Directory.systemTemp.createTempSync('hanashi_files_');
      addTearDown(() => files.delete(recursive: true));
      final photo = File('${files.path}/cat.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 600, height: 400)..clear(img.ColorRgb8(200, 120, 160))));
      await sota.repo.sendAttachment(conv, path: photo.path, name: 'cat.png');

      final received = await kumiko.waitForMessages(conv, (l) => l.length == 1 && _allDecrypted(l));
      final ref = received.single.envelope.media!;
      expect((ref.host, ref.thumb!.host), ('a.test', 'a.test'));
      expect((await kumiko.repo.mediaBytes(ref))!, photo.readAsBytesSync());
      expect(img.decodeJpg((await kumiko.repo.mediaBytes(ref.thumb!))!), isNotNull);
    });

    test('a group across three servers: one of each joins, talks, and shares a photo', () async {
      final servers = await GoServer.federating(['a.test', 'b.test', 'c.test']);
      for (final server in servers) {
        addTearDown(server.dispose);
      }
      final [a, b, c] = servers;
      final sota = await _Device.signIn(a, 'sota', register: true);
      final kumiko = await _Device.signIn(b, 'kumiko', register: true);
      final hiroko = await _Device.signIn(c, 'hiroko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await kumiko.waitForConversation((s) => s.id == club && s.title == 'Club');
      await sota.repo.sendText(club, 'From a.test');
      await kumiko.repo.sendText(club, 'From b.test');
      await kumiko.waitForMessages(club, (l) => _texts(l).contains('From a.test'));

      // Kumiko, of b.test, adds Hiroko, of c.test, which had nothing of the club,
      // through a.test; she shares the history with her.
      await _becomeContacts(hiroko, kumiko);
      await kumiko.repo.addMember(club, hiroko.me);
      await hiroko.waitForConversation((s) => s.id == club && s.title == 'Club');
      await hiroko.repo.loadOlderMessages(club);
      await hiroko.waitForMessages(club, (l) => _texts(l).contains('From a.test') && _texts(l).contains('From b.test'));

      await hiroko.repo.sendText(club, 'From c.test');
      for (final device in [sota, kumiko]) {
        await device.waitForMessages(club, (l) => _texts(l).contains('From c.test'));
      }

      // Her photo, kept on c.test, opened on a.test and b.test.
      final files = Directory.systemTemp.createTempSync('hanashi_files_');
      addTearDown(() => files.delete(recursive: true));
      final photo = File('${files.path}/club.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 320, height: 200)..clear(img.ColorRgb8(120, 200, 160))));
      await hiroko.repo.sendAttachment(club, path: photo.path, name: 'club.png');
      for (final device in [sota, kumiko]) {
        final received = await device.waitForMessages(club, (l) => l.any((m) => m.envelope.media != null) && _allDecrypted(l));
        final ref = received.firstWhere((m) => m.envelope.media != null).envelope.media!;
        expect(ref.host, 'c.test');
        expect((await device.repo.mediaBytes(ref))!, photo.readAsBytesSync());
      }
    });

    test('a chat across servers started by the one whose server does not order it', () async {
      final (a, b) = await GoServer.pair();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final sota = await _Device.signIn(a, 'sota', register: true);
      final kumiko = await _Device.signIn(b, 'kumiko', register: true);
      await Future.wait([sota.repo.started, kumiko.repo.started]);
      // She asks and he accepts: his app starts it, at her server.
      await kumiko.repo.requestContact(sota.me);
      await sota.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.incoming).timeout(_timeout);
      await sota.repo.acceptContact(kumiko.me);
      final conv = await sota.repo.openDirectConversation(kumiko.me);
      await kumiko.waitForConversation((c) => c.id == conv);
      await sota.repo.sendText(conv, 'Started from a.test');
      await kumiko.waitForMessages(conv, (l) => _texts(l).contains('Started from a.test'));
      await kumiko.repo.sendText(conv, 'Ordered at b.test');
      await sota.waitForMessages(conv, (l) => _texts(l).contains('Ordered at b.test'));
    });

    test('two contacts have one chat between them, however each comes to open it', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      await Future.wait([sota.repo.started, kumiko.repo.started]);
      await sota.repo.requestContact(kumiko.me);
      await kumiko.repo.watchContacts().firstWhere((c) => c[sota.me] == ContactState.incoming).timeout(_timeout);

      // Kumiko's app starts it on accepting; Sota opens it as soon as they
      // are contacts, most likely before it exists, and starts one too.
      await kumiko.repo.acceptContact(sota.me);
      await sota.repo.watchContacts().firstWhere((c) => c[kumiko.me] == ContactState.accepted).timeout(_timeout);
      final (fromSota, fromKumiko) = await (
        sota.repo.openDirectConversation(kumiko.me),
        kumiko.repo.openDirectConversation(sota.me),
      ).wait;
      expect(fromSota, fromKumiko);
      expect((await sota.api.snapshot()).conversations.map((c) => c.conversation.id), [fromSota]);

      await sota.repo.sendText(fromSota, 'from sota');
      await kumiko.waitForMessages(fromSota, (l) => _texts(l).contains('from sota'));
      await kumiko.repo.sendText(fromSota, 'from kumiko');
      await sota.waitForMessages(fromSota, (l) => _texts(l).contains('from kumiko'));
    });

    test("a Welcome from someone the user's own list does not have is not joined, whatever the server says", () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final stranger = await _Device.signIn(server, 'stranger', register: true);
      await Future.wait([sota.repo.started, stranger.repo.started]);
      // A malicious server claims Sota asked.
      await server.sql([
        "INSERT INTO contacts (owner, peer, state, updated_at) VALUES ('${sota.me}', '${stranger.me}', 'requested', 1)",
      ]);
      await stranger.repo.acceptContact(sota.me);
      final conv = await stranger.repo.openDirectConversation(sota.me);
      await _eventually(() async => await sota.db.isRefused(conv), reason: 'Sota refuses it');
      expect(await sota.repo.groups.mls.hasGroup(conv), isFalse);
      expect(await sota.repo.watchConversations().first, isEmpty);
      // The server says they are contacts; Sota's own list says otherwise.
      expect((await sota.api.contacts()).single.state, ContactState.accepted);
      expect(await sota.repo.watchContacts().first, isEmpty);
      await stranger.repo.sendText(conv, 'Buy my stuff');
      await _eventually(() async => (await stranger.leavesOf(conv)).isNotEmpty, reason: 'sent');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await sota.repo.watchConversations().first, isEmpty);
    });
  });

  group('group state', () {
    test('someone added knows the group and everyone in it at once, with no message read', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      await kumiko.repo.setDisplayName('Kyoyama Kumiko');
      await sota.repo.setDisplayName('Sota of Minato');
      final club = await _newGroup(sota, 'After School Sweets', [kumiko]);
      await _chatOf(kumiko, club);
      final file = File('${sota.dir.path}/club.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(240, 150, 170))));
      await sota.repo.setGroupPicture(club, file.path);
      await kumiko.waitForConversation((c) => c.id == club && c.picture != null);
      // Kumiko's own key reaches the roster before anyone new comes.
      await _eventually(() async => (await sota.repo.groups.heldState(club))!.roster.containsKey(kumiko.me) ||
          (await sota.db.profileRow(kumiko.me))!.profileKey != null, reason: "Sota has Kumiko's key");

      await _becomeContacts(naoko, sota);
      await sota.repo.addMember(club, naoko.me, shareHistory: false);

      final seen = await naoko.waitForConversation((c) => c.id == club && c.picture != null);
      expect((seen.title, seen.conversation.isGroup), ('After School Sweets', true));
      await _profileOf(naoko, kumiko.me, (p) => p.displayName == 'Kyoyama Kumiko');
      await _profileOf(naoko, sota.me, (p) => p.displayName == 'Sota of Minato');
      // All of that with none of the group's messages: the only ones are the
      // lines saying who made the group and who added Naoko.
      expect(await naoko.db.undecrypted(club), isEmpty);
      expect((await naoko.api.history(club)).messages, hasLength(2));
      // Everyone agrees, and Naoko's key finds its way to the others.
      expect((await naoko.db.groupStateRow(club))!.hash, (await sota.db.groupStateRow(club))!.hash);
      await _profileOf(kumiko, naoko.me, (_) => true);
    });

    test("a group's details reach a brand-new device, however long ago they changed", () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await _chatOf(kumiko, club);
      final file = File('${sota.dir.path}/club.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(240, 150, 170))));
      await sota.repo.setGroupPicture(club, file.path);
      for (var i = 0; i < 32; i++) {
        await sota.repo.sendText(club, 'm$i');
      }
      await kumiko.waitForMessages(club, (l) => _texts(l).contains('m31'));

      // It joins by itself, and cannot read what came before; a member seals it.
      final laptop = await _Device.signIn(server, 'kumiko');
      final seen = await laptop.waitForConversation((c) => c.id == club && c.picture != null && c.title == 'Club');
      expect(seen.picture!.hash, (await sota.waitForConversation((c) => c.id == club)).picture!.hash);
      expect((await laptop.repo.watchMessages(club).first).map((m) => m.envelope.text), isNot(contains('m0')));
    });

    test('changes made at once: every device ends up the same, and neither is lost', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await _chatOf(kumiko, club);
      final file = File('${sota.dir.path}/club.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(240, 150, 170))));

      await Future.wait([kumiko.repo.renameGroup(club, 'Club Room'), sota.repo.setGroupPicture(club, file.path)]);

      for (final device in [sota, kumiko]) {
        await device.waitForConversation((c) => c.id == club && c.title == 'Club Room' && c.picture != null);
      }
      expect((await sota.db.groupStateRow(club))!.hash, (await kumiko.db.groupStateRow(club))!.hash);
      // Each says who did it, as MLS says, and not the server.
      for (final device in [sota, kumiko]) {
        final lines = await device.waitForMessages(
          club,
          (l) => l.any((m) => m.envelope.body['change'] == 'renamed') && l.any((m) => m.envelope.body['change'] == 'picture'),
        );
        expect(lines.firstWhere((m) => m.envelope.body['change'] == 'renamed').senderId, kumiko.me);
        expect(lines.firstWhere((m) => m.envelope.body['change'] == 'picture').senderId, sota.me);
      }
    });

    test('a state that is not what the commits pin does not count', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await _chatOf(kumiko, club);
      await sota.repo.renameGroup(club, 'Club Room');
      await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club Room');

      // A new device joins by itself: its commit has no state, which a rogue
      // member then seals with another name before anyone else does.
      final watcher = sota.repo.groups;
      final laptop = await _Device.signIn(server, 'kumiko', verify: false);
      await server.sql(["UPDATE group_info SET state = NULL WHERE conv_id = '$club'"]);
      final forged = GroupState.create(title: 'Forged');
      final epoch = await watcher.mls.epoch(club);
      await sota.api.putGroupState(
        club,
        epoch: epoch,
        sealed: await forged.seal(await watcher.mls.exporterSecret(club, GroupState.secretLabel), conv: club, epoch: epoch),
      );
      // Those who applied the commits keep what those pin.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final device in [sota, kumiko]) {
        expect((await _chatOf(device, club)).title, 'Club Room');
      }
      await laptop.close();

      // A commit brings it right for all, also for one who believed otherwise.
      final tablet = await _Device.signIn(server, 'sota');
      await tablet.waitForConversation((c) => c.id == club);
      await kumiko.repo.renameGroup(club, 'Club Room 2');
      for (final device in [sota, kumiko, tablet]) {
        await device.waitForConversation((c) => c.id == club && c.title == 'Club Room 2');
      }
    });

    test('someone who leaves and comes back goes by what the group is now', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await _chatOf(kumiko, club);
      await kumiko.repo.leaveGroup(club);
      await _eventually(() async => await kumiko.db.conversation(club) == null, reason: 'gone for Kumiko');
      await _eventually(
        () async => !(await sota.leaves(club)).any((leaf) => leaf.startsWith(kumiko.me)),
        reason: "Kumiko's devices removed",
      );
      await sota.repo.renameGroup(club, 'Club Room');
      await sota.repo.addMember(club, kumiko.me, shareHistory: false);
      await kumiko.waitForConversation((c) => c.id == club && c.title == 'Club Room');
      await kumiko.repo.renameGroup(club, 'Club Room 2');
      await sota.waitForConversation((c) => c.id == club && c.title == 'Club Room 2');
    });

    test('someone removed cannot open the state of later epochs', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      final club = await _newGroup(sota, 'Club', [kumiko, naoko]);
      await _chatOf(naoko, club);
      await _chatOf(kumiko, club);
      await _eventually(() async => await naoko.repo.groups.heldState(club) != null, reason: 'Naoko holds it');
      final secret = await naoko.repo.groups.mls.exporterSecret(club, GroupState.secretLabel);

      await naoko.repo.leaveGroup(club);
      for (final device in [sota, kumiko]) {
        await _eventually(
          () async => !(await device.leaves(club)).any((leaf) => leaf.startsWith(naoko.me)),
          reason: "Naoko's devices removed",
        );
      }
      await sota.repo.renameGroup(club, 'Secret plans');
      await kumiko.waitForConversation((c) => c.id == club && c.title == 'Secret plans');
      final info = await sota.api.groupInfo(club);
      await expectLater(
        GroupState.open(info.state!, secret, conv: club, epoch: info.epoch),
        throwsA(isA<DecryptionFailed>()),
      );
      expect(utf8.decode(info.data, allowMalformed: true), isNot(contains('Secret plans')));
      expect(utf8.decode(base64.decode(info.state!), allowMalformed: true), isNot(contains('Secret plans')));
    });

    test('the server cannot read titles or names, in anything it stores', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      await sota.repo.setDisplayName('Sota of Minato');
      final club = await _newGroup(sota, 'After School Sweets', [kumiko]);
      await _chatOf(kumiko, club);
      await sota.repo.renameGroup(club, 'After School Sweets 2');
      final info = await kumiko.api.groupInfo(club);
      final everything = [
        jsonEncode((await kumiko.api.sync(0)).events.map((e) => e.toJson()).toList()),
        jsonEncode(await kumiko.api.profile(sota.me)),
        utf8.decode(info.data, allowMalformed: true),
        utf8.decode(base64.decode(info.state!), allowMalformed: true),
      ].join();
      for (final secret in ['After School', 'Sota of Minato']) {
        expect(everything, isNot(contains(secret)));
      }
    });
  });

  group('profiles', () {
    test('the server cannot bring back an old profile, nor forge one', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      await _becomeContacts(kumiko, sota);
      await sota.repo.setDisplayName('First');
      await _profileOf(kumiko, sota.me, (p) => p.displayName == 'First');
      final old = (await sota.api.profile(sota.me))!;
      await sota.repo.setDisplayName('Second');
      await _profileOf(kumiko, sota.me, (p) => p.displayName == 'Second');
      final version = (await kumiko.db.profileRow(sota.me))!.version;

      Future<void> serve(Map<String, Object?> record) => server.sql([
        "UPDATE profiles SET version = ${record['version']}, ct = '${record['ct']}', signature = '${record['signature']}' "
            "WHERE user_id = '${sota.me}'",
      ]);
      Future<void> kumikoLooks() async {
        await kumiko.db.noteWantedProfile(sota.me, version + 100);
        await kumiko.restart();
        await kumiko.online();
        await _eventually(() async => true, reason: 'restarted');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      // An older one, properly signed.
      await serve(old);
      await kumikoLooks();
      expect((await kumiko.db.profileRow(sota.me))!.displayName, 'Second');

      // A newer one that Sota did not sign, opened by the right key or not.
      final key = base64.decode((await sota.db.profileRow(sota.me))!.profileKey!);
      final forger = await IdentityKeyPair.fromSeed(randomBytes(32));
      final forged = await ProfileRecord.seal(
        const ProfileDocument(displayName: 'Forged'),
        user: sota.me,
        version: version + 1,
        key: key,
        signer: forger,
      );
      await serve(forged.toJson());
      await kumikoLooks();
      final row = (await kumiko.db.profileRow(sota.me))!;
      expect((row.displayName, row.version), ('Second', version));
    });

    test('a wrong key in a roster costs a profile at most, and its owner sets it right', () async {
      final server = await _startServer();
      final sota = await _Device.signIn(server, 'sota', register: true);
      final kumiko = await _Device.signIn(server, 'kumiko', register: true);
      final naoko = await _Device.signIn(server, 'naoko', register: true);
      await kumiko.repo.setDisplayName('Kyoyama Kumiko');
      final club = await _newGroup(sota, 'Club', [kumiko]);
      await _chatOf(kumiko, club);
      await _becomeContacts(naoko, sota);
      await _eventually(() async => (await sota.db.profileRow(kumiko.me))!.profileKey != null, reason: "Sota has Kumiko's key");

      // Sota's device says something else opens Kumiko's profile.
      await sota.db.setGroupState(club, roster: {kumiko.me: base64.encode(randomBytes(32))});
      await sota.repo.addMember(club, naoko.me, shareHistory: false);
      await naoko.waitForConversation((c) => c.id == club && c.title == 'Club');

      // Kumiko sees the roster lacks her key, and tells it. The wrong key was
      // never taken for hers: it opens nothing.
      await _profileOf(naoko, kumiko.me, (p) => p.displayName == 'Kyoyama Kumiko');
      expect((await naoko.db.profileRow(kumiko.me))!.profileKey, (await kumiko.db.profileRow(kumiko.me))!.profileKey);
    });
  });

  test('a push, with the app closed: a device seals a state others wait for', () async {
    final server = await _startServer();
    final sota = await _Device.signIn(server, 'sota', register: true);
    final kumiko = await _Device.signIn(server, 'kumiko', register: true);
    final club = await _newGroup(sota, 'Club', [kumiko]);
    await _chatOf(kumiko, club);
    await _eventually(() async => await kumiko.repo.groups.heldState(club) != null, reason: 'Kumiko holds it');
    // Nobody else is around when a new device of Sota's joins by itself.
    await kumiko.repo.dispose();
    await sota.repo.dispose();
    final laptop = await _Device.signIn(server, 'sota');
    await _eventually(() async => (await laptop.leaves(club)).isNotEmpty, reason: 'the laptop joins');
    expect((await laptop.api.groupInfo(club)).state, isNull);
    expect(await laptop.repo.groups.heldState(club), isNull);

    await syncForPush(db: kumiko.db, store: kumiko.store, storage: kumiko.storage, notifier: FakeDisplay());
    await laptop.waitForConversation((c) => c.id == club && c.title == 'Club');
  });

  test('two devices changing the same account data at once both keep their change', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    final laptop = await _Device.signIn(server, 'sota');
    await Future.wait([phone.repo.started, laptop.repo.started]);
    const dance = RemoteMedia(
      provider: RemoteMedia.klipy,
      id: 'dance',
      url: 'https://static.klipy.com/ii/dance/md.webp',
      mime: 'image/webp',
      width: 360,
      height: 270,
    );
    const wave = RemoteMedia(
      provider: RemoteMedia.klipy,
      id: 'wave',
      url: 'https://static.klipy.com/ii/wave/md.webp',
      mime: 'image/webp',
      width: 360,
      height: 270,
    );
    await Future.wait([
      phone.repo.setGifSaved(const GifRef.remote(dance), true),
      laptop.repo.setGifSaved(const GifRef.remote(wave), true),
    ]);
    for (final device in [phone, laptop]) {
      final gifs = await device.repo.watchSavedGifs().firstWhere((l) => l.length == 2).timeout(_timeout);
      expect({for (final g in gifs) g.key}, {'klipy:dance', 'klipy:wave'});
    }
  });

  test('the server cannot bring back old account data', () async {
    final server = await _startServer();
    final phone = await _Device.signIn(server, 'sota', register: true);
    await phone.repo.started;
    const dance = RemoteMedia(
      provider: RemoteMedia.klipy,
      id: 'dance',
      url: 'https://static.klipy.com/ii/dance/md.webp',
      mime: 'image/webp',
      width: 360,
      height: 270,
    );
    await phone.repo.setGifSaved(const GifRef.remote(dance), true);
    final old = (await phone.api.accountData('gifs'))!;
    await phone.repo.setGifSaved(const GifRef.remote(dance), false);
    await server.sql([
      "UPDATE account_data SET data = '${old.data}', version = version + 1 WHERE user_id = '${phone.me}' AND name = 'gifs'",
    ]);
    await phone.restart();
    await phone.online();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await phone.repo.watchSavedGifs().first, isEmpty);
    // Nor does it get in the way of what comes next.
    await phone.repo.setGifSaved(const GifRef.remote(dance), true);
    await phone.repo.watchSavedGifs().firstWhere((l) => l.length == 1).timeout(_timeout);
  });
}

/// The conversation as [device] sees it, once it is in its list.
Future<ConversationSummary> _chatOf(_Device device, String conv) => device.waitForConversation((c) => c.id == conv);

/// Stands in for a UnifiedPush distributor or FCM: counts the pushes the
/// server sends.
class _PushService {
  _PushService._(this._server) {
    _server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.created;
      await request.response.close();
      received++;
      _next?.complete();
      _next = null;
    });
  }

  final HttpServer _server;
  var received = 0;
  Completer<void>? _next;

  static Future<_PushService> start() async {
    final service = _PushService._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    addTearDown(() => service._server.close(force: true));
    return service;
  }

  String get url => 'http://${_server.address.address}:${_server.port}';

  /// Completes once [count] pushes arrived.
  Future<void> waitFor(int count) async {
    while (received < count) {
      await (_next ??= Completer<void>()).future;
    }
  }
}
