import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../diagnostics/app_log.dart';
import '../e2ee/account_data.dart';
import '../e2ee/attestation.dart';
import '../e2ee/content.dart';
import '../e2ee/encryption_identity.dart';
import '../e2ee/file_cipher.dart';
import '../e2ee/group_manager.dart';
import '../e2ee/key_backup.dart';
import '../e2ee/key_directory.dart';
import '../e2ee/mls_service.dart';
import '../e2ee/primitives.dart';
import '../e2ee/profile_record.dart';
import 'account.dart';
import 'attachments.dart';
import 'chat_repository.dart';
import 'custom_emojis.dart';
import 'local/database.dart';
import 'media_cache.dart';
import 'models.dart';
import 'packs/content_package.dart';
import 'packs/sticker_pack.dart';
import 'packs/sticker_pack_file.dart';
import 'packs/sticker_pack_store.dart';
import 'remote/api_client.dart';
import 'remote/link_previews.dart';
import 'remote/socket_client.dart';
import 'sync_lock.dart';

const _log = Log('sync');

/// [ChatRepository] backed by the server, with the local database as the
/// source for everything the UI shows. Everything that leaves the device is
/// end-to-end encrypted with MLS (see [GroupManager]).
///
/// Sync on every (re)connect: open the WebSocket first and buffer its live
/// events, take Welcomes from the device inbox, catch up with `GET /sync` (or
/// a snapshot on first run), apply the buffer, then apply live events
/// directly. Events are applied one by one, in order: MLS commits and
/// messages depend on each other. Because seqs are global, gaps are normal.
///
/// While running it holds the device's [SyncLock]; on Android a push that
/// arrives while the app is closed syncs once ([syncOnce]) in a headless
/// engine instead.
class ServerChatRepository implements ChatRepository {
  ServerChatRepository({
    required this.db,
    required this.account,
    required this.identity,
    required this.onSignedOut,
    required Directory mediaDir,
    required Directory packsDir,
    required this.tempDir,
    this.mlsDbPath = ':memory:',
    this.probeVideo,
    this.clock = DateTime.now,
    this.onSynced,
    this.onVerificationMessage,
    this.onUnverified,
    SyncLock? lock,
    ApiClient? api,
  }) : api = api ?? ApiClient(account.serverUrl, token: account.token),
       _lock = lock ?? SyncLock(account.deviceId),
       _packStore = StickerPackStore(packsDir) {
    media = MediaCache(mediaDir, this.api);
    // Files of deleted messages do not stay on the device.
    db.onMediaDeleted = _forgetMedia;
    db.me = account.userId;
    _socket = SocketClient(
      uri: this.api.webSocketUri,
      token: account.token,
      onReady: _onReady,
      onEvent: _onEvent,
      onInbox: _onInbox,
      onRevoked: _signedOut,
      // Another device backed up keys: waiting messages may be readable now.
      onBackup: () => unawaited(_restoreKeys()),
      onTyping: _onTyping,
      // Another device of the user verified someone.
      onTrust: () => unawaited(_serial(refreshTrust).catchError((Object _) {})),
      // Another device of the user changed something they share.
      onAccountData: (name) {
        if (name == _profileData) unawaited(_loadOwnProfile().catchError((Object _) {}));
        if (name == _contactsData) unawaited(_serial(_loadContactList).catchError((Object _) {}));
        if (name == _gifsData) unawaited(_loadSavedGifs().catchError((Object _) {}));
        if (name == _stickersData) unawaited(_loadSavedStickers().catchError((Object _) {}));
        if (name == _packsData) unawaited(_loadPacks().catchError((Object _) {}));
        if (name == _emojisData) unawaited(_loadMyEmojis().catchError((Object _) {}));
        if (name == _chatsData) unawaited(_loadChatSettings().catchError((Object _) {}));
      },
      onPresence: _onPresence,
      onCall: _takeCall,
    );
    // Who is online is known only while connected.
    _offline = _socket.statusChanges.listen((status) {
      if (status == ConnectionStatus.offline || status == ConnectionStatus.updateRequired) {
        _onPresence(const {}, all: true);
      }
    });
  }

  final AppDatabase db;
  final Account account;
  final ApiClient api;

  /// This device's verified encryption identity.
  final EncryptionIdentity identity;

  /// Where the MLS state lives (':memory:' for tests).
  final String mlsDbPath;

  /// Called when the server no longer accepts this device's token.
  final void Function() onSignedOut;

  /// Scratch space for thumbnails being prepared.
  final Directory tempDir;

  /// Reads video size, duration and a frame; needs the platform player.
  final VideoProbe? probeVideo;

  /// Decides when keys are due for rotation.
  final DateTime Function() clock;

  /// Called after new events were applied or a conversation was read, e.g.
  /// to update notifications.
  final Future<void> Function()? onSynced;

  /// Emoji verification messages from other devices (see `VerificationService`).
  final Future<void> Function(InboxItem item)? onVerificationMessage;

  /// Called once this device turns out not to be verified with the account's
  /// current key (it was reset elsewhere); it then stays out of all groups.
  final void Function()? onUnverified;
  var _toldUnverified = false;
  final SyncLock _lock;
  StreamSubscription<void>? _wakeups;
  late final MediaCache media;
  ServerInfo? _serverInfo;

  late final SocketClient _socket;
  MlsService? _mls;
  late KeyDirectory keys;
  late GroupManager groups;
  Future<void>? _started;

  final _buffer = <SyncEvent>[];
  var _live = false;
  var _disposed = false;
  Future<void> _queue = Future.value();
  final _pendingReads = <String, int>{};
  final _loadingHistory = <String>{};
  var _flushing = false;
  var _flushAgain = false;

  // Key backup (see [_uploadBackups]).
  KeyBackupCipher? _backup;
  AccountData? _accountData;
  String? _ownIdentityKey;
  int? _backupVersion;
  var _backupStale = false;
  Timer? _backupTimer;
  Future<void>? _uploading;
  var _backingUp = false;
  Future<void> _restoring = Future.value();
  var _restoreQueued = false;
  Future<void> _verifications = Future.value();

  /// Group upkeep that found another device committing, by conversation.
  final _upkeepRetries = <String, Timer>{};

  /// Conversations whose messages the server refused for their epoch.
  final _epochChecks = <String, Timer>{};

  /// Conversations waiting to see whether another member seals their state.
  final _sealChecks = <String, Timer>{};

  /// The epoch in which this device last told each conversation its profile
  /// key, while that has not come back in a group state.
  final _announcedAt = <String, int>{};

  /// Syncing once for a push: nothing runs later, so nothing waits.
  var _once = false;
  final _random = Random();

  // Typing indicators: who is typing where, until when.
  final _typing = <String, Map<String, Timer>>{};
  final _typingChanges = StreamController<String>.broadcast();
  final _typingSent = <String, DateTime>{};
  static const _typingShownFor = Duration(seconds: 6);
  static const _typingResend = Duration(seconds: 3);

  // Presence (see [watchPresence]).
  final _presence = <String, Presence>{};
  var _presenceMode = PresenceMode.auto;
  final _presenceChanges = StreamController<void>.broadcast();
  late final StreamSubscription<ConnectionStatus> _offline;
  var _active = true;

  // Profile cards (see [_fetchCards]).
  Future<void> _fetchingCards = Future.value();
  var _cardsQueued = false;

  @override
  String get me => account.userId;

  /// Waits for the sync lock, opens the encryption state, then connects.
  void start() => _started = _start();

  /// Completes once the repository is running (or failed to start).
  Future<void> get started => _started ?? Future.value();

  Future<void> _start() async {
    // A push may be syncing in a headless engine right now; it is quick.
    if (!await _lock.acquire(cancelled: () => _disposed)) return;
    // A push that reaches another engine asks us to catch up at once.
    _wakeups = _lock.wakeups.listen((_) => _socket.reconnectNow());
    await _openState();
    if (!_disposed) _socket.start();
  }

  /// Catches up once over HTTP, without a socket: for a push that arrives
  /// while the app is closed. Returns false, after asking the other engine
  /// to sync, if one already holds the lock. Not for use with [start].
  Future<bool> syncOnce() async {
    _once = true;
    while (!_lock.tryAcquire()) {
      // Not when the holder turned out to be gone: then the lock is free now.
      if (_disposed || await SyncLock.wakeHolder(account.deviceId)) return false;
    }
    var again = true;
    // Pushes that arrive meanwhile ask for another round.
    final wakeups = _lock.wakeups.listen((_) => again = true);
    try {
      await _openState();
      await _loadNotificationState();
      while (again && !_disposed) {
        again = false;
        await _serial(_catchUp);
      }
    } finally {
      await wakeups.cancel();
    }
    await _notifySynced();
    return true;
  }

  Future<void> _openState() async {
    _log.info('Opening $me on device ${account.deviceId} (${account.serverUrl})');
    final secrets = await identity.localSecrets();
    if (secrets == null) throw StateError('This device is not verified');
    final ownIdentity = await IdentityKeyPair.fromSeed(secrets.identitySeed);
    _ownIdentityKey = ownIdentity.publicKeyBase64;
    _backup = await KeyBackupCipher.forSecret(secrets.backupSecret);
    _accountData = AccountData(
      api: api,
      cipher: await AccountDataCipher.forSecret(secrets.backupSecret, me),
      // Per identity: a reset of the account's keys starts them over.
      loadSequence: (name) async =>
          int.tryParse(await db.getValue('account.seq.${ownIdentity.publicKeyBase64}.$name') ?? '') ?? 0,
      saveSequence: (name, sequence) => db.setValue('account.seq.${ownIdentity.publicKeyBase64}.$name', '$sequence'),
    );
    final mls = _mls = await MlsService.open(
      dbPath: mlsDbPath,
      dbKey: await identity.mlsDatabaseKey(),
      signer: await identity.deviceSigner(),
      userId: me,
      deviceId: account.deviceId,
    );
    keys = KeyDirectory(api: api, db: db, me: me, ownIdentityKey: ownIdentity.publicKeyBase64);
    groups = GroupManager(
      mls: mls,
      keys: keys,
      api: api,
      db: db,
      me: me,
      deviceId: account.deviceId,
      clock: clock,
      ownProfileKey: () async => (await db.profileRow(me))?.profileKey,
      refreshContacts: _loadContactList,
      onCommitUnsettled: _retryUpkeep,
      onOwnLine: (line) => unawaited(send(PendingMessage(line))),
      onRetryLater: (conv, after) => _retryUpkeep(conv, after: after),
      onEpoch: _onEpoch,
    );
    // Others can add this device as soon as it shows up online.
    try {
      await groups.ensureKeyPackages();
    } on ApiException {
      // Offline; retried after connecting.
    }
  }

  /// Stops syncing and closes the encryption state. Safe to call again.
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void>? _disposing;

  Future<void> _dispose() async {
    // The keys of the last few messages may still wait for their batch.
    if (!_disposed && _backupTimer != null) {
      await flushKeyBackup().timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    _disposed = true;
    _backupTimer?.cancel();
    for (final timer in [..._upkeepRetries.values, ..._epochChecks.values, ..._sealChecks.values]) {
      timer.cancel();
    }
    for (final users in _typing.values) {
      for (final timer in users.values) {
        timer.cancel();
      }
    }
    await _typingChanges.close();
    await _savedGifChanges.close();
    await _savedStickerChanges.close();
    await _packChanges.close();
    await _callChanges.close();
    for (final keys in _callKeys.values.expand((calls) => calls.values).toList()) {
      await keys.close();
    }
    await _myEmojiChanges.close();
    await _offline.cancel();
    await _presenceChanges.close();
    await _socket.stop();
    await _started?.catchError((Object _) {});
    await _queue;
    await _uploading?.catchError((Object _) {});
    await _verifications;
    await _wakeups?.cancel();
    await _mls?.close();
    // Only now may another engine open the MLS state.
    await _lock.close();
    // Reading waiting messages and fetching profile cards use no MLS state,
    // but downloads that can take long: closing the connections ends them,
    // so the next engine never waits for them.
    api.close();
    await _restoring.catchError((Object _) {});
    await _fetchingCards.catchError((Object _) {});
    await _fetchingPacks.catchError((Object _) {});
    if (db.onMediaDeleted == _forgetMedia) db.onMediaDeleted = null;
  }

  void _forgetMedia(String hash) => unawaited(media.remove(hash));

  Future<void> _notifySynced() async {
    _scheduleBackup();
    unawaited(_fetchCards());
    try {
      await onSynced?.call();
    } catch (_) {
      // Notifications are best effort.
    }
  }

  /// Runs database and MLS work strictly in order.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _onReady() async {
    _socket.sendPresence(active: _active);
    _live = false;
    _buffer.clear();
    await _serial(() async {
      await _catchUp();
      try {
        final cursor = await db.cursor();
        await _applyInOrder([..._buffer.where((e) => e.seq > cursor)]);
        _buffer.clear();
        _live = true;
      } on ApiException catch (e) {
        if (e.isUnauthorized) _signedOut();
        rethrow;
      }
      await _maintainGroups();
      await _afterGroupWork();
      for (final MapEntry(key: conv, value: upTo) in [..._pendingReads.entries]) {
        _pendingReads.remove(conv);
        unawaited(_sendReadMarker(conv, upTo));
      }
      unawaited(flushOutbox());
    });
    await _notifySynced();
    // Messages from before this device could read them (e.g. a new device).
    unawaited(_restoreKeys());
    unawaited(_serial(refreshTrust).catchError((Object _) {}));
    unawaited(_serial(_refreshProfiles).catchError((Object _) {}));
    unawaited(_loadSavedGifs().catchError((Object _) {}));
    unawaited(_loadSavedStickers().catchError((Object _) {}));
    unawaited(_loadPacks().catchError((Object _) {}));
    unawaited(_loadMyEmojis().catchError((Object _) {}));
    // Call frames sent while this device was away are lost.
    unawaited(_refreshCalls().catchError((Object _) {}));
    unawaited(_loadChatSettings().catchError((Object _) {}));
  }

