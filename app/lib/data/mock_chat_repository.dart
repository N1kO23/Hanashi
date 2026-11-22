import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hashlib/hashlib.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'chat_repository.dart';
import 'custom_emojis.dart';
import 'models.dart';
import 'packs/content_package.dart';
import 'packs/sticker_pack.dart';
import 'packs/sticker_pack_file.dart';
import 'remote/api_client.dart' show ApiException;
import 'remote/link_previews.dart';

/// In-memory [ChatRepository] with sample data, used until the server exists
/// and for UI tests. Simulates server acknowledgement and canned replies.
class MockChatRepository implements ChatRepository {
  MockChatRepository({
    this.latency = const Duration(milliseconds: 400),
    this.autoReply = true,
    DateTime? now,
  }) : _clock = now == null ? DateTime.now : (() => now) {
    _seed(_clock());
  }

  /// A fixed time in tests, so rendered times never change.
  final DateTime Function() _clock;

  final Duration latency;
  final bool autoReply;

  static const _host = 'localhost';
  static const _fakeHash =
      'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

  @override
  final String me = 'sota@$_host';

  final _profiles = <String, UserProfile>{};
  final _conversations = <String, Conversation>{};
  final _messages = <String, List<ChatMessage>>{};
  final _readSeq = <String, int>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  var _seq = 0;
  var _replyIndex = 0;

  static const _replies = [
    'Got it, Sota!',
    'Hmm... let me think about that.',
    'Ehehe, okay~',
    'I will be there in ten minutes.',
    'Did you eat properly today?',
  ];

  void dispose() {
    unawaited(_changes.close());
    final dir = _packsDir;
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  Stream<List<ConversationSummary>> watchConversations() => _watch(_summaries);

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) =>
      _watch(() => List.unmodifiable(_messages[conversationId] ?? const []));

  @override
  Stream<List<UserProfile>> watchProfiles() =>
      _watch(() => List.unmodifiable(_profiles.values));

  @override
  Future<void> sendText(String conversationId, String text, {String? replyTo, LinkPreviewDraft? link}) async {
    // No files in the demo: the preview goes without its picture.
    await _sendOwn(
      Envelope.text(
        conv: conversationId,
        from: me,
        text: text,
        emojis: _emojisIn(conversationId, text),
        replyTo: _quote(replyTo),
        link: link?.toPreview(),
        now: _clock(),
      ),
    );

    final other = _conversations[conversationId]?.members
        .where((m) => m != me)
        .firstOrNull;
    if (autoReply && other != null) {
      setTyping(conversationId, {other});
      await Future<void>.delayed(latency * 3);
      _typing.remove(conversationId);
      _addIncoming(
        Envelope.text(
          conv: conversationId,
          from: other,
          text: _replies[_replyIndex++ % _replies.length],
        ),
      );
      _notify();
    }
  }

  @override
  Future<void> sendGif(String conversationId, GifRef gif, {String? replyTo}) =>
      _sendOwn(Envelope.gif(conv: conversationId, from: me, gif: gif, replyTo: _quote(replyTo), now: _clock()));

  @override
  Future<void> sendSticker(String conversationId, StickerRef sticker, {String? replyTo}) async => _sendOwn(
    Envelope.sticker(conv: conversationId, from: me, sticker: _toSend(sticker), replyTo: _quote(replyTo), now: _clock()),
  );

  ReplyRef? _quote(String? messageId) {
    final quoted = messageId == null ? null : _find(messageId);
    return quoted == null ? null : ReplyRef(id: quoted.id, from: quoted.senderId, text: quoted.envelope.preview);
  }

  /// Shows one of the user's messages as pending, then as sent.
  Future<void> _sendOwn(Envelope envelope) async {
    final conversationId = envelope.conv;
    _messages.putIfAbsent(conversationId, () => []).add(
      ChatMessage(envelope: envelope, state: DeliveryState.pending, replyTo: envelope.replyTo),
    );
    _notify();

    await Future<void>.delayed(latency);
    _replace(
      conversationId,
      envelope.id,
      (m) => m.copyWith(seq: ++_seq, state: DeliveryState.sent),
    );
    _readSeq[conversationId] = _seq;
    _notify();
  }

  final _savedGifs = <GifRef>[];

  @override
  Stream<List<GifRef>> watchSavedGifs() => _watch(() => List<GifRef>.unmodifiable(_savedGifs));

  @override
  Future<void> setGifSaved(GifRef gif, bool saved) async {
    _savedGifs.removeWhere((g) => g.key == gif.key);
    if (saved) _savedGifs.insert(0, gif);
    _notify();
  }

  final _savedStickers = <StickerRef>[];
  var _madeStickers = 0;

  @override
  Stream<List<StickerRef>> watchSavedStickers() => _watch(() => List<StickerRef>.unmodifiable(_savedStickers));

  @override
  Future<void> setStickerSaved(StickerRef sticker, bool saved) async {
    var keep = sticker;
    if (saved && sticker.isNamed) {
      try {
        keep = _toSend(sticker);
      } on StickerPackMissing {
        keep = sticker;
      }
    }
    _savedStickers.removeWhere((s) => s.key == keep.key);
    if (saved) _savedStickers.insert(0, keep);
    _notify();
  }

  // Sticker packs: kept in memory, their stickers' files in [_packsDir].

  final _packs = <StickerPack>[];

  /// Pack files by the hash of the file a sticker says its pack is (see
  /// [StickerSource.archive]), for adding a pack from a sticker.
  final packFiles = <String, String>{};

  /// Pictures by hash: those of packs' stickers sent, as [mediaFile] gives them.
  final _files = <String, File>{};

  Directory? _packsDir;

  @override
  Stream<List<StickerPack>> watchStickerPacks() => _watch(() => List<StickerPack>.unmodifiable(_packs));

  @override
  Future<StickerPack> addStickerPack(StickerSource source) async {
    final kept = _packs.where((p) => p.id == source.pack).firstOrNull;
    if (kept != null) return kept;
    final file = packFiles[source.archive?.hash];
    if (file == null) throw const PackageException('This sticker did not come with its pack');
    final pack = _install(file, replace: false);
    if (pack.id != source.pack) throw const PackageException('This is not the pack the sticker came from');
    return pack;
  }

  @override
  Future<StickerPack> importStickerPack(String path, {bool replace = false}) async => _install(path, replace: replace);

  @override
  Future<void> removeStickerPack(String id) async {
    _packs.removeWhere((p) => p.id == id);
    _notify();
  }

  /// Reads the pack file at [path] as the real repository does, and keeps it
  /// (without uploading anything).
  StickerPack _install(String path, {required bool replace}) {
    final bytes = File(path).readAsBytesSync();
    final file = readStickerPackNow(bytes);
    final at = _packs.indexWhere((p) => p.id == file.manifest.id);
    if (at >= 0 && !replace) throw StickerPackInstalled(_packs[at].title);
    final root = _packsDir ??= Directory.systemTemp.createTempSync('hanashi_packs_');
    final dir = Directory('${root.path}/${newUlid()}')..createSync();
    final archive = MediaRef(
      hash: 'sha256:${sha256.convert(bytes).hex()}',
      size: bytes.length,
      mime: 'application/zip',
      key: 'a2V5',
      host: _host,
    );
    packFiles[archive.hash] = path;
    final pack = StickerPack(
      id: file.manifest.id,
      title: file.manifest.title,
      author: file.manifest.author,
      archive: archive,
      stickers: [
        for (final (place, sticker) in file.stickers.indexed)
          PackSticker(
            id: sticker.item.id,
            path: (File('${dir.path}/$place.${sticker.extension}')..writeAsBytesSync(sticker.bytes)).path,
            mime: sticker.mime,
            width: sticker.width,
            height: sticker.height,
            emoji: sticker.item.emoji,
          ),
      ],
    );
    if (at >= 0) {
      _packs[at] = pack;
    } else {
      _packs.insert(0, pack);
    }
    _notify();
    return pack;
  }

  /// A pack's sticker as its picture, as the real repository sends it; the
  /// picture's hash made up of its pack and ID.
  StickerRef _toSend(StickerRef sticker) {
    final named = sticker.packSticker;
    if (named == null) return sticker;
    final pack = _packs.where((p) => p.id == named.pack).firstOrNull;
    final item = pack?[named.id];
    final path = item?.path;
    if (pack == null || item == null || path == null) {
      if (sticker.media != null) return sticker;
      throw const StickerPackMissing();
    }
    final picture =
        sticker.media ??
        MediaRef(
          hash: 'sha256:${sha256.convert(utf8.encode('${pack.id}:${named.id}')).hex()}',
          size: File(path).lengthSync(),
          mime: item.mime ?? 'image/webp',
          width: item.width,
          height: item.height,
          key: 'a2V5',
          host: _host,
        );
    _files[picture.hash] ??= File(path);
    return StickerRef.media(picture, source: pack.sourceFor(named.id));
  }