  /// Takes Welcomes from the inbox, then fetches and applies everything
  /// since the cursor (or a snapshot on first run).
  Future<void> _catchUp() async {
    try {
      _serverInfo ??= await api.serverInfo();
      // Who may add this device to a group, and what it tells them about itself.
      await _loadContacts();
      await _ensureOwnProfile();
      // Welcomes first, so the messages that follow them can be decrypted.
      await _processInbox(await api.inbox());
      if (!await db.hasSynced()) {
        final snapshot = await api.snapshot();
        _log.info(
          'First sync: ${snapshot.conversations.length} chats, '
          '${snapshot.conversations.fold(0, (n, c) => n + c.messages.length)} messages, up to ${snapshot.cursor}',
        );
        final received = <int, ReceivedMessage>{};
        for (final c in snapshot.conversations) {
          for (final event in c.messages) {
            received[event.seq] = await groups.decrypt(event);
          }
        }
        await db.applySnapshot(snapshot, received);
        await _afterGroupWork();
      } else {
        var cursor = await db.cursor();
        while (true) {
          final page = await api.sync(cursor);
          _log.debug('Catching up from $cursor: ${page.events.length} events${page.more ? ', more to come' : ''}');
          await _applyInOrder(page.events);
          await db.applyEvents(const [], me: me, cursor: page.cursor);
          cursor = page.cursor;
          if (!page.more) break;
        }
      }
    } on ApiException catch (e) {
      if (e.isUnauthorized) _signedOut();
      rethrow;
    }
  }

  void _onEvent(SyncEvent event) {
    if (!_live) {
      _log.debug('Event ${event.seq} (${event.type}) waits for the catch-up');
      _buffer.add(event);
      return;
    }
    _serial(() => _applyInOrder([event])).then((_) {
      unawaited(_notifySynced());
      return flushOutbox();
    }, onError: (_) {});
  }

  void _onInbox(InboxItem item) {
    _serial(() => _processInbox([item])).then((_) => flushOutbox(), onError: (_) {});
  }

  Future<void> _processInbox(List<InboxItem> items) async {
    if (items.isEmpty) return;
    for (final item in items) {
      _log.debug('Inbox ${item.id}: ${item.type} from ${item.fromUser}/${item.fromDevice}');
      if (item.type == InboxType.welcome) {
        await groups.processWelcome(item);
        await groups.retryUndecrypted(item.data['conv'] as String);
        await _afterGroupWork();
      } else if (item.type.startsWith('verification.')) {
        final handler = onVerificationMessage;
        // In order, but off the sync queue: it talks to the server and can
        // call back into this repository (see [markVerified]).
        if (handler != null) {
          _verifications = _verifications.then((_) => handler(item)).catchError((Object e, StackTrace stack) {
            _log.warning('Verification message ${item.type} failed', e, stack); // The other side times out.
          });
        }
      }
    }
    await api.ackInbox([for (final item in items) item.id]);
  }

  /// Applies events one by one: decrypting messages, merging commits,
  /// refreshing keys. Conversations whose members or devices changed are
  /// reconciled afterwards.
  Future<void> _applyInOrder(List<SyncEvent> events) async {
    final touched = <String>{};
    var newContacts = false;
    for (final event in events) {
      _log.debug('Event ${event.seq}: ${event.type} in ${event.conv.isEmpty ? '-' : event.conv}');
      switch (event.type) {
        case EventType.message:
          final received = await groups.decrypt(event);
          await db.applyEvents([event], me: me, received: {event.seq: received});
          _stopTyping(event.conv, received.envelope.from); // They sent it.
          // The keys to what came before the user was added.
          if (received.envelope.sharedWith == me) unawaited(_restoreKeys(event.conv));
        case EventType.memberRemoved when event.data['user'] == me:
          _log.info('Left ${event.conv}');
          // Left (here or on another device): the group's keys go too.
          await db.applyEvents([event], me: me);
          await groups.forget(event.conv);
        case EventType.mlsCommit:
          await groups.processCommit(event);
          await db.applyEvents([event], me: me);
          touched.add(event.conv);
        case EventType.groupState:
          await groups.takeSealedState(event);
          await db.applyEvents([event], me: me);
        case EventType.control:
          final received = await groups.decrypt(event);
          if (received.envelope.profileKey case final key?) {
            await groups.noteRosterKey(event.conv, received.envelope.from, key);
            await _takeProfileKey(received.envelope.from, key);
          }
          await db.applyEvents([event], me: me);
        case EventType.profileChanged:
          final user = event.data['user'] as String;
          await db.noteWantedProfile(user, event.data['version'] as int);
          await _refreshProfileOf(user);
          await db.applyEvents([event], me: me);
        case EventType.contactChanged:
          await _onContactChanged(event.data['user'] as String, ContactState.parse(event.data['state']));
          await db.applyEvents([event], me: me);
        case EventType.deviceKeysChanged:
          final user = event.data['user'] as String;
          _log.info('Keys of $user changed');
          keys.invalidate(user);
          touched.addAll(user == me ? await db.conversationIds() : await db.conversationsWith(user));
          await db.applyEvents([event], me: me);
        default:
          await db.applyEvents([event], me: me);
          if (event.conv.isNotEmpty && event.type != EventType.readMarker) touched.add(event.conv);
          newContacts |= event.type == EventType.conversationCreated || event.type == EventType.memberAdded;
          // Someone who shares nothing with the user any more should not read
          // what they tell about themself next.
          if (event.type == EventType.memberRemoved && event.data['user'] != me) {
            await _noteLostReader(event.data['user'] as String);
          }
      }
    }
    // Those the user shares a chat with now: whether they are online.
    if (newContacts && _live) _socket.sendPresence();
    for (final conv in touched) {
      await _reconcile(conv);
    }
    await _afterGroupWork();
  }

  /// Joins and repairs every conversation's group, tops up key packages and
  /// retries messages that could not be decrypted.
  Future<void> _maintainGroups() async {
    try {
      await groups.ensureKeyPackages();
    } on ApiException {
      // Next time.
    }
    for (final conv in {...await db.conversationIds(), ...await db.unsettledConversations()}) {
      await _reconcile(conv);
      await _repair(conv, () => groups.rotateKeysIfDue(conv));
    }
  }

  Future<void> _reconcile(String conv) => _repair(
    conv,
    () async {
      if (await db.isRefused(conv)) return;
      await groups.reconcile(conv);
      await groups.retryUndecrypted(conv);
    },
    // Until then the chat cannot be read here; it says why.
    onFailure: (e) => db.setSecurityIssue(conv, 'This device could not join the encryption of this chat: $e'),
  );

  /// Runs group upkeep for [conv]; failures are retried on the next event or
  /// reconnect. Others than those expected (e.g. from openmls) are logged and
  /// go to [onFailure]: one chat never stops the sync of the rest.
  Future<void> _repair(String conv, Future<void> Function() work, {Future<void> Function(Object error)? onFailure}) async {
    if (_disposed) return;
    try {
      await work();
    } on StaleGroup {
      // Catching up; the next sync reconciles again.
      _log.debug('Upkeep of $conv waits: this device is catching up');
    } on DeviceNotVerified {
      _unverified();
    } on ApiException catch (e) {
      // Offline: retried on the next event or reconnect.
      if (e.code == 'not_verified') {
        _unverified();
      } else if (e.code == 'lease_held') {
        _log.debug('Upkeep of $conv waits: another device is changing its group');
        _retryUpkeep(conv);
      } else {
        _log.info('Upkeep of $conv failed: ${e.status} ${e.code}: $e');
      }
    } on StateError catch (e) {
      // E.g. the conversation is gone.
      _log.info('Upkeep of $conv stopped: $e');
    } catch (e, stack) {
      _log.warning('Upkeep of $conv failed', e, stack);
      await onFailure?.call(e);
    }
  }

  /// Another device is committing to [conv]: its commit usually arrives
  /// first and leaves nothing to do, but if it never comes (that device gave
  /// up), nothing else would bring this device back to it. Not waited for on
  /// the queue, which would hold up every other event meanwhile.
  void _retryUpkeep(String conv, {Duration? after}) {
    if (_disposed) return;
    // A later try asked for replaces a sooner one, which would find nothing to do.
    if (after != null) _upkeepRetries.remove(conv)?.cancel();
    _upkeepRetries[conv] ??= Timer(after ?? Duration(milliseconds: 1000 + _random.nextInt(2000)), () {
      _log.debug('Trying the upkeep of $conv again');
      _upkeepRetries.remove(conv);
      _serial(() => _reconcile(conv)).then((_) => flushOutbox(), onError: (_) {});
    });
  }

  /// This device has to verify again; until then it changes no group.
  void _unverified() {
    if (_disposed || _toldUnverified) return;
    _toldUnverified = true;
    _log.warning('This device is no longer verified with the account key: it must verify again');
    onUnverified?.call();
  }

  /// The server refused a message for its epoch. Usually the commit that
  /// moved the group on is on its way and the message goes again after it;
  /// [_resolveEpochMismatch] checks that it really is.
  void _checkEpochSoon(String conv) {
    if (_disposed) return;
    _epochChecks[conv] ??= Timer(const Duration(seconds: 2), () {
      _epochChecks.remove(conv);
      _serial(() => _repair(conv, () => _resolveEpochMismatch(conv))).then((_) => flushOutbox(), onError: (_) {});
    });
  }

  /// If this device's group is still at another epoch than the server's and
  /// no commit is on its way, it missed one for good (or went ahead of
  /// everyone else): waiting would hold its messages forever, so the group
  /// is rebuilt.
  Future<void> _resolveEpochMismatch(String conv) async {
    final local = await groups.localEpoch(conv);
    if (local == null) return; // Not in the group: reconciling joins it.
    final server = (await api.groupInfo(conv)).epoch;
    if (local == server) return; // Caught up meanwhile.
    if (local < server) {
      final next = await api.sync(await db.cursor());
      if (next.more || next.events.any((e) => e.conv == conv && e.type == EventType.mlsCommit)) {
        _log.debug('$conv: at epoch $local, the server at $server; the commits are on their way');
        return;
      }
    }
    _log.warning('$conv: at epoch $local, the server at $server, and no commit is on its way: rebuilding the group');
    groups.needsRecovery.add(conv);
    await groups.reconcile(conv);
    await groups.retryUndecrypted(conv);
  }

  void _signedOut() {
    if (_disposed) return;
    _log.warning('Signed out by the server');
    _disposed = true;
    onSignedOut();
  }