  /// Nothing is uploaded: the sticker is a file the demo pretends to have.
  @override
  Future<StickerRef> makeSticker(String path) async {
    final sticker = StickerRef.media(
      MediaRef(
        hash: 'sha256:${(++_madeStickers).toRadixString(16).padLeft(64, '0')}',
        size: 1,
        mime: 'image/png',
        width: 512,
        height: 512,
        key: 'a2V5',
      ),
    );
    await setStickerSaved(sticker, true);
    return sticker;
  }

  final _myEmojis = <String, MediaRef>{};
  final _groupEmojis = <String, Map<String, MediaRef>>{};
  var _madeEmojis = 0;

  @override
  Stream<Map<String, MediaRef>> watchEmojis({String? conversationId}) => _watch(
    () => Map<String, MediaRef>.unmodifiable(conversationId == null ? _myEmojis : _groupEmojis[conversationId] ?? {}),
  );

  /// Nothing is uploaded: a picture the demo pretends to have.
  @override
  Future<MediaRef> uploadEmoji(String path) async => MediaRef(
    hash: 'sha256:${(++_madeEmojis).toRadixString(16).padLeft(64, 'e')}',
    size: 1,
    mime: 'image/png',
    width: CustomEmoji.size,
    height: CustomEmoji.size,
    key: 'a2V5',
  );

  @override
  Future<void> changeEmojis(
    Map<String, MediaRef> Function(Map<String, MediaRef> current) change, {
    String? conversationId,
  }) async {
    if (conversationId == null) {
      final next = changedEmojis(_myEmojis, change);
      _myEmojis
        ..clear()
        ..addAll(next);
    } else {
      final before = _groupEmojis[conversationId] ?? const {};
      final after = _groupEmojis[conversationId] = changedEmojis(before, change);
      if (emojiChangeLine(before, after) case final line?) _groupLine(conversationId, me, line);
    }
    _notify();
  }

  Map<String, MediaRef> _emojisIn(String conv, String text, {Map<String, MediaRef> known = const {}}) =>
      emojisIn(text, known: known, group: _groupEmojis[conv] ?? const {}, mine: _myEmojis);

  /// No calls in the demo (tests that need them override these).
  @override
  Future<bool> callsAvailable() async => false;

  @override
  Future<bool> videoAvailable() async => false;

  @override
  Stream<Map<String, Call>> watchCalls() => _watch(() => const <String, Call>{});

  @override
  void noteCall(Call call) {}

  @override
  Future<CallJoin> joinCall(String conversationId, {bool video = false}) =>
      throw const ApiException(404, 'calls_off', 'This server has no calls');

  @override
  Future<void> declineCall(String callId) async {}

  @override
  Future<void> leaveCall(String callId) async {}

  @override
  Stream<CallKey?> watchCallKeys(String conversationId, String callId) => Stream.value(null);

  /// No GIF search in the demo.
  @override
  Future<String?> klipyApiKey() async => null;

  @override
  int? get maxUploadBytes => null;

  @override
  Future<void> markRead(String conversationId) async {
    final messages = _messages[conversationId];
    if (messages == null || messages.isEmpty) return;
    final last =
        messages
            .lastWhere((m) => m.seq != null, orElse: () => messages.last)
            .seq ??
        0;
    if ((_readSeq[conversationId] ?? 0) >= last) return;
    _readSeq[conversationId] = last;
    _notify();
  }

  @override
  Future<String> openDirectConversation(String userId) async {
    for (final c in _conversations.values) {
      if (!c.isGroup && c.members.contains(userId)) return c.id;
    }
    if (_contacts[userId] != ContactState.accepted) throw StateError('Add them as a contact first.');
    return _directChatWith(userId);
  }

  String _directChatWith(String userId) {
    final name = UserId.parse(userId).name;
    _profiles.putIfAbsent(
      userId,
      () => UserProfile(id: userId, displayName: _capitalize(name)),
    );
    final id = 'dm-$name';
    _conversations[id] ??= Conversation(id: id, members: [me, userId], isDirect: true);
    _messages[id] ??= [];
    _notify();
    return id;
  }

  final _contacts = <String, ContactState>{};

  @override
  Stream<Map<String, ContactState>> watchContacts() =>
      _watch(() => Map<String, ContactState>.unmodifiable(_contacts));

  /// Shows [userId] as standing thus with the user (demo and tests).
  void setContactState(String userId, ContactState state) {
    _profiles.putIfAbsent(
      userId,
      () => UserProfile(id: userId, displayName: _capitalize(UserId.parse(userId).name)),
    );
    if (state == ContactState.none) {
      _contacts.remove(userId);
    } else {
      _contacts[userId] = state;
    }
    _notify();
  }

  @override
  Future<ContactState> requestContact(String userId) async {
    final state = _contacts[userId] == ContactState.incoming ? ContactState.accepted : ContactState.outgoing;
    setContactState(userId, state);
    return state;
  }

  @override
  Future<void> acceptContact(String userId) async {
    setContactState(userId, ContactState.accepted);
    // Started right after, as the real app does.
    _directChatWith(userId);
  }

  @override
  Future<void> declineContact(String userId) async => setContactState(userId, ContactState.none);

  @override
  Future<void> cancelContactRequest(String userId) async => setContactState(userId, ContactState.none);

  @override
  Future<void> removeContact(String userId) async => setContactState(userId, ContactState.none);

  @override
  Future<void> blockContact(String userId) async => setContactState(userId, ContactState.blocked);

  @override
  Future<void> unblockContact(String userId) async => setContactState(userId, ContactState.none);

  @override
  Future<String> createGroup(String title, List<String> members) async {
    final id = 'group-${_conversations.length + 1}';
    _conversations[id] = Conversation(
      id: id,
      members: [me, ...members],
      isDirect: false,
      title: title,
    );
    _messages[id] = [];
    _groupLine(id, me, {'change': 'created', 'title': title});
    _notify();
    return id;
  }

  @override
  Future<void> addMember(String conversationId, String userId, {bool shareHistory = true}) async {
    final c = _conversations[conversationId]!;
    _conversations[conversationId] = Conversation(
      id: c.id,
      members: [...c.members, userId],
      isDirect: false,
      title: c.title,
    );
    _groupLine(conversationId, me, {'change': 'added', 'user': userId});
    if (shareHistory) _groupLine(conversationId, me, {'change': 'history', 'user': userId});
    _notify();
  }

  @override
  Future<void> renameGroup(String conversationId, String title) async {
    final c = _conversations[conversationId]!;
    _conversations[conversationId] = Conversation(
      id: c.id,
      members: c.members,
      isDirect: false,
      title: title,
    );
    _groupLine(conversationId, me, {'change': 'renamed', 'title': title});
    _notify();
  }

  @override
  Future<void> leaveGroup(String conversationId) async {
    _conversations.remove(conversationId);
    _messages.remove(conversationId);
    _notify();
  }

  final _typing = <String, Set<String>>{};

  /// Shows [users] as typing in [conversationId] (demo and tests).
  void setTyping(String conversationId, Set<String> users) {
    _typing[conversationId] = users;
    _notify();
  }

  @override
  void sendTyping(String conversationId) {}

  @override
  Stream<Set<String>> watchTyping(String conversationId) =>
      _watch(() => {...?_typing[conversationId]});

  void _groupLine(String conv, String by, Map<String, Object?> body) =>
      _messages[conv]!.add(
        ChatMessage(
          envelope: Envelope(
            id: newUlid(),
            conv: conv,
            from: by,
            ts: _clock().millisecondsSinceEpoch,
            type: Envelope.membershipType,
            body: body,
          ),
          seq: ++_seq,
        ),
      );

  @override
  Future<void> sendAttachment(
    String conversationId, {
    required String path,
    required String name,
    String? replyTo,
  }) async {}

  @override
  Future<void> react(String messageId, String emoji, {bool remove = false}) async {
    _update(messageId, (m) {
      final reactions = {for (final MapEntry(:key, :value) in m.reactions.entries) key: [...value]};
      final users = reactions.putIfAbsent(emoji, () => []);
      if (remove) {
        users.remove(me);
        if (users.isEmpty) reactions.remove(emoji);
      } else if (!users.contains(me)) {
        users.add(me);
      }
      return m.copyWith(reactions: reactions);
    });
  }