  /// Encrypts and sends pending messages in order over the WebSocket (media
  /// is uploaded over HTTP first, already encrypted). Stops at the first
  /// network error; the next successful (re)connect flushes again. Messages
  /// of a conversation whose group is not trusted right now stay pending.
  Future<void> flushOutbox() async {
    // Not open yet (another engine holds the lock, say): sent once connected.
    if (_mls == null) return;
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      do {
        _flushAgain = false;
        final held = <String>{};
        final sentTo = <String>{};
        for (final pending in await db.pendingMessages()) {
          if (_disposed) return;
          final conv = pending.envelope.conv;
          if (held.contains(conv)) continue; // Keep the conversation's order.
          int? epoch;
          try {
            await _uploadAttachments(pending);
            await _deleteFromServer(pending.envelope);
            final outgoing = await _withHistory(pending.envelope);
            if (outgoing == null) {
              _log.info('Not sharing the history of $conv: this account has no keys to it');
              await db.deleteMessage(pending.envelope.id);
              continue;
            }
            final sealed = await _serial(() => groups.encrypt(outgoing));
            epoch = sealed.wire.epoch;
            final seq = await _socket.sendMessage(sealed.wire);
            _log.debug('Sent ${pending.envelope.id} (${pending.envelope.type}) to $conv at epoch $epoch: $seq');
            await db.markSent(pending.envelope.id, seq);
            await db.setContentKey(pending.envelope.id, sealed.contentKey);
            _scheduleBackup();
            await db.noteSentWithKeys(conv, clock());
            sentTo.add(conv);
          } on SendBlocked catch (e) {
            _log.info('Holding ${pending.envelope.id} for $conv: ${e.reason}');
            held.add(conv);
          } on StaleGroup {
            _log.info('Holding ${pending.envelope.id} for $conv: this device is not in its group');
            held.add(conv);
          } on ApiException catch (e) {
            if (e.isUnauthorized) return _signedOut();
            if (e.code == 'epoch_mismatch') {
              // The group changed and this device has not caught up yet: the
              // commit is on its way and sends this again, re-encrypted.
              _log.info(
                'Holding ${pending.envelope.id} for $conv: the server refused epoch $epoch '
                '(this device is at ${await _serial(() => groups.localEpoch(conv))} now)',
              );
              held.add(conv);
              _checkEpochSoon(conv);
              continue;
            }
            if (e.code == 'not_verified') {
              // Sent once this device is verified again.
              held.add(conv);
              _unverified();
              continue;
            }
            if (e.isPermanent) {
              _log.warning('Could not send ${pending.envelope.id} to $conv: ${e.status} ${e.code}: $e');
              await db.setState(pending.envelope.id, DeliveryState.failed);
              continue;
            }
            _log.debug('Sending waits for the connection: $e');
            return; // Offline or server trouble: keep it pending.
          } on FileSystemException catch (e) {
            _log.warning('Could not send ${pending.envelope.id}: a file is missing', e);
            await db.setState(pending.envelope.id, DeliveryState.failed);
          }
        }
        for (final conv in sentTo) {
          await _serial(() => _repair(conv, () => groups.rotateKeysIfDue(conv)));
        }
      } while (_flushAgain);
    } finally {
      _flushing = false;
    }
  }

  /// Before a deletion goes out, the server drops the deleted message and the
  /// user's edits of it, so that devices which come later never get them.
  Future<void> _deleteFromServer(Envelope envelope) async {
    final target = envelope.target;
    if (envelope.type != Envelope.deleteType || target == null) return;
    await api.deleteMessages([target, ...await db.editsOf(target, me)]);
  }

  /// A share of the history (see [Envelope.historyType]) gets its keys when
  /// it first goes out: those of every message of the chat that this account
  /// can read by then. Null if there are none.
  Future<Envelope?> _withHistory(Envelope envelope) async {
    if (envelope.type != Envelope.historyType || envelope.historyKeys != null) return envelope;
    final keys = await _historyKeys(envelope.conv);
    if (keys.isEmpty) return null;
    final file = await _uploadJson(_historyFile(keys));
    final shared = envelope.withBody({...envelope.body, 'keys': file.toJson()});
    // Sent again (the group changed meanwhile, say), it shares the same file.
    await db.setPendingEnvelope(shared);
    _log.info('Sharing the keys of ${keys.length} messages of ${envelope.conv} with ${envelope.sharedWith}');
    return shared;
  }

  /// Encrypts [json] with a key of its own and uploads it.
  Future<MediaRef> _uploadJson(List<int> json) async {
    await tempDir.create(recursive: true);
    final plain = await File('${tempDir.path}/${newUlid()}.json').writeAsBytes(json);
    try {
      final upload = await _encryptForUpload(plain);
      try {
        await api.uploadFile(upload.file, 'application/octet-stream');
      } finally {
        await upload.file.delete();
      }
      return MediaRef(
        hash: upload.hash,
        size: json.length,
        mime: 'application/json',
        key: base64.encode(upload.key),
      ).at(_host);
    } finally {
      await plain.delete();
    }
  }

  /// The keys of the messages of [conv] that this account can read, oldest
  /// first: those its devices put in the key backup, and those on this
  /// device that are not there yet.
  Future<Map<String, ContentKey>> _historyKeys(String conv) async {
    final keys = <String, ({int seq, ContentKey key})>{};
    final cipher = _backup;
    if (cipher != null) {
      try {
        var after = 0;
        while (true) {
          final page = await api.conversationKeyBackup(conv, after: after);
          for (final entry in page.entries) {
            try {
              keys[entry.id] = (seq: entry.seq, key: await cipher.open(entry.id, entry.data));
            } on DecryptionFailed {
              // Made for an earlier identity.
            }
          }
          if (!page.more || page.entries.isEmpty) break;
          after = page.entries.last.seq;
        }
      } on ApiException catch (e) {
        if (e.status != 404) rethrow; // No longer a member: what is here.
      }
    }
    // After the messages queued before it were read.
    for (final row in await _serial(() => db.contentKeysOf(conv))) {
      keys[row.id] ??= (seq: row.seq, key: ContentKey.fromBytes(base64.decode(row.contentKey)));
    }
    final ids = keys.keys.toList()..sort((a, b) => keys[a]!.seq.compareTo(keys[b]!.seq));
    return {for (final id in ids) id: keys[id]!.key};
  }

  /// [keys] (oldest first) as the file of a history share. If the server
  /// would not take it whole, the oldest are left out.
  Uint8List _historyFile(Map<String, ContentKey> keys) {
    var entries = keys.entries.toList();
    var file = encodeHistoryKeys(keys);
    final limit = maxUploadBytes;
    final room = limit == null ? null : limit - limit ~/ 100; // Encryption adds a little.
    while (room != null && file.length > room) {
      entries = entries.sublist(entries.length - entries.length * room ~/ file.length);
      file = encodeHistoryKeys(Map.fromEntries(entries));
    }
    return file;
  }

  /// Uploads a message's files: a photo, video or file and its thumbnail, a
  /// link preview's picture, or the picture of a pack's sticker.
  Future<void> _uploadAttachments(PendingMessage pending) async {
    // These are the encrypted files; the server only ever sees ciphertext.
    if (pending.thumbnailPath != null) await api.uploadFile(File(pending.thumbnailPath!), 'application/octet-stream');
    if (pending.attachmentPath != null) {
      await api.uploadFile(File(pending.attachmentPath!), 'application/octet-stream');
      if (pending.envelope.messageType == MessageType.sticker) await _noteSentPackSticker(pending.envelope.sticker!);
    }
  }

  // Key backup

  /// Uploads content keys that are not in the key backup yet now, e.g.
  /// before signing out.
  Future<void> flushKeyBackup() async {
    _backupTimer?.cancel();
    _backupTimer = null;
    await _uploading?.catchError((Object _) {});
    await (_uploading = _uploadBackups());
  }

  /// Uploads new content keys soon, in one batch.
  void _scheduleBackup() {
    if (_disposed || _backup == null || _backupStale) return;
    _backupTimer ??= Timer(const Duration(seconds: 2), () {
      _backupTimer = null;
      _uploading = _uploadBackups();
    });
  }

  /// Puts the content keys of messages this device sent or decrypted into
  /// the account's key backup, so the user's other devices, including
  /// future ones, can read them.
  Future<void> _uploadBackups() async {
    final cipher = _backup;
    if (cipher == null || _backingUp) return;
    _backingUp = true;
    try {
      while (!_disposed) {
        final rows = await db.keysToBackUp();
        if (rows.isEmpty) return;
        final version = _backupVersion ??= await _identityVersionForBackup();
        if (version == null) {
          // Our identity was replaced (reset elsewhere): the backup secret is stale.
          _log.warning('Not backing up message keys: the account was reset elsewhere');
          _backupStale = true;
          return;
        }
        final entries = {
          for (final row in rows) row.id: await cipher.seal(row.id, ContentKey.fromBytes(base64.decode(row.contentKey!))),
        };
        await api.putKeyBackup(identityVersion: version, entries: entries);
        _log.debug('Backed up the keys of ${entries.length} messages');
        // Including any the server ignored (e.g. of a conversation since
        // left): sending them again would not help.
        await db.markKeysBackedUp(entries.keys);
      }
    } on ApiException catch (e) {
      // A reset happened meanwhile; otherwise offline, retried after the next sync.
      _log.info('Backing up message keys failed: ${e.code}');
      if (e.code == 'identity_changed') _backupVersion = null;
    } finally {
      _backingUp = false;
    }
  }

  /// The identity version this device's backup secret belongs to: the
  /// current one while the server still shows our identity key.
  Future<int?> _identityVersionForBackup() async {
    final keys = await api.userKeys(me);
    return keys.identityKey == _ownIdentityKey ? keys.identityVersion : null;
  }

  /// Decrypts messages this device could not read (sent before it joined)
  /// with keys from the key backup, or for messages from before the user
  /// joined, with keys a member shared (see [_takeShares]). Runs one after
  /// another; requests for everything that pile up meanwhile run once.
  Future<void> _restoreKeys([String? conv]) {
    if (conv == null) {
      if (_restoreQueued) return _restoring;
      _restoreQueued = true;
    }
    Future<void> run() {
      if (conv == null) _restoreQueued = false;
      return _restore(conv);
    }

    return _restoring = _restoring.then((_) => run(), onError: (_) => run());
  }

  Future<void> _restore(String? conv) async {
    final cipher = _backup;
    if (cipher == null || _disposed) return;
    try {
      await _takeShares(conv);
      // A share read just now (on a new device, from the backup) may open more.
      do {
        await _restoreWaiting(cipher, conv);
      } while (!_disposed && await _takeShares(conv) > 0);
    } on ApiException catch (e) {
      // Offline: tried again after the next sync.
      _log.debug('Reading the key backup failed: $e');
    }
  }

  /// One round of [_restore]: shared keys first, then the key backup.
  Future<void> _restoreWaiting(KeyBackupCipher cipher, String? conv) async {
    final waiting = await db.undecrypted(conv);
    var restored = 0, shared = 0, missing = 0, unreadable = 0;
    for (var i = 0; i < waiting.length && !_disposed; i += 500) {
      final batch = waiting.sublist(i, min(i + 500, waiting.length));
      final sharedKeys = await db.sharedKeysFor(batch);
      final rest = <Message>[];
      for (final row in batch) {
        if (await _openWithSharedKey(row, sharedKeys[row.id] ?? const [])) {
          shared++;
        } else {
          rest.add(row);
        }
      }
      if (rest.isEmpty) continue;
      final entries = await api.queryKeyBackup([for (final row in rest) row.id]);
      for (final row in rest) {
        final entry = entries[row.id];
        if (entry == null) {
          missing++; // None of the user's devices read it, nor did anyone share it.
          continue;
        }
        try {
          final key = await cipher.open(row.id, entry);
          final wire = EncryptedEnvelope.fromJson((jsonDecode(row.wire!) as Map).cast<String, Object?>());
          await db.setDecrypted(row.id, await openMessage(wire, key), base64.encode(key.toBytes()), backedUp: true);
          restored++;
        } on DecryptionFailed {
          // Made for an earlier identity, or not for this message.
          unreadable++;
        } on FormatException {
          // A malformed message stays a placeholder.
          unreadable++;
        }
      }
    }
    if (waiting.isNotEmpty) {
      _log.info(
        'Key backup${conv == null ? '' : ' for $conv'}: ${waiting.length} messages waited for keys; '
        '${restored + shared} read now ($shared with shared keys), $missing not in the backup, '
        '$unreadable not readable with it',
      );
    }
  }

  /// Opens [row] with the first of [keys] that fits; whether one did. Its
  /// key then goes into the user's key backup, for their other devices.
  Future<bool> _openWithSharedKey(Message row, List<String> keys) async {
    for (final key in keys) {
      try {
        final wire = EncryptedEnvelope.fromJson((jsonDecode(row.wire!) as Map).cast<String, Object?>());
        await db.setDecrypted(row.id, await openMessage(wire, ContentKey.fromBytes(base64.decode(key))), key);
        return true;
      } on DecryptionFailed {
        // Not this message's key.
      } on FormatException {
        return false; // A malformed message stays a placeholder.
      }
    }
    return false;
  }

  /// Takes the keys that came in shares of a group's history with the user
  /// (see [Envelope.historyType]) and that this device has not taken yet;
  /// how many shares it took. Only devices of the user they were shared
  /// with take them, and use them only for messages from before the share
  /// (see [AppDatabase.sharedKeysFor]).
  Future<int> _takeShares(String? conv) async {
    var taken = 0;
    for (final share in await db.untakenShares(me, conv)) {
      final file = share.historyKeys;
      final key = file?.key;
      if (file == null || key == null) continue;
      try {
        final keys = decodeHistoryKeys(
          await (await media.get(file.hash, key: base64.decode(key), host: _elsewhere(file))).readAsBytes(),
        );
        await db.addSharedKeys(share, {
          for (final MapEntry(key: id, value: contentKey) in keys.entries) id: base64.encode(contentKey.toBytes()),
        });
        // Kept in the database now; an empty one stays, or it would be fetched every time.
        if (keys.isNotEmpty) await media.remove(file.hash);
        _log.info('${share.from} shared the keys of ${keys.length} earlier messages of ${share.conv}');
        taken++;
      } on ApiException catch (e) {
        if (!e.isPermanent) rethrow; // Offline: taken after the next sync.
        _log.warning('The history ${share.from} shared in ${share.conv} is not on the server: $e');
      } on DecryptionFailed catch (e) {
        _log.warning('The history ${share.from} shared in ${share.conv} could not be decrypted: $e');
      } on FormatException catch (e) {
        _log.warning('The history ${share.from} shared in ${share.conv} is not readable: $e');
      }
    }
    return taken;
  }

  /// Fetches the profile cards (see [ProfileCard]) announced since they were
  /// last fetched. Runs one after another; requests that pile up meanwhile
  /// run once.
  Future<void> _fetchCards() {
    if (_cardsQueued) return _fetchingCards;
    _cardsQueued = true;
    Future<void> run() {
      _cardsQueued = false;
      return _fetchCardsNow();
    }

    return _fetchingCards = _fetchingCards.then((_) => run(), onError: (_) => run());
  }

  Future<void> _fetchCardsNow() async {
    for (final (:userId, :card) in await db.cardsToFetch()) {
      if (_disposed) return;
      String? json; // Stays null for a card that cannot be read: it shows nothing.
      try {
        final key = card.key;
        if (key == null || card.size > ProfileCard.maxBytes) throw const FormatException('Not a profile card');
        final bytes = await (await media.get(card.hash, key: base64.decode(key), host: _elsewhere(card))).readAsBytes();
        await media.remove(card.hash); // Kept in the database.
        final decoded = bytes.length > ProfileCard.maxBytes ? null : jsonDecode(utf8.decode(bytes));
        if (decoded is! Map) throw const FormatException('Not a profile card');
        json = jsonEncode(ProfileCard.fromJson(decoded.cast<String, Object?>()).toJson());
      } on ApiException catch (e) {
        if (!e.isPermanent) return; // Offline: fetched after the next sync.
        _log.info("$userId's profile card is not on the server: $e");
      } on DecryptionFailed catch (e) {
        _log.info("$userId's profile card could not be decrypted: $e");
      } on FormatException catch (e) {
        _log.info("$userId's profile card is not readable: $e");
      }
      await db.setFetchedCard(userId, card.hash, json);
    }
  }

  // What follows from groups changing

  /// Runs on the queue, after commits, Welcomes and such were applied: takes
  /// the profile keys in the rosters that changed, tells groups this user's if
  /// a roster lacks it, and sees to states that nobody sealed yet.
  Future<void> _afterGroupWork() async {
    final changed = {...groups.stateChanged};
    groups.stateChanged.clear();
    final own = (await db.profileRow(me))?.profileKey;
    for (final conv in changed) {
      final held = await groups.heldState(conv);
      final roster = held?.roster ?? _rosterOf(await db.groupStateRow(conv));
      for (final MapEntry(key: user, value: key) in roster.entries) {
        if (user != me) await _takeProfileKey(user, key);
      }
      if (own != null) {
        if (roster[me] == own) {
          _announcedAt.remove(conv);
        } else if (_announcedAt[conv] != await groups.localEpoch(conv)) {
          await _announceProfileKey(conv, own);
        }
      }
    }
    final missing = {...groups.stateMissing};
    groups.stateMissing.clear();
    for (final conv in missing) {
      if (_once) {
        await _repair(conv, () => groups.sealIfMissing(conv));
      } else if (!_disposed) {
        // One member will do: most of the time another was quicker.
        _sealChecks[conv] ??= Timer(Duration(milliseconds: 200 + _random.nextInt(1000)), () {
          _sealChecks.remove(conv);
          unawaited(_serial(() => _repair(conv, () => groups.sealIfMissing(conv))).catchError((Object _) {}));
        });
      }
    }
  }

  static Map<String, String> _rosterOf(GroupStateRow? row) =>
      row == null ? const {} : (jsonDecode(row.roster) as Map).cast<String, String>();

  /// Tells a conversation's members this user's profile key, in a message that
  /// stays out of the chat. Tried again the next time its state changes.
  Future<void> _announceProfileKey(String conv, String key) async {
    final message = Envelope.profileKey(conv: conv, from: me, key: key, now: clock());
    try {
      final sealed = await groups.encrypt(message, type: EncryptedEnvelope.control);
      _announcedAt[conv] = sealed.wire.epoch;
      void failed(Object e) {
        _log.debug('Telling $conv the profile key failed: $e');
        _announcedAt.remove(conv);
      }

      if (_once) {
        // No connection, and nothing that runs later.
        await api.postMessage(sealed.wire).then((_) {}, onError: failed);
      } else {
        unawaited(_socket.sendMessage(sealed.wire).then((_) {}, onError: failed));
      }
    } on SendBlocked catch (e) {
      _log.debug('Telling $conv the profile key waits: ${e.reason}');
    } on StaleGroup {
      _log.debug('Telling $conv the profile key waits: this device is not in its group');
    }
  }

  // Contacts

  /// Account data holding the user's contact list:
  /// `{"contacts": {userId: {"addedAt", "key"?}}}`.
  static const _contactsData = 'contacts';

  @override
  Stream<Map<String, ContactState>> watchContacts() => db.watchContacts().map(
    (rows) => {
      for (final MapEntry(key: user, value: row) in rows.entries)
        // The server's word alone does not make anyone a contact.
        if (row.state != ContactState.none && (row.state != ContactState.accepted || row.trusted)) user: row.state,
    },
  );

  /// How the user stands with everyone, by the server, and who they trust, by
  /// their own list.
  Future<void> _loadContacts() async {
    await db.setContactStates(await api.contacts());
    await _loadContactList();
  }

  Future<void> _loadContactList() async {
    final store = _accountData;
    if (store == null || _disposed) return;
    final read = await store.read(_contactsData);
    if (read == null) return; // Older than what this device has seen: that stays.
    if (read.value == null) {
      if (read.sequence > 0) return;
      // None yet: nobody on it. But one lost with a reset of the account's keys
      // can only be filled in on the server's word. This is the one time that
      // counts, for a device that has seen no list under the new key.
      if (((await api.userKeys(me)).identityVersion ?? 1) <= 1) return;
      final known = {
        for (final c in await db.allContacts())
          if (c.state == ContactState.accepted || c.state == ContactState.outgoing) c.userId,
      };
      if (known.isNotEmpty) {
        _log.info('The contact list is gone; taking ${known.length} contacts from the server');
        await _changeContactList((contacts) {
          for (final user in known) {
            contacts.putIfAbsent(user, () => {'addedAt': clock().millisecondsSinceEpoch});
          }
        });
      }
      return;
    }
    final contacts = _parseContactList(read.value);
    await _useContactList(contacts);
    for (final MapEntry(key: user, value: entry) in contacts.entries) {
      if (entry['key'] case final String key) await _takeProfileKey(user, key);
    }
  }

  static Map<String, Map<String, Object?>> _parseContactList(Map<String, Object?>? data) {
    final contacts = data?['contacts'];
    return {
      if (contacts is Map)
        for (final MapEntry(:key, :value) in contacts.entries)
          if (key is String && value is Map) key: value.cast<String, Object?>(),
    };
  }

  Future<void> _useContactList(Map<String, Map<String, Object?>> contacts) async {
    final before = await db.trustedContacts();
    await db.setTrustedContacts(contacts.keys.toSet());
    // Someone newly trusted may have brought this device somewhere before.
    if (contacts.keys.any((user) => !before.contains(user))) await db.clearRefusedConversations();
  }

  /// Changes the user's own list, on all of their devices.
  Future<void> _changeContactList(void Function(Map<String, Map<String, Object?>> contacts) change) async {
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    late Map<String, Map<String, Object?>> contacts;
    await store.update(_contactsData, (current) {
      contacts = _parseContactList(current);
      change(contacts);
      return {'contacts': contacts};
    });
    await _useContactList(contacts);
  }

  Future<void> _trust(String user) => _changeContactList(
    (contacts) => contacts.putIfAbsent(user, () => {'addedAt': clock().millisecondsSinceEpoch}),
  );

  Future<void> _distrust(String user) => _changeContactList((contacts) => contacts.remove(user));

  Future<void> _onContactChanged(String user, ContactState state) async {
    final was = (await db.contact(user))?.state;
    await db.setContactState(user, state);
    if (state == ContactState.accepted) {
      // A chat of theirs this device stayed out of counts now.
      await _loadContactList();
      for (final conv in await db.conversationsWith(user)) {
        await _reconcile(conv);
      }
    } else if (was == ContactState.accepted) {
      _log.info('$user is no longer a contact');
      try {
        await _distrust(user);
        await _noteLostReader(user);
      } on ApiException catch (e) {
        _log.info('Updating the contact list failed: $e'); // Comes right with the next sync.
      }
    }
  }

  @override
  Future<ContactState> requestContact(String userId) async {
    await started;
    // Listed first: their answer can reach this device before the server's does.
    await _trust(userId);
    final ContactState state;
    try {
      state = await api.requestContact(userId);
    } on ApiException catch (e) {
      if (e.isPermanent) await _distrust(userId);
      rethrow;
    }
    if (state == ContactState.incoming) {
      await acceptContact(userId);
      return ContactState.accepted;
    }
    await db.setContactState(userId, state);
    return state;
  }

  @override
  Future<void> acceptContact(String userId) async {
    await started;
    await _trust(userId);
    await api.acceptContact(userId);
    await db.setContactState(userId, ContactState.accepted);
    // Their chat right away, as a step of its own: the two learn who the other
    // is through it (their profile keys), and can verify each other. Should it
    // not work out now, it starts when either of them opens it.
    unawaited(
      _startDirectChat(userId).then((_) {}, onError: (Object e) => _log.info('Starting the chat with $userId: $e')),
    );
  }

  /// The direct chat with [userId], a contact, started unless this device has
  /// it already.
  Future<String> _startDirectChat(String userId) async {
    var made = false;
    final conv = await _serial(() async {
      final existing = await db.directConversationWith(userId);
      if (existing != null) return existing;
      made = true;
      return groups.createConversation(directWith: userId);
    });
    if (made) {
      _serial(() async {
        await _reconcile(conv);
        await _afterGroupWork();
      }).then((_) => flushOutbox(), onError: (_) {});
    }
    return conv;
  }

  @override
  Future<void> declineContact(String userId) async {
    await api.declineContact(userId);
    await db.setContactState(userId, ContactState.none);
  }

  @override
  Future<void> cancelContactRequest(String userId) async {
    await api.cancelContactRequest(userId);
    await _distrust(userId);
    await db.setContactState(userId, ContactState.none);
  }

  @override
  Future<void> removeContact(String userId) async {
    await api.removeContact(userId);
    await _distrust(userId);
    await db.setContactState(userId, ContactState.none);
    await _noteLostReader(userId);
  }

  @override
  Future<void> blockContact(String userId) async {
    await api.blockContact(userId);
    await _distrust(userId);
    await db.setContactState(userId, ContactState.blocked);
    await _noteLostReader(userId);
  }

  @override
  Future<void> unblockContact(String userId) async {
    await api.unblockContact(userId);
    await db.setContactState(userId, ContactState.none);
  }

  // Profiles

  /// Account data holding the user's profile key, which all of their devices
  /// need: `{"key", "previous"?, "rotate"?}`. `rotate` says someone lost the
  /// right to read what the user tells next, so the next change gets a new key.
  static const _profileData = 'profile';

  Future<void> _ensureOwnProfile() async {
    final store = _accountData;
    if (store == null || _disposed) return;
    final read = await store.read(_profileData);
    if (read == null) return;
    if (read.value?['key'] is! String) {
      await store.update(_profileData, (current) {
        if (current?['key'] is String) return null;
        return {'key': base64.encode(randomBytes(32))};
      });
    }
    await _loadOwnProfile();
    final row = await db.profileRow(me);
    if (row == null || row.version == 0) {
      // A new account, or one whose keys were reset: tell who the user is.
      await _changeProfile((document) => document, onQueue: true);
    }
  }

  /// Takes the user's own profile: how their devices learn it, with or without
  /// a chat in common.
  Future<void> _loadOwnProfile() async {
    final store = _accountData;
    if (store == null || _disposed) return;
    final secret = (await store.read(_profileData))?.value;
    final key = secret?['key'];
    if (key is! String) return;
    final row = await db.profileRow(me);
    if (row?.profileKey != key) await db.noteProfileKey(me, key);
    final record = await _ownRecord();
    if (record == null) return;
    final document = await _openOwn(record, secret!);
    if (document == null) return;
    if (await db.noteProfile(me, document, version: record.version, profileKey: key)) unawaited(_fetchCards());
  }

  /// The user's own record, if their current key signed it.
  Future<ProfileRecord?> _ownRecord() async {
    final json = await api.profile(me);
    if (json == null) return null;
    try {
      final record = ProfileRecord.fromJson(json, user: me);
      final own = _ownIdentityKey;
      if (own != null && await record.isSignedBy(own)) return record;
      _log.info('The stored profile was signed with an earlier key');
    } on FormatException catch (e) {
      _log.warning('The stored profile is malformed: $e');
    }
    return null;
  }

  Future<ProfileDocument?> _openOwn(ProfileRecord record, Map<String, Object?> secret) async {
    for (final key in [secret['key'], secret['previous']].whereType<String>()) {
      try {
        return await record.open(base64.decode(key));
      } on DecryptionFailed {
        // Perhaps with the one before it.
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// Publishes what [change] makes of the user's profile as stored. Another
  /// device changing it meanwhile makes this run again on what that one wrote.
  /// With someone having lost the right to read it, it gets a new key first,
  /// which then goes to everyone who still may; that takes the queue, unless
  /// this already runs on it ([onQueue]).
  Future<void> _changeProfile(ProfileDocument Function(ProfileDocument current) change, {bool onQueue = false}) async {
    final store = _accountData;
    final signer = await identity.localIdentity();
    if (store == null || signer == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    var rotated = false;
    final secret = await store.update(_profileData, (current) {
      final key = current?['key'];
      if (key is String && current?['rotate'] != true) return null;
      rotated = key is String;
      return {'key': base64.encode(randomBytes(32)), 'previous': ?key};
    }) ?? (await store.read(_profileData))?.value;
    final key = secret?['key'];
    if (key is! String) throw const ApiException(0, 'not_ready', 'Not connected yet');
    for (var attempt = 0; ; attempt++) {
      final stored = await _ownRecord();
      final row = await db.profileRow(me);
      final current = (stored == null ? null : await _openOwn(stored, secret!)) ?? _startingDocument(row);
      // Later than what the server shows, and than what this device has seen,
      // or the other devices would refuse it.
      final version = max(max(stored?.version ?? 0, (await api.profile(me))?['version'] as int? ?? 0), row?.version ?? 0) + 1;
      final document = change(current);
      final record = await ProfileRecord.seal(document, user: me, version: version, key: base64.decode(key), signer: signer);
      try {
        await api.putProfile(record.toJson());
        await db.noteProfile(me, document, version: version, profileKey: key);
        break;
      } on ApiException catch (e) {
        if (e.code != 'stale_version' || attempt >= 8) rethrow;
      }
    }
    if (rotated) {
      _log.info('The profile got a new key');
      Future<void> announce() async {
        for (final conv in await db.conversationIds()) {
          await _announceToReaders(conv, key);
        }
      }

      await (onQueue ? announce() : _serial(announce));
    }
  }

  /// [conv]'s members still may read the user's profile, unless it is the
  /// direct chat of someone no longer a contact.
  Future<void> _announceToReaders(String conv, String key) async {
    final row = await db.conversation(conv);
    if (row == null) return;
    if (row.isDirect) {
      final trusted = await db.trustedContacts();
      if (!(await db.memberIds(conv)).any((user) => user != me && trusted.contains(user))) return;
    }
    await _announceProfileKey(conv, key);
  }

  /// What the user's profile starts from when the stored one cannot be read, or
  /// there is none: what this device knows of it.
  ProfileDocument _startingDocument(Profile? row) => ProfileDocument(
    displayName: row != null && row.version > 0 ? row.displayName : account.displayName,
    avatar: AppDatabase.mediaRefOf(row?.avatar),
    card: AppDatabase.mediaRefOf(row?.card),
  );

  /// [user] shares nothing with the user now: what the user tells next, they
  /// should not read. It costs nothing until the user changes something.
  Future<void> _noteLostReader(String user) async {
    final trusted = (await db.trustedContacts()).contains(user);
    for (final conv in await db.conversationsWith(user)) {
      // A direct chat stays when the contact ends, but no longer counts.
      if (trusted || (await db.conversation(conv))?.isDirect == false) return;
    }
    final store = _accountData;
    if (store == null) return;
    try {
      await store.update(_profileData, (current) {
        if (current == null || current['rotate'] == true) return null;
        return {...current, 'rotate': true};
      });
    } on ApiException catch (e) {
      _log.info('Could not note that the profile needs a new key: $e');
    }
  }

  /// A key someone says opens [user]'s profile (they, or a group it came in):
  /// taken if it does.
  Future<void> _takeProfileKey(String user, String key) async {
    if ((await db.profileRow(user))?.profileKey == key) return;
    await _refreshProfileOf(user, candidate: key);
  }

  Future<void> _refreshProfiles() async {
    for (final user in await db.wantedProfiles()) {
      await _refreshProfileOf(user);
    }
    // Anyone whose key came before they had a profile to open with it.
    for (final row in await db.allProfiles()) {
      if (row.version == 0 && row.profileKey != null && row.id != me) await _refreshProfileOf(row.id);
    }
  }

  /// Fetches [user]'s record and takes it if their identity key signed it, it
  /// is no older than what this device has seen, and a key opens it: [candidate],
  /// or the one this device has. Failing that, nothing changes.
  Future<void> _refreshProfileOf(String user, {String? candidate}) async {
    if (user == me) return _loadOwnProfile().catchError((Object e) => _log.debug('Reading the profile failed: $e'));
    try {
      final json = await api.profile(user);
      if (json == null) {
        // Nothing to try it on yet.
        if (candidate != null) await db.noteProfileKey(user, candidate);
        return;
      }
      final record = ProfileRecord.fromJson(json, user: user);
      final row = await db.profileRow(user);
      if (record.version < (row?.version ?? 0)) {
        _log.warning("The server shows $user's profile at version ${record.version}, this device has seen ${row!.version}");
        return;
      }
      final trusted = await keys.devicesOf(user);
      final identityKey = trusted.identityKey;
      if (identityKey == null || trusted.identityChanged) return; // Waits for the user to review their key.
      if (!await record.isSignedBy(identityKey)) {
        _log.warning("$user's profile is not signed by their key");
        return;
      }
      for (final key in [candidate, row?.profileKey].whereType<String>()) {
        try {
          final document = await record.open(base64.decode(key));
          if (await db.noteProfile(user, document, version: record.version, profileKey: key)) {
            unawaited(_fetchCards());
            await _rememberProfileKey(user, key);
          }
          return;
        } on DecryptionFailed {
          // Not this one.
        }
      }
      _log.debug("No key to $user's profile yet");
    } on ApiException catch (e) {
      _log.debug("Fetching $user's profile failed: $e"); // Tried again with the next connection.
    } on FormatException catch (e) {
      _log.warning("$user's profile is malformed: $e");
    }
  }

  /// A contact's key goes on the user's list, for their devices to come.
  Future<void> _rememberProfileKey(String user, String key) async {
    if (!(await db.trustedContacts()).contains(user)) return;
    final store = _accountData;
    if (store == null) return;
    try {
      await store.update(_contactsData, (current) {
        final contacts = _parseContactList(current);
        final entry = contacts[user];
        if (entry == null || entry['key'] == key) return null;
        entry['key'] = key;
        return {'contacts': contacts};
      });
    } on ApiException catch (e) {
      _log.debug('Noting the profile key of $user failed: $e');
    }
  }

  // Presence

  void _onPresence(Map<String, Presence> statuses, {required bool all, PresenceMode? mode}) {
    if (all) _presence.clear();
    for (final MapEntry(key: user, value: status) in statuses.entries) {
      if (status == Presence.offline) {
        _presence.remove(user);
      } else {
        _presence[user] = status;
      }
    }
    if (mode != null) {
      _presenceMode = mode;
      unawaited(_notePresenceMode(mode));
    }
    if (!_presenceChanges.isClosed) _presenceChanges.add(null);
  }

  @override
  Stream<Map<String, Presence>> watchPresence() async* {
    yield Map.unmodifiable(_presence);
    yield* _presenceChanges.stream.map((_) => Map.unmodifiable(_presence));
  }

  @override
  Stream<PresenceMode> watchPresenceMode() async* {
    yield _presenceMode;
    yield* _presenceChanges.stream.map((_) => _presenceMode).distinct();
  }

  @override
  Future<void> setPresenceMode(PresenceMode mode) async {
    await api.setPresenceMode(mode);
    // The server tells this device too; shown at once meanwhile.
    _onPresence(const {}, all: false, mode: mode);
  }

  @override
  void setActive(bool active) {
    if (active == _active) return;
    _active = active;
    _socket.sendPresence(active: active);
  }

  // ChatRepository

  @override
  Stream<List<ConversationSummary>> watchConversations() => db.watchSummaries(me);

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) => db.watchMessages(conversationId);

  @override
  Stream<List<UserProfile>> watchProfiles() => db.watchProfiles();

  @override
  Stream<ConnectionStatus> watchConnection() async* {
    yield _socket.status;
    yield* _socket.statusChanges;
  }

  @override
  Stream<String?> watchConnectionProblem() async* {
    yield _socket.problem;
    yield* _socket.problemChanges;
  }

  @override
  Future<void> sendText(String conversationId, String text, {String? replyTo, LinkPreviewDraft? link}) async {
    final picture = link?.picture;
    final thumb = picture == null ? null : await _prepareLinkPicture(picture);
    final file = link?.media;
    final media = file == null ? null : await _prepareLinkMedia(file, thumb: thumb?.ref);
    await send(
      PendingMessage(
        Envelope.text(
          conv: conversationId,
          from: me,
          text: text,
          emojis: await _emojisIn(conversationId, text),
          replyTo: await _quote(replyTo),
          link: link?.toPreview(thumb: thumb?.ref, media: media?.ref),
        ),
        thumbnailPath: thumb?.upload,
        attachmentPath: media?.upload,
      ),
    );
  }

  /// Encrypts a link's video, GIF or picture for the outbox to upload, as
  /// [_prepareLinkPicture] does the preview's picture, which is its [thumb]
  /// (the viewer shows it until the file is here); null if the server would
  /// not take it (the preview then goes without).
  Future<({MediaRef ref, String upload})?> _prepareLinkMedia(LinkMediaFile file, {MediaRef? thumb}) async {
    final plain = File(file.path);
    final limit = maxUploadBytes;
    if (!plain.existsSync()) return null;
    try {
      if (limit != null && FileCipher.encryptedSize(file.size + 1) > limit) return null;
      final encrypted = await _encryptForUpload(plain);
      await media.put(encrypted.hash, plain);
      final ref = MediaRef(
        hash: encrypted.hash,
        size: file.size,
        mime: file.mime,
        width: file.width,
        height: file.height,
        durationMs: file.durationMs,
        key: base64.encode(encrypted.key),
        thumb: thumb,
      ).at(_host);
      return (ref: ref, upload: encrypted.file.path);
    } finally {
      await plain.delete();
    }
  }

  /// Encrypts a link preview's picture for the outbox to upload; this device
  /// shows it from its cache.
  Future<({MediaRef ref, String upload})> _prepareLinkPicture(LinkPicture picture) async {
    await tempDir.create(recursive: true);
    final extension = picture.mime == 'image/png' ? 'png' : 'jpg';
    final plain = await File('${tempDir.path}/link-${newUlid()}.$extension').writeAsBytes(picture.bytes);
    try {
      final encrypted = await _encryptForUpload(plain);
      await media.put(encrypted.hash, plain);
      final ref = MediaRef(
        hash: encrypted.hash,
        size: picture.bytes.length,
        mime: picture.mime,
        width: picture.width,
        height: picture.height,
        key: base64.encode(encrypted.key),
      ).at(_host);
      return (ref: ref, upload: encrypted.file.path);
    } finally {
      await plain.delete();
    }
  }

  @override
  Future<void> sendGif(String conversationId, GifRef gif, {String? replyTo}) async => send(
    PendingMessage(Envelope.gif(conv: conversationId, from: me, gif: gif, replyTo: await _quote(replyTo))),
  );

  @override
  Future<void> sendSticker(String conversationId, StickerRef sticker, {String? replyTo}) async {
    final (sent, upload) = await _stickerToSend(sticker);
    await send(
      PendingMessage(
        Envelope.sticker(conv: conversationId, from: me, sticker: sent, replyTo: await _quote(replyTo)),
        attachmentPath: upload,
      ),
    );
  }

  Integrations? _integrations;

  @override
  Future<String?> klipyApiKey() async => (_integrations ??= await api.integrations()).klipyApiKey;

  // Calls

  /// The calls the server told of, by ID: the newest version of each.
  final _calls = <String, Call>{};
  final _callChanges = StreamController<Map<String, Call>>.broadcast(sync: true);

  /// Where the keys of calls go: conversation -> call -> its watcher.
  final _callKeys = <String, Map<String, StreamController<CallKey?>>>{};

  @override
  Future<bool> callsAvailable() async => (_integrations ??= await api.integrations()).calls;

  @override
  Future<bool> videoAvailable() async {
    final integrations = _integrations ??= await api.integrations();
    return integrations.calls && integrations.video;
  }

  @override
  Stream<Map<String, Call>> watchCalls() async* {
    yield Map.unmodifiable(_calls);
    yield* _callChanges.stream;
  }

  /// Takes what the server says of a call, unless it said something newer.
  void _takeCall(Call call) {
    final known = _calls[call.id];
    if (known != null && known.version >= call.version) return;
    _calls[call.id] = call;
    if (!_callChanges.isClosed) _callChanges.add(Map.unmodifiable(_calls));
  }

  @override
  void noteCall(Call call) => _takeCall(call);

  Future<void> _refreshCalls() async {
    if (!await callsAvailable()) return;
    for (final call in await api.calls()) {
      _takeCall(call);
    }
  }

  @override
  Future<CallJoin> joinCall(String conversationId, {bool video = false}) async {
    // Asked again with the same ID, should the answer get lost: a call this
    // started is found as its own.
    final id = newUlid();
    late CallJoin join;
    for (var attempt = 1; ; attempt++) {
      try {
        join = await api.joinCall(id, conversationId, video: video);
        break;
      } on ApiException catch (e) {
        if (e.status != 0 || attempt == 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
    _takeCall(join.call);
    final anchored = 'call.anchored.$id';
    if (join.call.id == id && await db.getValue(anchored) == null) {
      // Started here: its place in the chat, once.
      await db.setValue(anchored, '1');
      await send(PendingMessage(Envelope.call(conv: conversationId, from: me, call: id)));
    }
    return join;
  }

  @override
  Future<void> declineCall(String callId) async => _takeCall(await api.declineCall(callId));

  @override
  Future<void> leaveCall(String callId) async => _takeCall(await api.leaveCall(callId));

  @override
  Stream<CallKey?> watchCallKeys(String conversationId, String callId) {
    late final StreamController<CallKey?> keys;
    keys = StreamController<CallKey?>(
      onListen: () async {
        (_callKeys[conversationId] ??= {})[callId] = keys;
        try {
          await started;
          final key = await _serial(() async => _mls == null ? null : groups.callKey(conversationId, callId));
          if (!keys.isClosed) keys.add(key);
        } catch (e) {
          if (!keys.isClosed) keys.addError(e);
        }
      },
      onCancel: () {
        final calls = _callKeys[conversationId];
        calls?.remove(callId);
        if (calls != null && calls.isEmpty) _callKeys.remove(conversationId);
      },
    );
    return keys.stream;
  }

  /// The group of [conv] moved on (on the serial queue already): calls in it
  /// take the key of the new epoch now, as the exporter has only the current
  /// one's.
  Future<void> _onEpoch(String conv) async {
    final calls = _callKeys[conv];
    if (calls == null) return;
    for (final MapEntry(key: callId, value: keys) in calls.entries.toList()) {
      final key = await groups.callKey(conv, callId);
      if (!keys.isClosed) keys.add(key);
    }
  }

  /// Kept for the notifications, which wait while in Focus: once it ends,
  /// what waited shows.
  Future<void> _notePresenceMode(PresenceMode mode) async {
    if (await db.presenceMode() == mode) return;
    await db.setPresenceMode(mode);
    await _notifySynced();
  }

  /// What the app hears live, for a sync without a connection (a push): the
  /// chats' settings, and whether the user is in Focus.
  Future<void> _loadNotificationState() async {
    try {
      await _loadChatSettings();
      await db.setPresenceMode(await api.presenceMode());
    } on ApiException {
      // Offline: as last heard.
    }
  }

  // Per-chat settings (see [ChatSettings])

  /// Account data holding them: `{"chats": {convId: ChatSettings}}`.
  static const _chatsData = 'chats';

  @override
  Stream<Map<String, ChatSettings>> watchChatSettings() => db.watchChatSettings();

  /// Takes them from the account data: on start, and when another device
  /// changed them.
  Future<void> _loadChatSettings() async {
    final settings = await _fetchChatSettings();
    if (settings != null) await db.setChatSettings(settings);
  }

  Future<Map<String, ChatSettings>?> _fetchChatSettings() async {
    final store = _accountData;
    if (store == null || _disposed) return null;
    final read = await store.read(_chatsData);
    return read == null ? null : AppDatabase.parseChatSettings(read.value?['chats']);
  }

  @override
  Future<void> setChatSettings(String conversationId, ChatSettings settings) async {
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    late Map<String, ChatSettings> all;
    await store.update(_chatsData, (current) {
      all = {...AppDatabase.parseChatSettings(current?['chats'])};
      if (settings.isEmpty) {
        all.remove(conversationId);
      } else {
        all[conversationId] = settings;
      }
      return {
        'chats': {for (final MapEntry(:key, :value) in all.entries) key: value.toJson()},
      };
    });
    await db.setChatSettings(all);
    // Muted, its notification goes; unmuted, what comes next shows.
    await _notifySynced();
  }

  // Saved GIFs

  /// Account data holding the user's saved GIFs: `{"gifs": [GifRef...]}`.
  static const _gifsData = 'gifs';

  /// The saved GIFs as last seen, for starts without a connection.
  static const _savedGifsKey = 'gifs.saved';

  static const maxSavedGifs = 100;

  /// Account data is at most 256 KiB once sealed and base64-encoded.
  static const _maxSavedGifBytes = 180 * 1024;

  final _savedGifChanges = StreamController<List<GifRef>>.broadcast(sync: true);

  @override
  Stream<List<GifRef>> watchSavedGifs() async* {
    yield _parseGifs(jsonDecode(await db.getValue(_savedGifsKey) ?? '[]'));
    yield* _savedGifChanges.stream;
  }

  /// Malformed entries (from a newer version, say) are left out.
  static List<GifRef> _parseGifs(Object? list) => [
    for (final entry in list is List ? list : const [])
      if (entry is Map) ?_tryParseGif(entry.cast<String, Object?>()),
  ];

  static GifRef? _tryParseGif(Map<String, Object?> json) {
    try {
      return GifRef.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  Future<void> _keepSavedGifs(List<GifRef> gifs) async {
    await db.setValue(_savedGifsKey, jsonEncode([for (final g in gifs) g.toJson()]));
    if (!_savedGifChanges.isClosed) _savedGifChanges.add(gifs);
  }

  /// Takes the saved GIFs from the account data: on start, and when another
  /// device changed them.
  Future<void> _loadSavedGifs() async {
    final gifs = await _fetchSavedGifs();
    if (gifs != null) await _keepSavedGifs(gifs);
  }

  Future<List<GifRef>?> _fetchSavedGifs() async {
    final store = _accountData;
    if (store == null || _disposed) return null;
    final read = await store.read(_gifsData);
    return read == null ? null : _parseGifs(read.value?['gifs']);
  }

  @override
  Future<void> setGifSaved(GifRef gif, bool saved) async {
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    late List<GifRef> gifs;
    await store.update(_gifsData, (current) {
      gifs = [if (saved) gif, ..._parseGifs(current?['gifs']).where((g) => g.key != gif.key)];
      Map<String, Object?> data() => {'gifs': [for (final g in gifs) g.toJson()]};
      // The oldest go when the list is full.
      while (gifs.length > maxSavedGifs || utf8.encode(jsonEncode(data())).length > _maxSavedGifBytes) {
        gifs.removeLast();
      }
      return data();
    });
    await _keepSavedGifs(gifs);
  }

  // The user's stickers

  /// Account data holding the user's stickers: `{"stickers": [StickerRef...]}`.
  static const _stickersData = 'stickers';

  /// The stickers as last seen, for starts without a connection.
  static const _savedStickersKey = 'stickers.saved';

  static const maxSavedStickers = 200;

  /// Account data is at most 256 KiB once sealed and base64-encoded.
  static const _maxSavedStickerBytes = 180 * 1024;

  final _savedStickerChanges = StreamController<List<StickerRef>>.broadcast(sync: true);

  @override
  Stream<List<StickerRef>> watchSavedStickers() async* {
    yield _parseStickers(jsonDecode(await db.getValue(_savedStickersKey) ?? '[]'));
    yield* _savedStickerChanges.stream;
  }

  /// Malformed entries (from a newer version, say) are left out, and all
  /// but the first of a sticker (kept both named and as its picture by
  /// different versions, say).
  static List<StickerRef> _parseStickers(Object? list) {
    final seen = <String>{};
    return [
      for (final entry in list is List ? list : const [])
        if (_tryParseSticker(entry) case final sticker? when seen.add(sticker.key)) sticker,
    ];
  }

  static StickerRef? _tryParseSticker(Object? json) {
    if (json is! Map) return null;
    try {
      return StickerRef.fromJson(json.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  Future<void> _keepSavedStickers(List<StickerRef> stickers) async {
    await db.setValue(_savedStickersKey, jsonEncode([for (final s in stickers) s.toJson()]));
    if (!_savedStickerChanges.isClosed) _savedStickerChanges.add(stickers);
  }

  /// Takes the stickers from the account data: on start, and when another
  /// device changed them.
  Future<void> _loadSavedStickers() async {
    final store = _accountData;
    if (store == null || _disposed) return;
    final read = await store.read(_stickersData);
    if (read != null) await _keepSavedStickers(_parseStickers(read.value?['stickers']));
  }

  @override
  Future<void> setStickerSaved(StickerRef sticker, bool saved) async {
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    var keep = sticker;
    if (saved && sticker.isNamed) {
      // Kept as its picture, it stays when its pack goes; one of a pack the
      // user does not have stays named, and shows once they add the pack.
      try {
        keep = await _uploadedPackSticker(sticker);
      } on StickerPackMissing {
        keep = sticker;
      }
    }
    late List<StickerRef> stickers;
    await store.update(_stickersData, (current) {
      final kept = current?['stickers'];
      // Those this version cannot read stay as they are, as later versions'.
      final entries = <Object?>[
        if (saved) keep.toJson(),
        for (final entry in kept is List ? kept : const [])
          if (_tryParseSticker(entry)?.key != keep.key) entry,
      ];
      Map<String, Object?> data() => {...?current, 'stickers': entries};
      // The oldest go when the list is full.
      while (entries.length > maxSavedStickers || utf8.encode(jsonEncode(data())).length > _maxSavedStickerBytes) {
        entries.removeLast();
      }
      stickers = _parseStickers(entries);
      return data();
    });
    await _keepSavedStickers(stickers);
  }

  @override
  Future<StickerRef> makeSticker(String path) async {
    final sticker = StickerRef.media(await _uploadPrepared(await prepareSticker(path, tempDir)));
    await setStickerSaved(sticker, true);
    return sticker;
  }

  /// [made] encrypted and uploaded, then deleted; this device keeps it in its
  /// media cache.
  Future<MediaRef> _uploadPrepared(PreparedPicture made) async {
    try {
      final upload = await _encryptForUpload(made.file);
      try {
        await api.uploadFile(upload.file, 'application/octet-stream');
      } finally {
        await upload.file.delete();
      }
      await media.put(upload.hash, made.file);
      return MediaRef(
        hash: upload.hash,
        size: await made.file.length(),
        mime: made.mime,
        width: made.width,
        height: made.height,
        key: base64.encode(upload.key),
      ).at(_host);
    } finally {
      await made.file.delete();
    }
  }

  // Sticker packs

  /// Account data holding the sticker packs the user keeps (see [PackList]).
  static const _packsData = 'packs';

  /// The packs as last seen, for starts without a connection.
  static const _packsKey = 'packs.list';

  /// What this device uploaded of a pack's stickers, to send each again
  /// without uploading: `packs.media.<the pack's folder>.<sticker>`.
  static const _packMediaPrefix = 'packs.media.';

  /// The largest a pack's file can be once encrypted.
  static final _maxPackDownload = FileCipher.encryptedSize(FileCipher.paddedLength(stickerPackLimits.maxBytes));

  /// Packs extracted on this device.
  final StickerPackStore _packStore;

  final _packChanges = StreamController<List<StickerPack>>.broadcast(sync: true);
  PackList? _packList;

  /// Files of packs that could not be fetched this time.
  final _failedPacks = <String>{};

  /// Files of packs being added: not listed yet, but not to be collected.
  final _keepingPacks = <String>{};

  Future<void> _fetchingPacks = Future.value();
  var _packFetchQueued = false;

  Future<PackList> _packs() async {
    final known = _packList;
    if (known != null) return known;
    final stored = await db.getValue(_packsKey);
    return _packList ??= PackList.fromJson(stored == null ? null : jsonDecode(stored) as Map<String, Object?>);
  }

  @override
  Stream<List<StickerPack>> watchStickerPacks() async* {
    yield await _packViews();
    yield* _packChanges.stream;
  }

  /// The packs as the picker shows them: those on this device, and those
  /// still being fetched.
  Future<List<StickerPack>> _packViews() async {
    final list = await _packs();
    final views = <StickerPack>[];
    for (final entry in list.entries) {
      final stored = await _packStore.load(entry.archive.hash);
      if (stored != null) {
        views.add(stored.view(entry));
      } else {
        final failed = _failedPacks.contains(entry.archive.hash);
        views.add(
          StickerPack(
            id: entry.id,
            title: entry.title,
            archive: entry.archive,
            state: failed ? StickerPackState.failed : StickerPackState.fetching,
          ),
        );
      }
    }
    return views;
  }

  Future<StickerPack?> _packView(String id) async => (await _packViews()).where((p) => p.id == id).firstOrNull;

  Future<void> _emitPacks() async {
    if (_packChanges.isClosed) return;
    final views = await _packViews();
    if (!_packChanges.isClosed) _packChanges.add(views);
  }

  Future<void> _keepPacks(PackList list) async {
    _packList = list;
    await db.setValue(_packsKey, jsonEncode(list.toJson()));
    await _emitPacks();
  }

  /// Takes the packs from the account data: on start, and when another
  /// device changed them. Then fetches those not on this device yet.
  Future<void> _loadPacks() async {
    final store = _accountData;
    if (store == null || _disposed) return;
    final read = await store.read(_packsData);
    if (read == null) return;
    await _keepPacks(PackList.fromJson(read.value));
    await _fetchPacks();
  }

  /// Fetches the packs the user keeps that are not on this device, one after
  /// another, then deletes those they no longer keep. Requests that pile up
  /// meanwhile run once.
  Future<void> _fetchPacks() {
    if (_packFetchQueued) return _fetchingPacks;
    _packFetchQueued = true;
    Future<void> run() {
      _packFetchQueued = false;
      return _fetchPacksNow();
    }

    return _fetchingPacks = _fetchingPacks.then((_) => run(), onError: (_) => run());
  }

  Future<void> _fetchPacksNow() async {
    // Those that failed before are tried again.
    _failedPacks.clear();
    for (final entry in (await _packs()).entries) {
      if (_disposed) return;
      final hash = entry.archive.hash;
      if (await _packStore.load(hash) != null) continue;
      try {
        final (bytes: _, :pack) = await _downloadPack(entry.archive);
        if (pack.manifest.id != entry.id) throw const PackageException('This sticker pack is not the one listed');
        await _packStore.install(pack, hash);
      } on Object catch (e) {
        _log.warning('Could not fetch sticker pack ${entry.id}: $e');
        _failedPacks.add(hash);
      }
      await _emitPacks();
    }
    if (!_disposed) await _collectPacks();
  }

  /// Fetches and checks the pack whose file is [archive].
  Future<({Uint8List bytes, StickerPackFile pack})> _downloadPack(MediaRef archive) async {
    final key = archive.key;
    if (key == null) throw const PackageException('This sticker pack is damaged');
    if (archive.size > stickerPackLimits.maxBytes) throw const PackageException('This sticker pack is too large');
    final file = await media.get(
      archive.hash,
      key: base64.decode(key),
      host: _elsewhere(archive),
      maxBytes: _maxPackDownload,
    );
    try {
      final bytes = await file.readAsBytes();
      return (bytes: bytes, pack: await readStickerPack(bytes));
    } finally {
      // Kept extracted instead.
      await media.remove(archive.hash);
    }
  }

  /// Deletes the packs the user no longer keeps from this device, and what
  /// it noted of their stickers.
  Future<void> _collectPacks() async {
    final keep = {for (final entry in (await _packs()).entries) entry.archive.hash, ..._keepingPacks};
    await _packStore.gc(keep);
    final folders = {for (final hash in keep) StickerPackStore.folderName(hash)};
    for (final key in (await db.valuesWithPrefix(_packMediaPrefix)).keys) {
      if (!folders.contains(key.substring(_packMediaPrefix.length).split('.').first)) await db.setValue(key, null);
    }
  }

  @override
  Future<StickerPack> addStickerPack(StickerSource source) async {
    final kept = await _packView(source.pack);
    // A pack the user has stays as it is: a sticker from a chat never
    // replaces it (only its file would, see importStickerPack).
    if (kept != null && kept.archive != null) return kept;
    final archive = source.archive;
    if (archive == null) throw const PackageException('This sticker did not come with its pack');
    if (_accountData == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    final (:bytes, :pack) = await _downloadPack(archive);
    if (pack.manifest.id != source.pack) throw const PackageException('This is not the pack the sticker came from');
    return _keepPack(bytes, pack, replace: false);
  }

  @override
  Future<StickerPack> importStickerPack(String path, {bool replace = false}) async {
    final file = File(path);
    if (await file.length() > stickerPackLimits.maxBytes) {
      throw PackageException('This sticker pack is larger than ${stickerPackLimits.maxBytes ~/ (1024 * 1024)} MB');
    }
    final bytes = await file.readAsBytes();
    final pack = await readStickerPack(bytes);
    final kept = (await _packs())[pack.manifest.id];
    if (kept != null && !replace) throw StickerPackInstalled(kept.title);
    return _keepPack(bytes, pack, replace: true);
  }

  /// Uploads [bytes], the file of [pack], to the user's server with a key of
  /// its own (whatever becomes of where it came from, theirs stays), extracts
  /// it and lists it among their packs: in place of one of its ID if
  /// [replace], else only if they have none (another device may have added
  /// it meanwhile).
  Future<StickerPack> _keepPack(Uint8List bytes, StickerPackFile pack, {required bool replace}) async {
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    final id = pack.manifest.id;
    final archive = await _uploadPack(bytes);
    _keepingPacks.add(archive.hash);
    try {
      await _packStore.install(pack, archive.hash);
      late PackList list;
      await store.update(_packsData, (current) {
        list = PackList.fromJson(current);
        if (!replace && list[id] != null) return null;
        list = list.withAdded(PackEntry(id: id, title: pack.manifest.title, archive: archive));
        return list.toJson();
      });
      await _keepPacks(list);
    } finally {
      _keepingPacks.remove(archive.hash);
    }
    unawaited(_fetchPacks());
    return (await _packView(id))!;
  }

  Future<MediaRef> _uploadPack(Uint8List bytes) async {
    await tempDir.create(recursive: true);
    final plain = await File('${tempDir.path}/pack-${newUlid()}.zip').writeAsBytes(bytes);
    try {
      final upload = await _encryptForUpload(plain);
      try {
        await api.uploadFile(upload.file, 'application/octet-stream');
      } finally {
        await upload.file.delete();
      }
      return MediaRef(
        hash: upload.hash,
        size: bytes.length,
        mime: 'application/zip',
        key: base64.encode(upload.key),
      ).at(_host);
    } finally {
      await plain.delete();
    }
  }

  @override
  Future<void> removeStickerPack(String id) async {
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    late PackList list;
    await store.update(_packsData, (current) => (list = PackList.fromJson(current).withRemoved(id)).toJson());
    await _keepPacks(list);
    await _collectPacks();
  }

  /// What a message carries for [sticker]: a pack's sticker goes as its
  /// picture, with its pack beside it (see [StickerSource]), the picture
  /// uploaded once on this device, by the outbox ([upload] is the encrypted
  /// file). The user's own stickers are uploaded already. Throws
  /// [StickerPackMissing] for one of a pack the user does not have.
  Future<(StickerRef sticker, String? upload)> _stickerToSend(StickerRef sticker) async {
    final named = sticker.packSticker;
    if (named == null) return (sticker, null);
    final pack = await _packView(named.pack);
    final item = pack?[named.id];
    final (archive, path) = (pack?.archive, item?.path);
    if (pack == null || item == null || archive == null || path == null) {
      // A kept one goes as it is.
      if (sticker.media != null) return (sticker, null);
      throw const StickerPackMissing();
    }
    final source = pack.sourceFor(named.id);
    final sent = await _sentPackSticker(archive.hash, named.id);
    if (sent != null) return (StickerRef.media(sent, source: source), null);
    // Kept before this device sent one of its own: on a server already.
    if (sticker.media case final media?) return (StickerRef.media(media, source: source), null);
    final plain = File(path);
    final encrypted = await _encryptForUpload(plain);
    // This device shows it without downloading anything.
    await media.put(encrypted.hash, plain);
    final picture = MediaRef(
      hash: encrypted.hash,
      size: await plain.length(),
      mime: item.mime ?? 'image/webp',
      width: item.width,
      height: item.height,
      key: base64.encode(encrypted.key),
    ).at(_host);
    return (StickerRef.media(picture, source: source), encrypted.file.path);
  }

  /// [sticker], named from a pack, as its picture: uploaded now if this device
  /// never has.
  Future<StickerRef> _uploadedPackSticker(StickerRef sticker) async {
    final (uploaded, upload) = await _stickerToSend(sticker);
    if (upload != null) {
      try {
        await api.uploadFile(File(upload), 'application/octet-stream');
      } finally {
        await File(upload).delete();
      }
      await _noteSentPackSticker(uploaded);
    }
    return uploaded;
  }

  String _packStickerKey(String archiveHash, String sticker) =>
      '$_packMediaPrefix${StickerPackStore.folderName(archiveHash)}.$sticker';

  Future<MediaRef?> _sentPackSticker(String archiveHash, String sticker) async {
    final stored = await db.getValue(_packStickerKey(archiveHash, sticker));
    if (stored == null) return null;
    try {
      return MediaRef.fromJson(jsonDecode(stored) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  /// Notes the picture of a pack's sticker this device uploaded.
  Future<void> _noteSentPackSticker(StickerRef sticker) async {
    final (picture, source) = (sticker.media, sticker.source);
    final archive = source?.archive;
    if (picture == null || source == null || archive == null || picture.host != _host) return;
    await db.setValue(_packStickerKey(archive.hash, source.id), jsonEncode(picture.toJson()));
  }

  // Custom emojis

  /// Account data holding the user's own custom emojis:
  /// `{"emojis": {name: MediaRef}}`.
  static const _emojisData = 'emojis';

  /// The user's emojis as last seen, for starts without a connection.
  static const _myEmojisKey = 'emojis.mine';

  final _myEmojiChanges = StreamController<Map<String, MediaRef>>.broadcast(sync: true);

  Future<Map<String, MediaRef>> _myEmojis() async =>
      CustomEmoji.parse(jsonDecode(await db.getValue(_myEmojisKey) ?? '{}'));

  @override
  Stream<Map<String, MediaRef>> watchEmojis({String? conversationId}) async* {
    if (conversationId != null) {
      yield* db.watchGroupDocument(conversationId).map((document) => document?.emojis ?? const {});
      return;
    }
    yield await _myEmojis();
    yield* _myEmojiChanges.stream;
  }

  Future<void> _keepMyEmojis(Map<String, MediaRef> emojis) async {
    await db.setValue(_myEmojisKey, jsonEncode(CustomEmoji.toJson(emojis) ?? const <String, Object?>{}));
    if (!_myEmojiChanges.isClosed) _myEmojiChanges.add(emojis);
  }

  /// Takes the user's emojis from the account data: on start, and when
  /// another device changed them.
  Future<void> _loadMyEmojis() async {
    final store = _accountData;
    if (store == null || _disposed) return;
    final read = await store.read(_emojisData);
    if (read != null) await _keepMyEmojis(CustomEmoji.parse(read.value?['emojis']));
  }

  @override
  Future<MediaRef> uploadEmoji(String path) async => _uploadPrepared(await prepareEmoji(path, tempDir));

  @override
  Future<void> changeEmojis(
    Map<String, MediaRef> Function(Map<String, MediaRef> current) change, {
    String? conversationId,
  }) async {
    if (conversationId != null) {
      return _changeGroup(
        conversationId,
        (current) => GroupDocument(
          salt: current.salt,
          title: current.title,
          description: current.description,
          picture: current.picture,
          emojis: changedEmojis(current.emojis, change),
          extra: current.extra,
        ),
      );
    }
    final store = _accountData;
    if (store == null) throw const ApiException(0, 'not_ready', 'Not connected yet');
    late Map<String, MediaRef> emojis;
    await store.update(_emojisData, (current) {
      emojis = changedEmojis(CustomEmoji.parse(current?['emojis']), change);
      return {'emojis': CustomEmoji.toJson(emojis) ?? const <String, Object?>{}};
    });
    await _keepMyEmojis(emojis);
  }

  /// The custom emojis [text] uses, written in [conv]: [known] ones (an
  /// edited message's) first, then the group's, then the user's own.
  Future<Map<String, MediaRef>> _emojisIn(String conv, String text, {Map<String, MediaRef> known = const {}}) async {
    if (!text.contains(':')) return const {};
    return emojisIn(
      text,
      known: known,
      group: (await db.groupDocument(conv))?.emojis ?? const {},
      mine: await _myEmojis(),
    );
  }

  /// How a new message quotes [messageId].
  Future<ReplyRef?> _quote(String? messageId) async {
    if (messageId == null) return null;
    final original = await db.resolvedMessage(messageId);
    if (original == null || original.isDeleted) return null;
    return ReplyRef(id: original.id, from: original.senderId, text: AppDatabase.quotePreview(original.envelope));
  }

  @override
  Future<void> react(String messageId, String emoji, {bool remove = false}) async {
    final target = await db.resolvedMessage(messageId);
    if (target == null || target.isDeleted) return;
    await send(
      PendingMessage(
        Envelope.reaction(conv: target.envelope.conv, from: me, target: messageId, emoji: emoji, remove: remove),
      ),
    );
  }

  @override
  Future<void> editMessage(String messageId, String text) async {
    final target = await db.resolvedMessage(messageId);
    if (target == null || target.senderId != me || target.envelope.messageType != MessageType.text) return;
    final conv = target.envelope.conv;
    final emojis = await _emojisIn(conv, text, known: target.envelope.emojis);
    if (target.seq == null) {
      // Not sent yet: it goes out with the new text.
      return db.setPendingText(messageId, text, emojis: emojis);
    }
    await send(PendingMessage(Envelope.edit(conv: conv, from: me, target: messageId, text: text, emojis: emojis)));
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    final target = await db.resolvedMessage(messageId);
    if (target == null || target.senderId != me || target.isDeleted) return;
    // Never sent: nobody else has it.
    if (target.seq == null) return discard(messageId);
    await send(PendingMessage(Envelope.delete(conv: target.envelope.conv, from: me, target: messageId)));
  }

  @override
  Future<void> setDisplayName(String name) => _changeProfile(
    (current) => ProfileDocument(displayName: name, avatar: current.avatar, card: current.card, extra: current.extra),
  );

  @override
  Future<void> setAvatar(String? path) async {
    final avatar = path == null ? null : await _uploadPicture(path);
    await _changeProfile(
      (current) => ProfileDocument(displayName: current.displayName, avatar: avatar, card: current.card, extra: current.extra),
    );
  }

  @override
  Future<void> setProfileCard(ProfileCard card) async {
    final json = utf8.encode(jsonEncode(card.toJson()));
    final file = card.isEmpty ? null : await _uploadJson(json);
    await _changeProfile(
      (current) => ProfileDocument(displayName: current.displayName, avatar: current.avatar, card: file, extra: current.extra),
    );
    // This device has it already.
    if (file != null) await db.setFetchedCard(me, file.hash, utf8.decode(json));
  }

  @override
  Future<void> setGroupPicture(String conversationId, String? path) async {
    final picture = path == null ? null : await _uploadPicture(path);
    await _changeGroup(
      conversationId,
      (current) => GroupDocument(
        salt: current.salt,
        title: current.title,
        description: current.description,
        picture: picture,
        emojis: current.emojis,
        extra: current.extra,
      ),
    );
  }

  /// Changes a group's document. Should another member's commit come first,
  /// this runs again on what that one made of it, so neither change is lost.
  Future<void> _changeGroup(String conv, GroupDocument Function(GroupDocument current) change) async {
    await started;
    for (var attempt = 0; ; attempt++) {
      try {
        await _serial(() async {
          await groups.changeDocument(conv, change);
          await _afterGroupWork();
        });
        return;
      } on StaleGroup {
        if (attempt >= 8) rethrow;
        _log.debug('Changing $conv waits: this device is catching up');
        await _serial(_catchUp);
        await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      }
    }
  }

  /// Crops the image at [path] to a profile picture and uploads it,
  /// encrypted with a key of its own.
  Future<MediaRef> _uploadPicture(String path) async {
    final picture = await prepareAvatar(path, tempDir);
    try {
      final upload = await _encryptForUpload(picture);
      try {
        await api.uploadFile(upload.file, 'application/octet-stream');
      } finally {
        await upload.file.delete();
      }
      await media.put(upload.hash, picture);
      return MediaRef(
        hash: upload.hash,
        size: await picture.length(),
        mime: 'image/jpeg',
        width: avatarSize,
        height: avatarSize,
        key: base64.encode(upload.key),
      ).at(_host);
    } finally {
      await picture.delete();
    }
  }

  /// Queues any message (text or media) in the outbox and tries to send it.
  Future<void> send(PendingMessage message) async {
    await db.insertPending(message);
    unawaited(flushOutbox());
  }

  @override
  int? get maxUploadBytes => _serverInfo?.maxUploadBytes;

  @override
  Future<void> sendAttachment(
    String conversationId, {
    required String path,
    required String name,
    String? replyTo,
  }) async {
    final limit = maxUploadBytes;
    final size = await File(path).length();
    if (limit != null && size > limit) {
      throw AttachmentException('"$name" is too large; this server accepts files up to ${limit ~/ (1024 * 1024)} MB');
    }
    final prepared = await prepareAttachment(path: path, name: name, tempDir: tempDir, probeVideo: probeVideo);
    final original = await _encryptForUpload(File(prepared.path));
    final thumbPath = prepared.thumbnailPath;
    final thumb = thumbPath == null ? null : await _encryptForUpload(File(thumbPath));
    final plain = prepared.media;
    final ref = MediaRef(
      hash: original.hash,
      size: plain.size,
      mime: plain.mime,
      name: plain.name,
      width: plain.width,
      height: plain.height,
      durationMs: plain.durationMs,
      key: base64.encode(original.key),
      thumb: thumb == null
          ? null
          : MediaRef(hash: thumb.hash, size: plain.thumb!.size, mime: plain.thumb!.mime, key: base64.encode(thumb.key)),
    ).at(_host);
    // This device shows the plaintext without downloading anything.
    await media.put(original.hash, File(prepared.path));
    if (thumb != null) await media.put(thumb.hash, File(thumbPath!));
    await send(
      PendingMessage(
        Envelope.media(
          conv: conversationId,
          from: me,
          type: prepared.type,
          media: ref,
          replyTo: await _quote(replyTo),
        ),
        attachmentPath: original.file.path,
        thumbnailPath: thumb?.file.path,
      ),
    );
  }

  /// Encrypts a file with a fresh key into the outgoing folder; the outbox
  /// uploads it from there.
  Future<({File file, String hash, List<int> key})> _encryptForUpload(File plain) async {
    final key = randomBytes(32);
    final dir = await Directory('${media.root.path}/outgoing').create(recursive: true);
    final tmp = File('${dir.path}/${newUlid()}');
    await FileCipher.encrypt(plain.path, tmp.path, key, maxSize: maxUploadBytes);
    final hash = await hashFile(tmp.path);
    final file = await tmp.rename('${dir.path}/${hash.substring('sha256:'.length)}');
    return (file: file, hash: hash, key: key);
  }

  @override
  Future<File?> mediaFile(MediaRef ref, {void Function(double progress)? onProgress}) => media.get(
    ref.hash,
    key: ref.key == null ? null : base64.decode(ref.key!),
    host: _elsewhere(ref),
    onProgress: onProgress,
  );

  /// The host of [ref]'s server, if it is another than this user's.
  String? _elsewhere(MediaRef ref) => ref.host == _host ? null : ref.host;

  /// The host of this user's server, where what they upload is.
  String get _host => UserId.parse(me).host;

  @override
  File? cachedMediaFile(String hash) => media.cached(hash);

  @override
  Future<void> retry(String messageId) async {
    await db.setState(messageId, DeliveryState.pending);
    unawaited(flushOutbox());
  }

  @override
  Future<void> discard(String messageId) => db.deleteMessage(messageId);

  @override
  Future<void> markRead(String conversationId) async {
    final newest = await db.newestSeq(conversationId);
    final conversation = await db.conversation(conversationId);
    if (newest == null || conversation == null || newest <= conversation.readUpTo) return;
    // Optimistic: the badge clears at once; the server tells the other devices.
    await db.advanceReadMarker(conversationId, newest);
    unawaited(_notifySynced());
    await _sendReadMarker(conversationId, newest);
  }

  Future<void> _sendReadMarker(String conversationId, int upTo) async {
    try {
      await _socket.markRead(conversationId, upTo);
    } on ApiException catch (e) {
      if (e.isUnauthorized) return _signedOut();
      if (!e.isPermanent) _pendingReads[conversationId] = upTo; // Resent after reconnecting.
    }
  }

  @override
  Future<String> openDirectConversation(String userId) async {
    final existing = await db.directConversationWith(userId);
    if (existing != null) return existing;
    final contact = await db.contact(userId);
    if (contact == null || contact.state != ContactState.accepted || !contact.trusted) {
      throw StateError('Add ${UserId.fallbackName(userId, me: me)} as a contact first.');
    }
    await started;
    return _startDirectChat(userId);
  }

  @override
  Future<String> createGroup(String title, List<String> members) async {
    await started;
    return _serial(() => groups.createConversation(members: members, title: title.trim()));
  }

  @override
  Future<void> addMember(String conversationId, String userId, {bool shareHistory = true}) async {
    await started;
    await _serial(() => groups.addUser(conversationId, userId));
    // Someone just added has no keys to what came before: share them, unless
    // the user chose not to; its keys are put together when it goes out.
    if (shareHistory) await send(PendingMessage(Envelope.history(conv: conversationId, from: me, user: userId)));
  }

  @override
  Future<void> renameGroup(String conversationId, String title) => _changeGroup(
    conversationId,
    (current) => GroupDocument(
      salt: current.salt,
      title: title.trim(),
      description: current.description,
      picture: current.picture,
      emojis: current.emojis,
      extra: current.extra,
    ),
  );

  @override
  Future<void> setGroupDescription(String conversationId, String? description) => _changeGroup(
    conversationId,
    (current) => GroupDocument(
      salt: current.salt,
      title: current.title,
      description: description == null || description.trim().isEmpty ? null : description.trim(),
      picture: current.picture,
      emojis: current.emojis,
      extra: current.extra,
    ),
  );

  /// The server's member_removed event then removes the group from all of
  /// the user's devices (see [_applyInOrder]).
  @override
  Future<void> leaveGroup(String conversationId) async {
    await started;
    // Said by the one leaving, signed, while they still can: the server's
    // event says so too, but only as the server's word. Leaving does not wait
    // for it for long, nor depend on it.
    final line = Envelope.member(conv: conversationId, from: me, change: 'left');
    await send(PendingMessage(line));
    try {
      await watchMessages(conversationId)
          .firstWhere((l) => l.any((m) => m.envelope.id == line.id && m.state != DeliveryState.pending))
          .timeout(_leaveLineWait);
    } on TimeoutException {
      _log.info('Leaving $conversationId without having said so first: it could not be sent in time');
    }
    await api.leaveConversation(conversationId);
  }

  /// How long leaving waits for the line saying so to go out.
  static const _leaveLineWait = Duration(seconds: 10);

  @override
  void sendTyping(String conversationId) {
    final last = _typingSent[conversationId];
    final now = DateTime.now();
    if (last != null && now.difference(last) < _typingResend) return;
    _typingSent[conversationId] = now;
    _socket.sendTyping(conversationId);
  }

  @override
  Stream<Set<String>> watchTyping(String conversationId) async* {
    Set<String> current() => {...?_typing[conversationId]?.keys};
    yield current();
    yield* _typingChanges.stream.where((c) => c == conversationId).map((_) => current());
  }

  void _onTyping(String conv, String user) {
    if (_disposed || user == me) return;
    final users = _typing.putIfAbsent(conv, () => {});
    users[user]?.cancel();
    users[user] = Timer(_typingShownFor, () => _stopTyping(conv, user));
    _typingChanges.add(conv);
  }

  void _stopTyping(String conv, String user) {
    final timer = _typing[conv]?.remove(user);
    if (timer == null) return;
    timer.cancel();
    if (!_typingChanges.isClosed) _typingChanges.add(conv);
  }

  @override
  Future<void> loadOlderMessages(String conversationId) async {
    // Not open yet: the user can scroll up again later.
    if (_mls == null || !_loadingHistory.add(conversationId)) return;
    try {
      final conversation = await db.conversation(conversationId);
      if (conversation == null || !conversation.moreHistory) return;
      final page = await api.history(conversationId, before: await db.oldestSeq(conversationId));
      await _serial(() async {
        final received = <int, ReceivedMessage>{};
        for (final event in page.messages) {
          received[event.seq] = await groups.decrypt(event);
        }
        await db.addHistory(conversationId, page, received);
        unawaited(_restoreKeys(conversationId));
      });
    } on ApiException {
      // Offline: the user can scroll up again later.
    } finally {
      _loadingHistory.remove(conversationId);
    }
  }

  // Verified contacts

  /// Reads which contacts the user verified (from any device): their
  /// attestations, checked against the user's own identity key.
  Future<void> refreshTrust() async {
    final own = _ownIdentityKey;
    if (own == null) return;
    for (final MapEntry(key: user, value: data) in (await api.attestations()).entries) {
      final statement = await Attestation.open(data, userId: user, signerKey: own);
      // Only newer statements count: a missing, forged or replayed one
      // changes nothing.
      if (statement == null || statement.at <= ((await db.pinnedIdentity(user))?.verifiedAt ?? 0)) continue;
      final key = statement.identityKey;
      _log.info(
        key == null ? '$user is no longer verified (on another device)' : '$user was verified on another device',
      );
      // Verified on another device: the key is the one to trust.
      if (key != null) await db.pinIdentity(user, key);
      await db.setVerifiedKey(user, key, at: statement.at);
      keys.invalidate(user);
      for (final conv in await db.conversationsWith(user)) {
        await _reconcile(conv);
      }
    }
  }

  /// [userId]'s identity key checked out in emoji verification: attest it
  /// for the user's other devices and trust it here.
  Future<void> markVerified(String userId, String identityKey) async {
    await started;
    final statement = await _attest(userId, identityKey);
    if (statement == null) return;
    _log.info('Verified $userId');
    await _serial(() async {
      await db.pinIdentity(userId, identityKey);
      await db.setVerifiedKey(userId, identityKey, at: statement.at);
      keys.invalidate(userId);
      for (final conv in await db.conversationsWith(userId)) {
        await _reconcile(conv);
      }
      await _refreshProfileOf(userId); // It may have waited for this.
    });
    unawaited(flushOutbox());
  }

  /// Signs and stores the user's statement that [identityKey] is [userId]'s
  /// verified key (null: none is), newer than any before it.
  Future<Attestation?> _attest(String userId, String? identityKey) async {
    final own = await identity.localIdentity();
    if (own == null) return null;
    final previous = (await db.pinnedIdentity(userId))?.verifiedAt ?? 0;
    // Later than the last statement even if this device's clock is behind.
    final at = max(clock().millisecondsSinceEpoch, previous + 1);
    final statement = Attestation(userId: userId, identityKey: identityKey, at: at);
    await api.putAttestation(userId, await statement.sign(own));
    return statement;
  }

  @override
  Stream<Set<String>> watchVerifiedUsers() => db.watchVerifiedUsers();

  @override
  Stream<Set<String>> watchIdentityChanges() =>
      db.watchChangedIdentities().map((pins) => {for (final p in pins) p.userId});

  @override
  Future<void> acceptIdentityChange(String userId) async {
    await started;
    _log.info("Accepted $userId's new key");
    // Verified the old key: the new one is not, on any of the user's devices.
    // Stated first, or the next trust refresh brings the old key back.
    if ((await db.pinnedIdentity(userId))?.verifiedKey != null) {
      final statement = await _attest(userId, null);
      if (statement != null) await db.setVerifiedKey(userId, null, at: statement.at);
    }
    await _serial(() async {
      await keys.acceptIdentityChange(userId);
      for (final conv in await db.conversationsWith(userId)) {
        await _reconcile(conv);
      }
      await _refreshProfileOf(userId); // It may have waited for this.
    });
    unawaited(flushOutbox());
  }

  @override
  Future<List<DeviceInfo>> devices() => api.devices();

  @override
  Future<void> revokeDevice(String deviceId) => api.revokeDevice(deviceId);
}

/// Placeholder used while nobody is signed in, so widgets that are about to
/// be replaced by the login screen never see an error.
class SignedOutRepository implements ChatRepository {
  const SignedOutRepository();

  @override
  String get me => '';

  @override
  Stream<List<ConversationSummary>> watchConversations() => Stream.value(const []);

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) => Stream.value(const []);

  @override
  Stream<List<UserProfile>> watchProfiles() => Stream.value(const []);

  @override
  Stream<ConnectionStatus> watchConnection() => Stream.value(ConnectionStatus.offline);

  @override
  Stream<String?> watchConnectionProblem() => Stream.value(null);

  @override
  Future<void> sendText(String conversationId, String text, {String? replyTo, LinkPreviewDraft? link}) async {}

  @override
  Future<void> sendAttachment(
    String conversationId, {
    required String path,
    required String name,
    String? replyTo,
  }) async {}

  @override
  Future<void> sendGif(String conversationId, GifRef gif, {String? replyTo}) async {}

  @override
  Future<void> sendSticker(String conversationId, StickerRef sticker, {String? replyTo}) async {}

  @override
  Stream<List<GifRef>> watchSavedGifs() => Stream.value(const []);

  @override
  Future<void> setGifSaved(GifRef gif, bool saved) async {}

  @override
  Stream<List<StickerRef>> watchSavedStickers() => Stream.value(const []);

  @override
  Future<void> setStickerSaved(StickerRef sticker, bool saved) async {}

  @override
  Future<StickerRef> makeSticker(String path) => throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Stream<List<StickerPack>> watchStickerPacks() => Stream.value(const []);

  @override
  Future<StickerPack> addStickerPack(StickerSource source) => throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Future<StickerPack> importStickerPack(String path, {bool replace = false}) =>
      throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Future<void> removeStickerPack(String id) => throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Stream<Map<String, MediaRef>> watchEmojis({String? conversationId}) => Stream.value(const {});

  @override
  Future<MediaRef> uploadEmoji(String path) => throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Future<void> changeEmojis(
    Map<String, MediaRef> Function(Map<String, MediaRef> current) change, {
    String? conversationId,
  }) => throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Future<String?> klipyApiKey() async => null;

  @override
  Future<bool> callsAvailable() async => false;

  @override
  Future<bool> videoAvailable() async => false;

  @override
  Stream<Map<String, Call>> watchCalls() => Stream.value(const {});

  @override
  void noteCall(Call call) {}

  @override
  Future<CallJoin> joinCall(String conversationId, {bool video = false}) =>
      throw const ApiException(0, 'not_ready', 'Not signed in');

  @override
  Future<void> declineCall(String callId) async {}

  @override
  Future<void> leaveCall(String callId) async {}

  @override
  Stream<CallKey?> watchCallKeys(String conversationId, String callId) => Stream.value(null);

  @override
  int? get maxUploadBytes => null;

  @override
  Future<void> react(String messageId, String emoji, {bool remove = false}) async {}

  @override
  Future<void> editMessage(String messageId, String text) async {}

  @override
  Future<void> deleteMessage(String messageId) async {}

  @override
  Stream<Map<String, ContactState>> watchContacts() => Stream.value(const {});

  @override
  Future<ContactState> requestContact(String userId) => throw StateError('Not signed in');

  @override
  Future<void> acceptContact(String userId) => throw StateError('Not signed in');

  @override
  Future<void> declineContact(String userId) async {}

  @override
  Future<void> cancelContactRequest(String userId) async {}

  @override
  Future<void> removeContact(String userId) async {}

  @override
  Future<void> blockContact(String userId) async {}

  @override
  Future<void> unblockContact(String userId) async {}

  @override
  Future<void> setDisplayName(String name) async {}

  @override
  Future<void> setAvatar(String? path) async {}

  @override
  Future<void> setProfileCard(ProfileCard card) async {}

  @override
  Stream<Map<String, ChatSettings>> watchChatSettings() => Stream.value(const {});

  @override
  Future<void> setChatSettings(String conversationId, ChatSettings settings) async {}

  @override
  Stream<Map<String, Presence>> watchPresence() => Stream.value(const {});

  @override
  Stream<PresenceMode> watchPresenceMode() => Stream.value(PresenceMode.auto);

  @override
  Future<void> setPresenceMode(PresenceMode mode) async {}

  @override
  void setActive(bool active) {}

  @override
  Future<void> setGroupPicture(String conversationId, String? path) async {}

  @override
  Future<File?> mediaFile(MediaRef media, {void Function(double progress)? onProgress}) async => null;

  @override
  File? cachedMediaFile(String hash) => null;

  @override
  Stream<Set<String>> watchIdentityChanges() => Stream.value(const {});

  @override
  Stream<Set<String>> watchVerifiedUsers() => Stream.value(const {});

  @override
  Future<void> acceptIdentityChange(String userId) async {}

  @override
  Future<void> markRead(String conversationId) async {}

  @override
  Future<String> openDirectConversation(String userId) => throw StateError('Not signed in');

  @override
  Future<String> createGroup(String title, List<String> members) => throw StateError('Not signed in');

  @override
  Future<void> addMember(String conversationId, String userId, {bool shareHistory = true}) async {}

  @override
  Future<void> renameGroup(String conversationId, String title) async {}

  @override
  Future<void> setGroupDescription(String conversationId, String? description) async {}

  @override
  Future<void> leaveGroup(String conversationId) async {}

  @override
  void sendTyping(String conversationId) {}

  @override
  Stream<Set<String>> watchTyping(String conversationId) => Stream.value(const {});

  @override
  Future<void> loadOlderMessages(String conversationId) async {}

  @override
  Future<void> retry(String messageId) async {}

  @override
  Future<void> discard(String messageId) async {}

  @override
  Future<List<DeviceInfo>> devices() async => const [];

  @override
  Future<void> revokeDevice(String deviceId) async {}
}