  @override
  Future<void> editMessage(String messageId, String text) async => _update(
    messageId,
    (m) => ChatMessage(
      envelope: m.envelope.withBody(
        editedBody(
          m.envelope.body,
          Envelope.edit(
            conv: m.envelope.conv,
            from: me,
            target: messageId,
            text: text,
            emojis: _emojisIn(m.envelope.conv, text, known: m.envelope.emojis),
          ),
        ),
      ),
      seq: m.seq,
      state: m.state,
      edited: true,
      reactions: m.reactions,
      replyTo: m.replyTo,
    ),
  );

  @override
  Future<void> deleteMessage(String messageId) async => _update(messageId, (m) {
    final e = m.envelope;
    return ChatMessage(
      envelope: Envelope(id: e.id, conv: e.conv, from: e.from, ts: e.ts, type: Envelope.deletedType, body: const {}),
      seq: m.seq,
      state: m.state,
    );
  });

  @override
  Future<void> setDisplayName(String name) async {
    final profile = _profiles[me];
    _profiles[me] = UserProfile(id: me, displayName: name, avatar: profile?.avatar, card: profile?.card ?? ProfileCard.empty);
    _notify();
  }

  @override
  Future<void> setAvatar(String? path) async {}

  @override
  Future<void> setProfileCard(ProfileCard card) async => setCard(me, card);

  /// Shows [card] as [userId]'s (demo and tests).
  void setCard(String userId, ProfileCard card) {
    final profile = _profiles[userId]!;
    _profiles[userId] = UserProfile(id: userId, displayName: profile.displayName, avatar: profile.avatar, card: card);
    _notify();
  }

  final _chatSettings = <String, ChatSettings>{};

  /// The settings as they are now (tests).
  Map<String, ChatSettings> get chatSettings => Map.unmodifiable(_chatSettings);

  @override
  Stream<Map<String, ChatSettings>> watchChatSettings() =>
      _watch(() => Map<String, ChatSettings>.unmodifiable(_chatSettings));

  @override
  Future<void> setChatSettings(String conversationId, ChatSettings settings) async {
    if (settings.isEmpty) {
      _chatSettings.remove(conversationId);
    } else {
      _chatSettings[conversationId] = settings;
    }
    _notify();
  }

  final _presence = <String, Presence>{};
  var _presenceMode = PresenceMode.auto;

  /// Shows [userId] as [presence] (demo and tests).
  void setPresence(String userId, Presence presence) {
    if (presence == Presence.offline) {
      _presence.remove(userId);
    } else {
      _presence[userId] = presence;
    }
    _notify();
  }

  @override
  Stream<Map<String, Presence>> watchPresence() => _watch(() => Map<String, Presence>.unmodifiable(_presence));

  @override
  Stream<PresenceMode> watchPresenceMode() => _watch(() => _presenceMode);

  @override
  Future<void> setPresenceMode(PresenceMode mode) async {
    _presenceMode = mode;
    setPresence(me, switch (mode) {
      PresenceMode.auto => Presence.online,
      PresenceMode.focus => Presence.focus,
      PresenceMode.invisible => Presence.offline,
    });
  }

  @override
  void setActive(bool active) {}

  final _groupPictures = <String, MediaRef>{};
  final _groupDescriptions = <String, String>{};

  @override
  Future<void> setGroupDescription(String conversationId, String? description) async {
    final text = description?.trim() ?? '';
    if (text.isEmpty) {
      _groupDescriptions.remove(conversationId);
    } else {
      _groupDescriptions[conversationId] = text;
    }
    _groupLine(conversationId, me, {'change': text.isEmpty ? 'descriptionRemoved' : 'description'});
    _notify();
  }

  @override
  Future<void> setGroupPicture(String conversationId, String? path) async {
    if (path == null) {
      _groupPictures.remove(conversationId);
    } else {
      _groupPictures[conversationId] = const MediaRef(hash: _fakeHash, size: 1, mime: 'image/jpeg');
    }
    _groupLine(conversationId, me, {'change': path == null ? 'pictureRemoved' : 'picture'});
    _notify();
  }

  ChatMessage? _find(String messageId) {
    for (final list in _messages.values) {
      for (final m in list) {
        if (m.id == messageId) return m;
      }
    }
    return null;
  }

  void _update(String messageId, ChatMessage Function(ChatMessage) update) {
    final message = _find(messageId);
    if (message == null) return;
    _replace(message.envelope.conv, messageId, update);
    _notify();
  }

  /// The demo's media: plain files of this device's.
  File? mediaFileOf(MediaRef media) => _files[media.hash];

  /// Read at once (the demo's files are small, and widget tests' clocks
  /// never let a read of the disk finish), and the same bytes each time, as
  /// pictures are cached by them.
  @override
  Future<Uint8List?> mediaBytes(MediaRef media, {void Function(double progress)? onProgress}) async {
    final file = mediaFileOf(media);
    return file == null ? null : _bytes[file.path] ??= file.readAsBytesSync();
  }

  final _bytes = <String, Uint8List>{};

  @override
  Future<Uint8List?> localMediaBytes(MediaRef media) => mediaBytes(media);

  @override
  Future<PlayableMedia?> playableMedia(MediaRef media, {void Function(double progress)? onProgress}) async {
    final file = mediaFileOf(media);
    return file == null ? null : (uri: file.path, close: null);
  }

  @override
  Future<bool> saveMedia(MediaRef media, String path, {void Function(double progress)? onProgress}) async {
    final file = mediaFileOf(media);
    if (file == null) return false;
    await file.copy(path);
    return true;
  }

  @override
  Stream<Set<String>> watchIdentityChanges() => Stream.value(const {});

  @override
  Future<void> acceptIdentityChange(String userId) async {}

  /// Contacts shown as verified (demo and tests).
  final verified = <String>{};

  @override
  Stream<Set<String>> watchVerifiedUsers() => _watch(() => {...verified});

  @override
  Future<void> loadOlderMessages(String conversationId) async {}

  @override
  Future<void> retry(String messageId) async {}

  @override
  Future<void> discard(String messageId) async {
    for (final list in _messages.values) {
      list.removeWhere(
        (m) => m.id == messageId && m.state != DeliveryState.sent,
      );
    }
    _notify();
  }

  @override
  Stream<ConnectionStatus> watchConnection() =>
      Stream.value(ConnectionStatus.online);

  @override
  Stream<String?> watchConnectionProblem() => Stream.value(null);

  @override
  Future<List<DeviceInfo>> devices() async => [
    const DeviceInfo(
      id: 'this',
      name: 'This device',
      platform: 'mock',
      createdAt: 0,
      lastSeenAt: 0,
      current: true,
    ),
  ];

  @override
  Future<void> revokeDevice(String deviceId) async {}

  List<ConversationSummary> _summaries() {
    final result = [
      for (final c in _conversations.values)
        ConversationSummary(
          conversation: c,
          title:
              c.title ??
              _profiles[_otherMember(c)]?.displayName ??
              _otherMember(c),
          avatarId: c.isGroup ? c.id : _otherMember(c),
          picture: _groupPictures[c.id],
          description: _groupDescriptions[c.id],
          lastMessage: _messages[c.id]?.lastOrNull,
          unreadCount:
              _messages[c.id]
                  ?.where(
                    (m) =>
                        m.senderId != me &&
                        (m.seq ?? 0) > (_readSeq[c.id] ?? 0),
                  )
                  .length ??
              0,
        ),
    ];
    // Most recent activity first; empty conversations sink to the bottom.
    result.sort(
      (a, b) => (b.lastMessage?.envelope.ts ?? 0).compareTo(
        a.lastMessage?.envelope.ts ?? 0,
      ),
    );
    return result;
  }

  String _otherMember(Conversation c) =>
      c.members.firstWhere((m) => m != me, orElse: () => me);

  Stream<T> _watch<T>(T Function() snapshot) => Stream.multi((controller) {
    controller.add(snapshot());
    final sub = _changes.stream.listen((_) => controller.add(snapshot()));
    controller.onCancel = sub.cancel;
  });

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _replace(
    String conversationId,
    String messageId,
    ChatMessage Function(ChatMessage) update,
  ) {
    final list = _messages[conversationId]!;
    final index = list.indexWhere((m) => m.id == messageId);
    if (index >= 0) list[index] = update(list[index]);
  }

  void _addIncoming(Envelope envelope) {
    _messages
        .putIfAbsent(envelope.conv, () => [])
        .add(ChatMessage(envelope: envelope, seq: ++_seq, replyTo: envelope.replyTo));
  }

  void _seed(DateTime now) {
    String user(String name, String displayName, Presence presence, [String? statusMessage, Birthday? birthday]) {
      final id = '$name@$_host';
      _profiles[id] = UserProfile(
        id: id,
        displayName: displayName,
        card: ProfileCard(statusMessage: statusMessage, birthday: birthday),
      );
      if (presence != Presence.offline) _presence[id] = presence;
      return id;
    }

    // Made-up birthdays, counted from the day, so that the demo always shows
    // today's and upcoming ones.
    final soon = now.add(const Duration(days: 5));
    user('sota', 'Sota', Presence.online);
    final kumiko = user('kumiko', 'Kumiko', Presence.online, 'Sweets after school?');
    final naoko = user('naoko', 'Naoko', Presence.offline, 'Lost in thought...', Birthday(now.month, now.day));
    final aiko = user('aiko', 'Aiko', Presence.idle, 'Practice at four!');
    final yoko = user('yoko', 'Yoko', Presence.focus, 'Snack duty today', Birthday(soon.month, soon.day));
    for (final contact in [kumiko, naoko, aiko, yoko]) {
      _contacts[contact] = ContactState.accepted;
    }

    var minutesAgo = 120;
    String text(String conv, String from, String text, {String? replyTo}) {
      final quoted = replyTo == null ? null : _find(replyTo);
      final envelope = Envelope.text(
        conv: conv,
        from: from,
        text: text,
        replyTo: quoted == null ? null : ReplyRef(id: quoted.id, from: quoted.senderId, text: quoted.envelope.preview),
        now: now.subtract(Duration(minutes: minutesAgo -= 2)),
      );
      _addIncoming(envelope);
      return envelope.id;
    }

    void react(String id, Map<String, List<String>> reactions) =>
        _replace(_find(id)!.envelope.conv, id, (m) => m.copyWith(reactions: reactions));
    void media(
      String conv,
      String from,
      MessageType type,
      MediaRef ref, {
      String? caption,
    }) => _addIncoming(
      Envelope.media(
        conv: conv,
        from: from,
        type: type,
        media: ref,
        caption: caption,
        now: now.subtract(Duration(minutes: minutesAgo -= 2)),
      ),
    );

    _conversations['club'] = Conversation(
      id: 'club',
      members: [me, kumiko, aiko, yoko],
      isDirect: false,
      title: 'Club Room',
    );
    final question = text('club', aiko, 'Is everyone coming to the meeting later?');
    final snacks = text('club', yoko, 'Yes! I will bring snacks.');
    react(snacks, {
      '👍': [aiko, kumiko],
      '❤️': [me],
    });
    text('club', me, 'I will be a little late, start without me.', replyTo: question);
    media(
      'club',
      kumiko,
      MessageType.video,
      const MediaRef(
        hash: _fakeHash,
        size: 4200000,
        mime: 'video/mp4',
        width: 1280,
        height: 720,
        durationMs: 42000,
      ),
      caption: 'Practice run from yesterday',
    );
    _readSeq['club'] = _seq;

    _conversations['dm-naoko'] = Conversation(
      id: 'dm-naoko',
      members: [me, naoko],
      isDirect: true,
    );
    text('dm-naoko', naoko, 'Sota, I finished the report.');
    media(
      'dm-naoko',
      naoko,
      MessageType.file,
      const MediaRef(
        hash: _fakeHash,
        size: 284331,
        mime: 'application/pdf',
        name: 'weekly-report.pdf',
      ),
    );
    text('dm-naoko', me, 'Thank you, I will read it tonight.');
    _readSeq['dm-naoko'] = _seq;
    media(
      'dm-naoko',
      naoko,
      MessageType.image,
      const MediaRef(
        hash: _fakeHash,
        size: 512000,
        mime: 'image/jpeg',
        width: 1080,
        height: 1440,
      ),
    );

    _conversations['dm-kumiko'] = Conversation(
      id: 'dm-kumiko',
      members: [me, kumiko],
      isDirect: true,
    );
    text('dm-kumiko', kumiko, 'Sota!');
    text('dm-kumiko', me, 'What is it?');
    _readSeq['dm-kumiko'] = _seq;
    text('dm-kumiko', kumiko, 'Are you free after school today?');
    text(
      'dm-kumiko',
      kumiko,
      'There is a new cafe near the station and I want to try their parfait.',
    );
    text('dm-kumiko', kumiko, 'It is my treat this time!');
  }
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
