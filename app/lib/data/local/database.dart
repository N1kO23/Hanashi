import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../custom_emojis.dart';
import '../models.dart';

part 'database.g.dart';

/// Small settings store: the signed-in account and the sync cursor.
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class Profiles extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();

  /// Their profile picture, a [MediaRef] as JSON; null for none.
  TextColumn get avatar => text().nullable()();

  /// The newest of their signed profile records this device took; older ones
  /// are refused, so the server cannot bring one back. 0: none yet.
  IntColumn get version => integer().withDefault(const Constant(0))();

  /// The newest version they announced; above [version] while it has yet to
  /// be fetched.
  IntColumn get wantedVersion => integer().withDefault(const Constant(0))();

  /// Base64 key that opened their record, or said to; null if unknown so far.
  TextColumn get profileKey => text().nullable()();

  /// Their [ProfileCard] file as their profile says (a [MediaRef] as JSON),
  /// null for none; and the card as last fetched (JSON), with the hash of the
  /// file it came from. A newer card shows once it is fetched.
  TextColumn get card => text().nullable()();
  TextColumn get cardJson => text().nullable()();
  TextColumn get cardFetched => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ConversationRow')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().nullable()();
  BoolColumn get isDirect => boolean()();

  /// The user's read marker; synced across their devices.
  IntColumn get readUpTo => integer().withDefault(const Constant(0))();

  /// Older messages exist on the server than the oldest one stored here.
  BoolColumn get moreHistory => boolean().withDefault(const Constant(false))();

  /// When the conversation appeared locally; orders chats without messages.
  IntColumn get addedAt => integer()();

  /// Set while sending is blocked for security reasons (an unverified device
  /// in the group, or a contact whose security key changed).
  TextColumn get securityIssue => text().nullable()();

  /// A group's picture ([MediaRef] as JSON; null: none). This, [title] and
  /// [description] are copies, for lists, of what its [GroupStates] row says.
  TextColumn get picture => text().nullable()();

  /// What a group is about (null: nothing said).
  TextColumn get description => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// What this device holds of a conversation's state (see `GroupState`). Kept
/// apart from [Conversations] since a device can join a group before it hears
/// of its conversation.
/// A commit or new conversation this device sent or is sending, until it knows
/// whether it counted, and what is left to do then. Written before it goes out,
/// so that an app closed meanwhile still finds out.
@DataClassName('UnsettledCommitRow')
class UnsettledCommits extends Table {
  TextColumn get convId => text()();

  /// The epoch the commit is for.
  IntColumn get epoch => integer()();

  /// It creates the conversation: if that exists at all, it counted.
  BoolColumn get creating => boolean().withDefault(const Constant(false))();

  /// The state it leaves the group with, as in [GroupStates]; null from a device
  /// that does not hold it.
  TextColumn get document => text().nullable()();
  TextColumn get roster => text().nullable()();

  /// It changes the document, which the user's own timeline should say.
  BoolColumn get changesDocument => boolean().withDefault(const Constant(false))();

  /// JSON list of the users it brings in.
  TextColumn get users => text().withDefault(const Constant('[]'))();

  /// For [creating]: the request as sent, JSON `{"members"?, "directWith"?,
  /// "group"}`, so that it can be sent again unchanged. The server answers a
  /// repeat with what the first one made.
  TextColumn get request => text().nullable()();

  @override
  Set<Column> get primaryKey => {convId};
}

@DataClassName('GroupStateRow')
class GroupStates extends Table {
  TextColumn get convId => text()();

  /// Base64 hash of the document the commits pin; null until one says.
  TextColumn get hash => text().nullable()();

  /// Base64 of the last document that matched a pinned hash. While [hash] says
  /// otherwise, this one keeps showing and the state counts as pending.
  TextColumn get document => text().nullable()();

  /// JSON `{userId: base64 profile key}`.
  TextColumn get roster => text().withDefault(const Constant('{}'))();

  /// Whether [hash] came from a commit this device applied, rather than from
  /// whoever sealed the state for it when it joined.
  BoolColumn get verified => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {convId};
}

/// How the user stands with others. [state] is the server's word, for showing;
/// [trusted] comes from the user's own encrypted contact list, and is what
/// decides whether anyone gets to add this device to a group.
@DataClassName('ContactRow')
class Contacts extends Table {
  TextColumn get userId => text()();
  TextColumn get state => textEnum<ContactState>()();
  IntColumn get since => integer().withDefault(const Constant(0))();
  BoolColumn get trusted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {userId};
}

/// Conversations this device stayed out of: nobody the user trusts brought
/// it there.
class RefusedConversations extends Table {
  TextColumn get convId => text()();

  @override
  Set<Column> get primaryKey => {convId};
}

class Members extends Table {
  TextColumn get convId => text()();
  TextColumn get userId => text()();

  @override
  Set<Column> get primaryKey => {convId, userId};
}

/// Messages, both confirmed (with a server `seq`) and pending in the outbox.
/// Reactions, edits and deletions are messages too, kept out of the timeline ([kind]) and applied when it is read.
@TableIndex(name: 'messages_conv_seq', columns: {#convId, #seq})
@TableIndex(name: 'messages_target', columns: {#target})
class Messages extends Table {
  /// Client-generated ULID.
  TextColumn get id => text()();
  TextColumn get convId => text()();
  IntColumn get seq => integer().nullable()();
  TextColumn get sender => text()();
  IntColumn get ts => integer()();
  TextColumn get envelope => text()();
  IntColumn get state => intEnum<DeliveryState>()();

  /// Local files to upload before a pending media message can be sent.
  TextColumn get attachmentPath => text().nullable()();
  TextColumn get thumbnailPath => text().nullable()();

  /// The encrypted envelope as received, kept while the message cannot be
  /// decrypted yet (and for the key backup).
  TextColumn get wire => text().nullable()();

  /// Base64 content key, once known.
  TextColumn get contentKey => text().nullable()();

  /// Whether [contentKey] is in the account's key backup on the server.
  BoolColumn get keyBackedUp => boolean().withDefault(const Constant(false))();

  /// A line about the group itself ("Kumiko added Naoko"), not a message:
  /// never unread, never notified.
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();

  /// For a hidden message, what it is (one of [Envelope.hiddenTypes]); null
  /// for messages shown in the timeline.
  TextColumn get kind => text().nullable()();

  /// For a reaction, edit or deletion: the message it is about.
  TextColumn get target => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Identity keys of contacts, pinned on first sight (trust on first use).
@DataClassName('PinnedIdentity')
class PinnedIdentities extends Table {
  TextColumn get userId => text()();
  TextColumn get identityKey => text()();

  /// A different key the server now shows, not yet accepted by the user.
  TextColumn get changedTo => text().nullable()();

  /// The key the user verified for this contact (emoji verification). They
  /// count as verified while it equals [identityKey].
  TextColumn get verifiedKey => text().nullable()();

  /// When the user's statement behind [verifiedKey] was made (see
  /// `Attestation`); older statements are ignored.
  IntColumn get verifiedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {userId};
}

/// Users this device has seen in a conversation's MLS group. Only they may
/// add devices by external commit; the server cannot forge this list.
class GroupUsers extends Table {
  TextColumn get convId => text()();
  TextColumn get userId => text()();

  @override
  Set<Column> get primaryKey => {convId, userId};
}

/// Leaves that joined a group in a way the client does not accept; they are
/// removed and block sending until then.
class SuspiciousLeaves extends Table {
  TextColumn get convId => text()();
  TextColumn get signatureKey => text()();

  @override
  Set<Column> get primaryKey => {convId, signatureKey};
}

/// When this device last updated its own keys in a conversation's group, and
/// how many messages it sent with them since.
class KeyRotations extends Table {
  TextColumn get convId => text()();
  IntColumn get rotatedAt => integer()();
  IntColumn get sentSince => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {convId};
}

/// Keys to a group's earlier messages that a member shared with the user on
/// adding them (see [Envelope.historyType]), by the share they came in. A
/// key opens only a message of the same chat from before its share, and only
/// if it fits; it then goes into the user's key backup like any other.
@TableIndex(name: 'shared_keys_message', columns: {#messageId})
class SharedKeys extends Table {
  /// The [Envelope.historyType] message they came in.
  TextColumn get shareId => text()();
  TextColumn get convId => text()();
  TextColumn get messageId => text()();

  /// Base64, as [Messages.contentKey].
  TextColumn get contentKey => text()();

  @override
  Set<Column> get primaryKey => {shareId, messageId};
}

/// A received message as stored locally: decrypted, or a placeholder of type
/// [Envelope.encryptedType] until it can be.
class ReceivedMessage {
  const ReceivedMessage({required this.envelope, this.wire, this.contentKey, this.own = false});

  final Envelope envelope;

  /// The encrypted envelope (JSON), kept while undecrypted.
  final String? wire;
  final String? contentKey;

  /// Sent by this device: the local copy stays, the message is only confirmed.
  final bool own;
}

/// Someone's reaction to one of the user's messages, for a notification.
class ReactionNotice {
  const ReactionNotice({
    required this.seq,
    required this.from,
    required this.emoji,
    required this.time,
    required this.target,
  });

  final int seq;
  final String from;
  final String emoji;
  final DateTime time;

  /// The message reacted to.
  final Envelope target;
}

/// A message waiting in the outbox.
class PendingMessage {
  const PendingMessage(this.envelope, {this.attachmentPath, this.thumbnailPath});

  final Envelope envelope;
  final String? attachmentPath;
  final String? thumbnailPath;
}

@DriftDatabase(
  tables: [
    KeyValues,
    Profiles,
    Conversations,
    Members,
    Messages,
    PinnedIdentities,
    GroupUsers,
    SuspiciousLeaves,
    KeyRotations,
    SharedKeys,
    GroupStates,
    Contacts,
    RefusedConversations,
    UnsettledCommits,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Called with the hash of each file whose message was deleted, so the
  /// decrypted copy can go too.
  void Function(String hash)? onMediaDeleted;

  /// The signed-in user, so that users of other servers are named by their
  /// whole ID until their own name is known ([UserId.fallbackName]).
  String? me;

  /// 0.9.0 started afresh with schema 14: later versions add their steps
  /// from there (`if (from < 15) ...` in [migration]).
  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration => MigrationStrategy();

  // Key-value settings

  Future<String?> getValue(String key) async =>
      (await (select(keyValues)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setValue(String key, String? value) async {
    if (value == null) {
      await (delete(keyValues)..where((t) => t.key.equals(key))).go();
    } else {
      await into(keyValues).insertOnConflictUpdate(KeyValue(key: key, value: value));
    }
  }

  /// The user's per-chat settings as last fetched from their account data
  /// (see [ChatSettings]), by conversation.
  Future<Map<String, ChatSettings>> chatSettings() async =>
      parseChatSettings(_decode(await getValue(_chatSettingsKey)));

  Stream<Map<String, ChatSettings>> watchChatSettings() =>
      (select(keyValues)..where((t) => t.key.equals(_chatSettingsKey))).watchSingleOrNull().map(
        (row) => parseChatSettings(_decode(row?.value)),
      );

  Future<void> setChatSettings(Map<String, ChatSettings> settings) => setValue(
    _chatSettingsKey,
    jsonEncode({for (final MapEntry(:key, :value) in settings.entries) key: value.toJson()}),
  );

  static const _chatSettingsKey = 'chats.settings';

  static Object? _decode(String? json) => json == null ? null : jsonDecode(json);

  /// `{convId: ChatSettings}`, leaving out what is malformed or empty.
  static Map<String, ChatSettings> parseChatSettings(Object? json) => {
    if (json is Map)
      for (final MapEntry(:key, :value) in json.entries)
        if (key is String && value is Map)
          if (ChatSettings.fromJson(value.cast<String, Object?>()) case final settings when !settings.isEmpty)
            key: settings,
  };

  /// How the user chose to appear, as last heard: notifications wait while
  /// in Focus, also in the push engine, which hears nothing live.
  Future<PresenceMode> presenceMode() async => PresenceMode.parse(await getValue('presence.mode'));

  Future<void> setPresenceMode(PresenceMode mode) => setValue('presence.mode', mode.name);

  /// Settings whose key starts with [prefix].
  Future<Map<String, String>> valuesWithPrefix(String prefix) async => {
    for (final row in await select(keyValues).get())
      if (row.key.startsWith(prefix)) row.key: row.value,
  };

  Future<int> cursor() async => int.tryParse(await getValue('cursor') ?? '') ?? 0;
  Future<bool> hasSynced() async => await getValue('cursor') != null;

  /// Removes all chat data, e.g. when signing out.
  Future<void> clearAll() => transaction(() async {
    for (final table in allTables) {
      await delete(table).go();
    }
  });

  // Applying server state

  /// Replaces local state with [snapshot]; [received] holds the local form
  /// of each snapshot message, by seq.
  Future<void> applySnapshot(SyncSnapshot snapshot, Map<int, ReceivedMessage> received) => transaction(() async {
    await delete(conversations).go();
    await delete(members).go();
    // Pending messages survive; everything else is replaced.
    await (delete(messages)..where((m) => m.state.equalsValue(DeliveryState.pending).not())).go();
    for (final c in snapshot.conversations) {
      await _upsertConversation(c.conversation, moreHistory: c.moreHistory);
      await (update(
        conversations,
      )..where((t) => t.id.equals(c.conversation.id))).write(ConversationsCompanion(readUpTo: Value(c.readUpTo)));
      for (final event in c.messages) {
        final message = received[event.seq];
        if (message != null) await _upsertMessage(event.seq, message);
      }
    }
    await setValue('cursor', '${snapshot.cursor}');
  });

  /// Applies events in order and advances the cursor to [cursor] (or to the
  /// last event's seq). Message events need their local form in [received].
  Future<void> applyEvents(
    List<SyncEvent> events, {
    required String me,
    int? cursor,
    Map<int, ReceivedMessage> received = const {},
  }) => transaction(() async {
    for (final event in events) {
      await _applyEvent(event, me, received[event.seq]);
    }
    final newCursor = cursor ?? (events.isEmpty ? null : events.last.seq);
    if (newCursor != null && newCursor > await this.cursor()) {
      await setValue('cursor', '$newCursor');
    }
  });

  Future<void> _applyEvent(SyncEvent event, String me, ReceivedMessage? received) async {
    switch (event.type) {
      case EventType.message:
        if (received != null) await _upsertMessage(event.seq, received);
      case EventType.conversationCreated:
        final info = event.conversation!;
        await _upsertConversation(info);
        if (!info.isDirect) {
          await _addGroupLine(event, by: event.data['by'], change: 'created', server: true);
        }
      case EventType.memberAdded:
        // Joining an existing group: older history may exist on the server.
        await _upsertConversation(event.conversation!, moreHistory: event.data['user'] == me ? true : null);
        await _addGroupLine(event, by: event.data['by'], change: 'added', user: event.data['user'], server: true);
      case EventType.memberRemoved:
        if (event.data['user'] == me) {
          await deleteConversation(event.conv);
        } else {
          await _upsertConversation(event.conversation!);
          await _addGroupLine(event, by: event.data['user'], change: 'left', server: true);
        }
      case EventType.readMarker:
        if (event.data['user'] == me) {
          await advanceReadMarker(event.conv, event.data['upTo'] as int);
        }
      default:
        break; // MLS commits are handled by the group manager; unknown types are skipped.
    }
  }

  Future<void> applyConversation(ConversationInfo info) => transaction(() => _upsertConversation(info));

  Future<void> _upsertConversation(ConversationInfo info, {bool? moreHistory}) async {
    final existing = await (select(conversations)..where((t) => t.id.equals(info.id))).getSingleOrNull();
    await into(conversations).insertOnConflictUpdate(
      ConversationsCompanion.insert(
        id: info.id,
        isDirect: info.isDirect,
        readUpTo: Value(existing?.readUpTo ?? 0),
        moreHistory: Value(moreHistory ?? existing?.moreHistory ?? false),
        addedAt: existing?.addedAt ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await (delete(members)..where((m) => m.convId.equals(info.id))).go();
    for (final m in info.members) {
      await into(members).insert(MembersCompanion.insert(convId: info.id, userId: m.id));
      await _ensureProfile(m.id);
    }
    // Its state may have come first (see [GroupStates]).
    await _copyStateToConversation(info.id);
  }

  /// A row for someone whose profile is not known yet, named after their ID.
  Future<void> _ensureProfile(String userId) => into(profiles).insert(
    ProfilesCompanion.insert(
      id: userId,
      displayName: UserId.fallbackName(userId, me: me),
    ),
    mode: InsertMode.insertOrIgnore,
  );

  /// Stores a change to a group as a line in its timeline (see
  /// [Envelope.membershipType]).
  Future<void> _addGroupLine(
    SyncEvent event, {
    required Object? by,
    required String change,
    Object? user,
    String? title,
    Map<String, Object?> details = const {},
    int idOffset = 0,
    bool server = false,
  }) async {
    if (by is! String) return;
    final envelope = Envelope(
      id: ulidFor(event.ts, event.seq + idOffset),
      conv: event.conv,
      from: by,
      ts: event.ts,
      type: Envelope.membershipType,
      body: {...details, 'change': change, 'user': ?user, 'title': ?title, if (server) 'server': true},
    );
    await into(messages).insertOnConflictUpdate(
      MessagesCompanion.insert(
        id: envelope.id,
        convId: envelope.conv,
        seq: Value(event.seq),
        sender: by,
        ts: envelope.ts,
        envelope: jsonEncode(envelope.toJson()),
        state: DeliveryState.sent,
        isSystem: const Value(true),
      ),
    );
    if (server) await _pairGroupLines(event.conv);
  }

  /// Takes out the server's word on a change of members wherever the member
  /// who made it said so themself ([Envelope.memberType]). Each of theirs goes
  /// with the closest line of the server's on the same change by the same
  /// person, with no other change about the same person in between: which
  /// comes first differs (someone leaving says so before the server can).
  Future<void> _pairGroupLines(String convId) async {
    final rows =
        await (select(messages)
              ..where((m) => m.convId.equals(convId) & m.isSystem.equals(true) & m.seq.isNotNull())
              ..orderBy([(m) => OrderingTerm.asc(m.seq)]))
            .get();
    final lines = [
      for (final row in rows)
        if (_envelope(row) case final envelope when _memberSubject(envelope) != null)
          (seq: row.seq!, id: row.id, envelope: envelope),
    ];
    final taken = <String>{};
    for (final said in lines.where((l) => l.envelope.type == Envelope.memberType)) {
      final change = said.envelope.body['change'];
      final subject = _memberSubject(said.envelope);
      String? best;
      var bestDistance = 0;
      for (final line in lines) {
        final envelope = line.envelope;
        if (envelope.type != Envelope.membershipType || envelope.body['server'] != true || taken.contains(line.id)) {
          continue;
        }
        if (envelope.body['change'] != change ||
            _memberSubject(envelope) != subject ||
            envelope.from != said.envelope.from) {
          continue;
        }
        final (low, high) = line.seq < said.seq ? (line.seq, said.seq) : (said.seq, line.seq);
        final apart = lines.any(
          (other) =>
              other.seq > low &&
              other.seq < high &&
              _memberSubject(other.envelope) == subject &&
              other.envelope.body['change'] != change,
        );
        if (apart) continue;
        final distance = high - low;
        if (best == null || distance < bestDistance) {
          (best, bestDistance) = (line.id, distance);
        }
      }
      if (best != null) taken.add(best);
    }
    if (taken.isNotEmpty) {
      await (delete(messages)..where((m) => m.id.isIn(taken))).go();
    }
  }

  /// Who a line about members is about ('' for the group itself), or null if
  /// it is about something else.
  static String? _memberSubject(Envelope line) => switch (line.body['change']) {
    'added' => line.body['user'] as String?,
    'left' => line.from,
    'created' => '',
    _ => null,
  };

  Future<void> _upsertMessage(int seq, ReceivedMessage message) async {
    final envelope = message.envelope;
    if (message.own) {
      // Our own echo: keep the plaintext we already have, just confirm it.
      final updated = await markSentCount(envelope.id, seq);
      if (updated > 0) return;
    }
    if (message.contentKey == null) {
      // A placeholder never replaces a message decrypted before (MLS keys
      // work only once, so a second attempt fails).
      final existing = await messageRow(envelope.id);
      if (existing != null && existing.contentKey != null) return;
    }
    await into(messages).insertOnConflictUpdate(
      MessagesCompanion.insert(
        id: envelope.id,
        convId: envelope.conv,
        seq: Value(seq),
        sender: envelope.from,
        ts: envelope.ts,
        envelope: jsonEncode(envelope.toJson()),
        state: DeliveryState.sent,
        wire: Value(message.wire),
        contentKey: Value(message.contentKey),
        kind: Value(_kind(envelope)),
        target: Value(envelope.target),
        isSystem: Value(envelope.type == Envelope.memberType),
      ),
    );
    await _applyEffects(envelope);
  }

  static String? _kind(Envelope envelope) => envelope.isHidden ? envelope.type : null;

  /// What a stored message does besides being there: share the history, or
  /// delete a message. And a message (or edit) that was deleted before it got here keeps no
  /// content, nor does a quote of one.
  Future<void> _applyEffects(Envelope envelope) async {
    if (envelope.type == Envelope.memberType) {
      await _pairGroupLines(envelope.conv);
    }
    if (envelope.sharedWith != null) {
      final seq = (await messageRow(envelope.id))?.seq;
      if (seq != null) await _addHistoryLine(envelope, seq);
    }
    final target = envelope.target;
    if (envelope.type == Envelope.deleteType) {
      await _removeContent(target!, envelope.from, envelope.conv);
    } else if (envelope.type == Envelope.editType || target == null) {
      final row = await messageRow(envelope.id);
      if (row == null) return;
      if (await _isDeleted(target ?? envelope.id, envelope.from)) {
        await _tombstone(row);
      } else if (envelope.replyTo case final quoted? when await _isDeleted(quoted.id, quoted.from)) {
        await _forgetQuote(row);
      }
    }
  }

  Future<bool> _isDeleted(String id, String author) async =>
      (await (select(
            messages,
          )..where((m) => m.target.equals(id) & m.kind.equals(Envelope.deleteType) & m.sender.equals(author))).get())
          .isNotEmpty;

  /// Deletes [target]'s content, that of its edits and the quotes of it in
  /// replies, if [author] wrote it.
  Future<void> _removeContent(String target, String author, String conv) async {
    final row = await messageRow(target);
    if (row != null && row.sender == author) await _tombstone(row);
    final edits = await (select(
      messages,
    )..where((m) => m.target.equals(target) & m.kind.equals(Envelope.editType) & m.sender.equals(author))).get();
    for (final edit in edits) {
      await _tombstone(edit);
    }
    // ULIDs hold no LIKE wildcards; the match is checked on the parsed reply.
    final mentions = await (select(messages)..where((m) => m.convId.equals(conv) & m.envelope.like('%$target%'))).get();
    for (final reply in mentions) {
      final quoted = _envelope(reply).replyTo;
      if (quoted != null && quoted.id == target && quoted.from == author) {
        await _forgetQuote(reply);
      }
    }
  }

  /// IDs of [author]'s edits of [target].
  Future<List<String>> editsOf(String target, String author) async => [
    for (final row in await (select(
      messages,
    )..where((m) => m.target.equals(target) & m.kind.equals(Envelope.editType) & m.sender.equals(author))).get())
      row.id,
  ];

  /// A reply keeps who it quoted but not what: that message was deleted.
  Future<void> _forgetQuote(Message row) async {
    final envelope = _envelope(row);
    final quoted = envelope.replyTo!;
    final gone = ReplyRef(id: quoted.id, from: quoted.from, text: _tombstoneOf(envelope).preview);
    if (quoted.text == gone.text) return;
    await (update(messages)..where((m) => m.id.equals(row.id))).write(
      MessagesCompanion(
        envelope: Value(jsonEncode(envelope.withBody({...envelope.body, 'replyTo': gone.toJson()}).toJson())),
      ),
    );
  }

  static Envelope _tombstoneOf(Envelope envelope) => Envelope(
    id: envelope.id,
    conv: envelope.conv,
    from: envelope.from,
    ts: envelope.ts,
    type: Envelope.deletedType,
    body: const {},
  );

  /// Replaces a message's content with [Envelope.deletedType], keeping its
  /// place in the timeline (or its kind, for a hidden one).
  Future<void> _tombstone(Message row) async {
    final envelope = _envelope(row);
    if (envelope.type == Envelope.deletedType) return;
    final media = envelope.messageType?.isMedia == true ? envelope.media : null;
    for (final file in [?media, ?media?.thumb, ?envelope.link?.thumb, ?envelope.link?.media]) {
      onMediaDeleted?.call(file.hash);
    }
    await (update(messages)..where((m) => m.id.equals(row.id))).write(
      MessagesCompanion(
        envelope: Value(jsonEncode(_tombstoneOf(envelope).toJson())),
        wire: const Value(null),
        contentKey: const Value(null),
        attachmentPath: const Value(null),
        thumbnailPath: const Value(null),
      ),
    );
  }

  Future<int> markSentCount(String id, int seq) async {
    final updated = await (update(
      messages,
    )..where((m) => m.id.equals(id))).write(MessagesCompanion(seq: Value(seq), state: const Value(DeliveryState.sent)));
    final row = updated > 0 ? await messageRow(id) : null;
    if (row != null && row.kind == Envelope.historyType) {
      await _addHistoryLine(_envelope(row), seq);
    }
    if (row != null && row.isSystem) await _pairGroupLines(row.convId);
    return updated;
  }

  Future<void> deleteConversation(String id) async {
    await (delete(sharedKeys)..where((k) => k.convId.equals(id))).go();
    await (delete(keyRotations)..where((r) => r.convId.equals(id))).go();
    await (delete(groupUsers)..where((g) => g.convId.equals(id))).go();
    await (delete(suspiciousLeaves)..where((g) => g.convId.equals(id))).go();
    await (delete(groupStates)..where((g) => g.convId.equals(id))).go();
    await (delete(messages)..where((m) => m.convId.equals(id))).go();
    await (delete(members)..where((m) => m.convId.equals(id))).go();
    await (delete(conversations)..where((c) => c.id.equals(id))).go();
  }

  Future<void> advanceReadMarker(String convId, int upTo) =>
      (update(conversations)..where((c) => c.id.equals(convId) & c.readUpTo.isSmallerThanValue(upTo))).write(
        ConversationsCompanion(readUpTo: Value(upTo)),
      );

  Future<void> addHistory(String convId, HistoryPage page, Map<int, ReceivedMessage> received) => transaction(() async {
    for (final event in page.messages) {
      final message = received[event.seq];
      // Never overwrite a message this device already holds in plaintext.
      if (message != null && (await messageRow(message.envelope.id)) == null) {
        await _upsertMessage(event.seq, message);
      }
    }
    await (update(
      conversations,
    )..where((c) => c.id.equals(convId))).write(ConversationsCompanion(moreHistory: Value(page.more)));
  });

  // Outbox

  Future<void> insertPending(PendingMessage message) => transaction(() async {
    final e = message.envelope;
    await into(messages).insert(
      MessagesCompanion.insert(
        id: e.id,
        convId: e.conv,
        sender: e.from,
        ts: e.ts,
        envelope: jsonEncode(e.toJson()),
        state: DeliveryState.pending,
        attachmentPath: Value(message.attachmentPath),
        thumbnailPath: Value(message.thumbnailPath),
        kind: Value(_kind(e)),
        target: Value(e.target),
        isSystem: Value(e.type == Envelope.memberType),
      ),
    );
    // A deletion shows at once, before it is sent.
    await _applyEffects(e);
  });

  /// New text for a message that has not been sent yet, with the custom
  /// [emojis] it uses.
  Future<void> setPendingText(String id, String text, {Map<String, MediaRef> emojis = const {}}) async {
    final row = await messageRow(id);
    if (row == null || row.seq != null) return;
    final envelope = _envelope(row);
    final body = {...envelope.body, 'text': text}..remove('emojis');
    if (CustomEmoji.toJson(emojis) case final json?) body['emojis'] = json;
    await (update(messages)..where((m) => m.id.equals(id))).write(
      MessagesCompanion(envelope: Value(jsonEncode(envelope.withBody(body).toJson()))),
    );
  }

  /// Pending messages, oldest first.
  Future<List<PendingMessage>> pendingMessages() async {
    final rows =
        await (select(messages)
              ..where((m) => m.state.equalsValue(DeliveryState.pending))
              ..orderBy([(m) => OrderingTerm.asc(m.ts)]))
            .get();
    return [
      for (final r in rows)
        PendingMessage(_envelope(r), attachmentPath: r.attachmentPath, thumbnailPath: r.thumbnailPath),
    ];
  }

  /// Confirms a message. If the sync stream already delivered it, this is a no-op.
  Future<void> markSent(String id, int seq) => transaction(() => markSentCount(id, seq));

  /// A pending message as it goes out, with what was prepared for it, so
  /// that sending it again sends the same.
  Future<void> setPendingEnvelope(Envelope envelope) =>
      (update(messages)..where((m) => m.id.equals(envelope.id) & m.seq.isNull())).write(
        MessagesCompanion(envelope: Value(jsonEncode(envelope.toJson()))),
      );

  Future<void> setState(String id, DeliveryState state) =>
      (update(messages)..where((m) => m.id.equals(id) & m.state.equalsValue(DeliveryState.sent).not())).write(
        MessagesCompanion(state: Value(state)),
      );

  Future<void> deleteMessage(String id) => (delete(messages)..where((m) => m.id.equals(id))).go();

  // End-to-end encryption state

  Future<Message?> messageRow(String id) => (select(messages)..where((m) => m.id.equals(id))).getSingleOrNull();

  /// Remembers the content key of a message this device sent.
  Future<void> setContentKey(String id, String contentKey) =>
      (update(messages)..where((m) => m.id.equals(id))).write(MessagesCompanion(contentKey: Value(contentKey)));

  /// Replaces a placeholder once the message could be decrypted. With
  /// [backedUp], its key came from the key backup.
  Future<void> setDecrypted(String id, Envelope envelope, String contentKey, {bool backedUp = false}) =>
      transaction(() async {
        await (update(messages)..where((m) => m.id.equals(id))).write(
          MessagesCompanion(
            envelope: Value(jsonEncode(envelope.toJson())),
            contentKey: Value(contentKey),
            wire: const Value(null),
            keyBackedUp: Value(backedUp),
            kind: Value(_kind(envelope)),
            target: Value(envelope.target),
            isSystem: Value(envelope.type == Envelope.memberType),
          ),
        );
        await _applyEffects(envelope);
      });

  /// Messages of [convId] (or of every conversation) still waiting to be
  /// decrypted, oldest first.
  Future<List<Message>> undecrypted([String? convId]) =>
      (select(messages)
            ..where((m) => m.wire.isNotNull() & (convId == null ? const Constant(true) : m.convId.equals(convId)))
            ..orderBy([(m) => OrderingTerm.asc(m.seq)]))
          .get();

  /// Confirmed messages whose content key is not in the key backup yet.
  Future<List<Message>> keysToBackUp({int limit = 200}) =>
      (select(messages)
            ..where((m) => m.contentKey.isNotNull() & m.seq.isNotNull() & m.keyBackedUp.equals(false))
            ..orderBy([(m) => OrderingTerm.asc(m.seq)])
            ..limit(limit))
          .get();

  Future<void> markKeysBackedUp(Iterable<String> ids) =>
      (update(messages)..where((m) => m.id.isIn(ids))).write(const MessagesCompanion(keyBackedUp: Value(true)));

  // Shared history (see [SharedKeys])

  /// The content keys this device holds for [convId]'s messages, oldest first.
  Future<List<({String id, int seq, String contentKey})>> contentKeysOf(String convId) async => [
    for (final row
        in await (select(messages)
              ..where((m) => m.convId.equals(convId) & m.contentKey.isNotNull() & m.seq.isNotNull())
              ..orderBy([(m) => OrderingTerm.asc(m.seq)]))
            .get())
      (id: row.id, seq: row.seq!, contentKey: row.contentKey!),
  ];

  /// Shares of a group's history with [me] (of [convId], or of every chat)
  /// whose keys this device has not taken yet.
  Future<List<Envelope>> untakenShares(String me, [String? convId]) async {
    final rows =
        await (select(messages)..where(
              (m) =>
                  m.kind.equals(Envelope.historyType) &
                  m.seq.isNotNull() &
                  (convId == null ? const Constant(true) : m.convId.equals(convId)) &
                  notExistsQuery(select(sharedKeys)..where((k) => k.shareId.equalsExp(m.id))),
            ))
            .get();
    return [
      for (final row in rows)
        if (_envelope(row) case final share when share.sharedWith == me) share,
    ];
  }

  /// Keeps the keys (message ID to base64 content key) that came in [share].
  Future<void> addSharedKeys(Envelope share, Map<String, String> keys) => batch(
    (b) => b.insertAll(sharedKeys, [
      for (final MapEntry(key: id, value: key) in keys.entries)
        SharedKeysCompanion.insert(shareId: share.id, convId: share.conv, messageId: id, contentKey: key),
    ], mode: InsertMode.insertOrIgnore),
  );

  /// Shared keys that may open [waiting] (by message ID): from shares of
  /// the same chat, placed after the message.
  Future<Map<String, List<String>>> sharedKeysFor(List<Message> waiting) async {
    final byId = {for (final row in waiting) row.id: row};
    final share = alias(messages, 'share');
    final query = select(sharedKeys).join([innerJoin(share, share.id.equalsExp(sharedKeys.shareId))])
      ..where(sharedKeys.messageId.isIn(byId.keys));
    final out = <String, List<String>>{};
    for (final result in await query.get()) {
      final key = result.readTable(sharedKeys);
      final row = byId[key.messageId]!;
      final (rowSeq, shareSeq) = (row.seq, result.readTable(share).seq);
      if (key.convId != row.convId || rowSeq == null || shareSeq == null || rowSeq >= shareSeq) {
        continue;
      }
      (out[key.messageId] ??= []).add(key.contentKey);
    }
    return out;
  }

  Future<List<String>> conversationIds() async => [for (final c in await select(conversations).get()) c.id];

  Future<List<String>> memberIds(String convId) async => [
    for (final m in await (select(members)..where((m) => m.convId.equals(convId))).get()) m.userId,
  ];

  Future<List<String>> conversationsWith(String userId) async => [
    for (final m in await (select(members)..where((m) => m.userId.equals(userId))).get()) m.convId,
  ];

  Future<void> setSecurityIssue(String convId, String? issue) => (update(
    conversations,
  )..where((c) => c.id.equals(convId))).write(ConversationsCompanion(securityIssue: Value(issue)));

  Future<PinnedIdentity?> pinnedIdentity(String userId) =>
      (select(pinnedIdentities)..where((p) => p.userId.equals(userId))).getSingleOrNull();

  /// Trusts [identityKey] for [userId]: on first sight, or a change the user
  /// accepted. Clears a pending change and any verification, which was for
  /// another key. (Explicit nulls: a data class would leave them as they are.)
  Future<void> pinIdentity(String userId, String identityKey) => into(pinnedIdentities).insertOnConflictUpdate(
    PinnedIdentitiesCompanion.insert(
      userId: userId,
      identityKey: identityKey,
      changedTo: const Value(null),
      verifiedKey: const Value(null),
    ),
  );

  /// Notes that the server shows [newKey] for [userId] instead of the
  /// pinned key. A no-op if that key is pinned by now (a lookup that started
  /// before an accept or a verification must not undo it).
  Future<void> markIdentityChanged(String userId, String newKey) =>
      (update(pinnedIdentities)..where((p) => p.userId.equals(userId) & p.identityKey.equals(newKey).not())).write(
        PinnedIdentitiesCompanion(changedTo: Value(newKey)),
      );

  /// Records (or clears, with null) the key the user verified for [userId],
  /// as stated [at].
  Future<void> setVerifiedKey(String userId, String? key, {required int at}) async {
    final updated = await (update(pinnedIdentities)..where((p) => p.userId.equals(userId))).write(
      PinnedIdentitiesCompanion(verifiedKey: Value(key), verifiedAt: Value(at)),
    );
    if (updated == 0 && key != null) {
      await into(pinnedIdentities)
          .insert(PinnedIdentity(userId: userId, identityKey: key, verifiedKey: key, verifiedAt: at));
    }
  }

  /// Users the user verified, while their key is still the verified one.
  Stream<Set<String>> watchVerifiedUsers() => select(pinnedIdentities).watch().map(
    (pins) => {
      for (final p in pins)
        if (p.verifiedKey != null && p.verifiedKey == p.identityKey && p.changedTo == null) p.userId,
    },
  );

  /// A line in every chat with [userId] saying their security key changed.
  Future<void> addKeyChangeNotice(String userId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final conv in await conversationsWith(userId)) {
      final envelope = Envelope(
        id: newUlid(),
        conv: conv,
        from: userId,
        ts: now,
        type: Envelope.membershipType,
        body: const {'change': 'keyChanged'},
      );
      await into(messages).insert(
        MessagesCompanion.insert(
          id: envelope.id,
          convId: conv,
          // After what is there now, like a message that just arrived.
          seq: Value(await newestSeq(conv) ?? 0),
          sender: userId,
          ts: now,
          envelope: jsonEncode(envelope.toJson()),
          state: DeliveryState.sent,
          isSystem: const Value(true),
        ),
      );
    }
  }

  Stream<List<PinnedIdentity>> watchChangedIdentities() =>
      (select(pinnedIdentities)..where((p) => p.changedTo.isNotNull())).watch();

  Future<Set<String>> groupUsersOf(String convId) async => {
    for (final g in await (select(groupUsers)..where((g) => g.convId.equals(convId))).get()) g.userId,
  };

  Future<void> addGroupUsers(String convId, Iterable<String> userIds) async {
    for (final userId in userIds) {
      await into(groupUsers).insertOnConflictUpdate(GroupUser(convId: convId, userId: userId));
    }
  }

  Future<Set<String>> suspiciousLeavesOf(String convId) async => {
    for (final l in await (select(suspiciousLeaves)..where((l) => l.convId.equals(convId))).get()) l.signatureKey,
  };

  Future<void> addSuspiciousLeaf(String convId, String signatureKey) =>
      into(suspiciousLeaves).insertOnConflictUpdate(SuspiciousLeave(convId: convId, signatureKey: signatureKey));

  Future<void> clearSuspiciousLeaves(String convId, Iterable<String> keepKeys) =>
      (delete(suspiciousLeaves)..where((l) => l.convId.equals(convId) & l.signatureKey.isNotIn(keepKeys))).go();

  Future<KeyRotation?> keyRotation(String convId) =>
      (select(keyRotations)..where((r) => r.convId.equals(convId))).getSingleOrNull();

  Future<void> noteKeyRotation(String convId, DateTime at) =>
      into(keyRotations)
          .insertOnConflictUpdate(KeyRotation(convId: convId, rotatedAt: at.millisecondsSinceEpoch, sentSince: 0));

  /// Counts a message sent with the current keys.
  Future<void> noteSentWithKeys(String convId, DateTime now) => customStatement(
    'INSERT INTO key_rotations (conv_id, rotated_at, sent_since) VALUES (?, ?, 1) '
    'ON CONFLICT (conv_id) DO UPDATE SET sent_since = sent_since + 1',
    [convId, now.millisecondsSinceEpoch],
  );

  // Queries for the UI

  static Envelope _envelope(Message row) =>
      Envelope.fromJson((jsonDecode(row.envelope) as Map).cast<String, Object?>());

  /// Confirmed messages in server order, then pending ones in send order.
  static final _inOrder = <OrderClauseGenerator<$MessagesTable>>[
    (m) => OrderingTerm.asc(m.seq.isNull()),
    (m) => OrderingTerm.asc(m.seq),
    (m) => OrderingTerm.asc(m.ts),
  ];

  /// The reactions in [hidden] (in order) that stand: per message, each
  /// emoji and who reacted with it, in the order they came. [addedBy] names
  /// the message that added each one (`'<target>|<user>|<emoji>'`).
  static ({Map<String, Map<String, Set<String>>> byTarget, Map<String, String> addedBy}) _reactions(
    Iterable<Message> hidden,
  ) {
    final byTarget = <String, Map<String, Set<String>>>{};
    final addedBy = <String, String>{};
    for (final row in hidden) {
      if (row.kind != Envelope.reactionType || row.state == DeliveryState.failed) {
        continue;
      }
      final e = _envelope(row);
      final target = e.target;
      if (target == null) continue;
      final byEmoji = byTarget.putIfAbsent(target, () => {});
      final emoji = e.emoji;
      if (emoji == null) continue;
      if (e.removesReaction) {
        byEmoji[emoji]?.remove(e.from);
        addedBy.remove('$target|${e.from}|$emoji');
      } else if (byEmoji.putIfAbsent(emoji, () => {}).add(e.from)) {
        addedBy['$target|${e.from}|$emoji'] = row.id;
      }
      byEmoji.removeWhere((_, users) => users.isEmpty);
    }
    return (byTarget: byTarget, addedBy: addedBy);
  }

  /// [rows] (timeline messages) as they read now: with the latest edit by
  /// their sender and the reactions from [hidden] (in order), and with
  /// quotes of messages among [rows] showing their current text.
  static List<ChatMessage> _resolve(List<Message> rows, Iterable<Message> hidden) {
    final edits = <String, Envelope>{}; // '<target>|<editor>' -> latest edit
    for (final row in hidden) {
      if (row.kind != Envelope.editType || row.state == DeliveryState.failed) {
        continue;
      }
      final e = _envelope(row);
      if (e.target case final target?) edits['$target|${e.from}'] = e;
    }
    final reactions = _reactions(hidden).byTarget;
    final current = <String, (Envelope, bool)>{};
    for (final row in rows) {
      final envelope = _envelope(row);
      final edit = envelope.messageType == null ? null : edits['${row.id}|${row.sender}'];
      current[row.id] = edit == null ? (envelope, false) : (envelope.withBody(editedBody(envelope.body, edit)), true);
    }
    final out = <ChatMessage>[];
    for (final row in rows) {
      final (envelope, edited) = current[row.id]!;
      final quoted = envelope.replyTo;
      final original = quoted == null ? null : current[quoted.id]?.$1;
      final emoji = envelope.type == Envelope.deletedType
          ? const <String, List<String>>{}
          : {
              for (final MapEntry(:key, :value) in (reactions[row.id] ?? const {}).entries) key: [...value],
            };
      out.add(
        ChatMessage(
          envelope: envelope,
          seq: row.seq,
          state: row.state,
          edited: edited,
          reactions: emoji,
          replyTo: original == null
              ? quoted
              : ReplyRef(id: original.id, from: original.from, text: quotePreview(original)),
        ),
      );
    }
    return out;
  }

  /// How a reply quotes [original]: its preview, shortened.
  static String quotePreview(Envelope original) {
    final text = original.preview.replaceAll('\n', ' ');
    return text.length <= ReplyRef.maxText ? text : '${text.substring(0, ReplyRef.maxText - 3)}...';
  }

  Stream<List<ChatMessage>> watchMessages(String convId) =>
      (select(messages)
            ..where((m) => m.convId.equals(convId))
            ..orderBy(_inOrder))
          .watch()
          .map(
            (rows) => _resolve(
              [
                for (final r in rows)
                  if (r.kind == null) r,
              ],
              [
                for (final r in rows)
                  if (r.kind != null) r,
              ],
            ),
          );

  /// The reactions and edits about [ids], in order.
  Future<List<Message>> _hiddenAbout(Iterable<String> ids) =>
      (select(messages)
            ..where((m) => m.target.isIn(ids))
            ..orderBy(_inOrder))
          .get();

  /// One message as it reads now (without resolving its quote).
  Future<ChatMessage?> resolvedMessage(String id) async {
    final row = await messageRow(id);
    if (row == null || row.kind != null) return null;
    return _resolve([row], await _hiddenAbout([id])).single;
  }

  /// [userId]'s profile as this device last took it, if any.
  Future<Profile?> profileRow(String userId) => (select(profiles)..where((p) => p.id.equals(userId))).getSingleOrNull();

  static MediaRef? _avatar(Profile row) =>
      row.avatar == null ? null : MediaRef.fromJson((jsonDecode(row.avatar!) as Map).cast<String, Object?>());

  /// Takes [document], from the record [version] of [userId] that [profileKey]
  /// opened, unless a newer one was taken; whether it did.
  Future<bool> noteProfile(String userId, ProfileDocument document, {required int version, String? profileKey}) =>
      transaction(() async {
        await _ensureProfile(userId);
        final row = await profileRow(userId);
        if (row!.version > version) return false;
        await (update(profiles)..where((p) => p.id.equals(userId))).write(
          ProfilesCompanion(
            displayName: Value(document.displayName ?? UserId.fallbackName(userId, me: me)),
            avatar: Value(document.avatar == null ? null : jsonEncode(document.avatar!.toJson())),
            version: Value(version),
            profileKey: profileKey == null ? const Value.absent() : Value(profileKey),
            card: Value(document.card == null ? null : jsonEncode(document.card!.toJson())),
            // A new card shows once fetched; until then the last one does.
            cardJson: document.card == null ? const Value(null) : const Value.absent(),
            cardFetched: document.card == null ? const Value(null) : const Value.absent(),
          ),
        );
        return true;
      });

  /// A key said to open [userId]'s record, while they have none to try it on.
  Future<void> noteProfileKey(String userId, String profileKey) => transaction(() async {
    await _ensureProfile(userId);
    await (update(profiles)..where((p) => p.id.equals(userId))).write(ProfilesCompanion(profileKey: Value(profileKey)));
  });

  /// [userId] announced [version] of their profile.
  Future<void> noteWantedProfile(String userId, int version) => transaction(() async {
    await _ensureProfile(userId);
    await (update(profiles)..where((p) => p.id.equals(userId) & p.wantedVersion.isSmallerThanValue(version))).write(
      ProfilesCompanion(wantedVersion: Value(version)),
    );
  });

  /// Those whose announced profile has yet to be fetched.
  Future<List<String>> wantedProfiles() async => [
    for (final p in await (select(profiles)..where((p) => p.wantedVersion.isBiggerThan(p.version))).get()) p.id,
  ];

  /// Profile cards announced but not fetched yet, by user.
  Future<List<({String userId, MediaRef card})>> cardsToFetch() async => [
    for (final row in await (select(profiles)..where((p) => p.card.isNotNull())).get())
      if (_mediaRef(row.card) case final card? when card.hash != row.cardFetched) (userId: row.id, card: card),
  ];

  /// [userId]'s card from the file [hash] ([cardJson] null: unreadable),
  /// unless a newer one was announced meanwhile.
  Future<void> setFetchedCard(String userId, String hash, String? cardJson) => transaction(() async {
    final row = await (select(profiles)..where((p) => p.id.equals(userId))).getSingleOrNull();
    if (row == null || _mediaRef(row.card)?.hash != hash) return;
    await (update(
      profiles,
    )..where((p) => p.id.equals(userId))).write(ProfilesCompanion(cardJson: Value(cardJson), cardFetched: Value(hash)));
  });

  // Group state

  Future<GroupStateRow?> groupStateRow(String convId) =>
      (select(groupStates)..where((g) => g.convId.equals(convId))).getSingleOrNull();

  /// A group's document as this device holds it; null before it is here.
  Future<GroupDocument?> groupDocument(String convId) async => _parseDocument((await groupStateRow(convId))?.document);

  /// [groupDocument], and again whenever it changes.
  Stream<GroupDocument?> watchGroupDocument(String convId) =>
      (select(groupStates)..where((g) => g.convId.equals(convId)))
          .watchSingleOrNull()
          .map((row) => row?.document)
          .distinct()
          .map(_parseDocument);

  /// Checked before it was stored: null only for none.
  static GroupDocument? _parseDocument(String? encoded) {
    if (encoded == null) return null;
    try {
      final json = jsonDecode(utf8.decode(base64.decode(encoded)));
      return json is Map ? GroupDocument.fromJson(json.cast<String, Object?>()) : null;
    } on FormatException {
      return null;
    }
  }

  /// Writes what is given. A document also shows at once in its conversation.
  Future<void> setGroupState(
    String convId, {
    String? hash,
    String? document,
    Map<String, String>? roster,
    bool? verified,
  }) => transaction(() async {
    await into(groupStates).insert(GroupStatesCompanion.insert(convId: convId), mode: InsertMode.insertOrIgnore);
    await (update(groupStates)..where((g) => g.convId.equals(convId))).write(
      GroupStatesCompanion(
        hash: hash == null ? const Value.absent() : Value(hash),
        document: document == null ? const Value.absent() : Value(document),
        roster: roster == null ? const Value.absent() : Value(jsonEncode(roster)),
        verified: verified == null ? const Value.absent() : Value(verified),
      ),
    );
    if (document != null) await _copyStateToConversation(convId);
  });

  Future<void> noteUnsettledCommit(
    String convId, {
    required int epoch,
    bool creating = false,
    String? document,
    Map<String, String>? roster,
    bool changesDocument = false,
    Iterable<String> users = const [],
    Map<String, Object?>? request,
  }) => into(unsettledCommits).insertOnConflictUpdate(
    UnsettledCommitsCompanion.insert(
      convId: convId,
      epoch: epoch,
      creating: Value(creating),
      document: Value(document),
      roster: Value(roster == null ? null : jsonEncode(roster)),
      changesDocument: Value(changesDocument),
      users: Value(jsonEncode(users.toList())),
      request: Value(request == null ? null : jsonEncode(request)),
    ),
  );

  Future<UnsettledCommitRow?> unsettledCommit(String convId) =>
      (select(unsettledCommits)..where((c) => c.convId.equals(convId))).getSingleOrNull();

  Future<List<String>> unsettledConversations() => (selectOnly(
    unsettledCommits,
  )..addColumns([unsettledCommits.convId])).map((row) => row.read(unsettledCommits.convId)!).get();

  Future<void> forgetUnsettledCommit(String convId) =>
      (delete(unsettledCommits)..where((c) => c.convId.equals(convId))).go();

  /// This device can no longer tell if what it holds of a group's state is
  /// current. It stays on show, and whatever comes next is taken over it.
  Future<void> unpinGroupState(String convId) => (update(groupStates)..where((g) => g.convId.equals(convId))).write(
    const GroupStatesCompanion(hash: Value(null), verified: Value(false)),
  );

  Future<void> clearGroupState(String convId) => (delete(groupStates)..where((g) => g.convId.equals(convId))).go();

  Future<void> _copyStateToConversation(String convId) async {
    final document = await groupDocument(convId);
    if (document == null) return;
    await (update(conversations)..where((c) => c.id.equals(convId))).write(
      ConversationsCompanion(
        title: Value(document.title),
        description: Value(document.description),
        picture: Value(document.picture == null ? null : jsonEncode(document.picture!.toJson())),
      ),
    );
  }

  /// A line for what a commit changed about a group: its name, its
  /// description, its picture, its emojis.
  Future<void> addGroupChangeLines(
    String convId, {
    required int seq,
    required int ts,
    required String by,
    required GroupDocument? before,
    required GroupDocument after,
  }) async {
    Future<void> line(String change, {String? title, Map<String, Object?> details = const {}}) => _addGroupLine(
      SyncEvent(seq: seq, type: EventType.mlsCommit, conv: convId, ts: ts, data: const {}),
      by: by,
      change: change,
      title: title,
      details: details,
      // One commit can change all of them.
      idOffset: switch (change) {
        'renamed' => 0,
        'picture' || 'pictureRemoved' => 1,
        'description' || 'descriptionRemoved' => 2,
        _ => 3,
      },
    );
    // Its first document comes with the group, whose line says so already.
    if (before == null) return;
    if (before.title != after.title && after.title != null) {
      await line('renamed', title: after.title);
    }
    final (was, now) = (before.picture?.hash, after.picture?.hash);
    if (was != now) await line(now == null ? 'pictureRemoved' : 'picture');
    if (before.description != after.description) {
      await line(after.description == null ? 'descriptionRemoved' : 'description');
    }
    if (emojiChangeLine(before.emojis, after.emojis) case final details?) {
      await line(details['change']! as String, details: details);
    }
  }

  // Contacts

  Stream<Map<String, ContactRow>> watchContacts() =>
      select(contacts).watch().map((rows) => {for (final c in rows) c.userId: c});

  Future<List<ContactRow>> allContacts() => select(contacts).get();

  Future<ContactRow?> contact(String userId) =>
      (select(contacts)..where((c) => c.userId.equals(userId))).getSingleOrNull();

  /// Takes the server's list; who is trusted stays as it is.
  Future<void> setContactStates(Iterable<ContactInfo> list) => transaction(() async {
    final listed = {for (final c in list) c.user};
    await (update(contacts)..where((c) => c.userId.isNotIn(listed))).write(
      const ContactsCompanion(state: Value(ContactState.none), since: Value(0)),
    );
    for (final c in list) {
      await _setContactState(c.user, c.state, since: c.since);
    }
  });

  Future<void> setContactState(String userId, ContactState state, {int since = 0}) =>
      transaction(() => _setContactState(userId, state, since: since));

  Future<void> _setContactState(String userId, ContactState state, {required int since}) async {
    await _ensureProfile(userId);
    await into(contacts).insert(
      ContactsCompanion.insert(userId: userId, state: state, since: Value(since)),
      onConflict: DoUpdate((_) => ContactsCompanion(state: Value(state), since: Value(since))),
    );
  }

  /// Takes who is on the user's own encrypted contact list.
  Future<void> setTrustedContacts(Set<String> trusted) => transaction(() async {
    await (update(
      contacts,
    )..where((c) => c.userId.isNotIn(trusted))).write(const ContactsCompanion(trusted: Value(false)));
    for (final userId in trusted) {
      await _ensureProfile(userId);
      await into(contacts).insert(
        ContactsCompanion.insert(userId: userId, state: ContactState.none, trusted: const Value(true)),
        onConflict: DoUpdate((_) => const ContactsCompanion(trusted: Value(true))),
      );
    }
  });

  Future<Set<String>> trustedContacts() async => {
    for (final c in await (select(contacts)..where((c) => c.trusted.equals(true))).get()) c.userId,
  };

  // Conversations this device stayed out of

  Future<void> refuseConversation(String convId) =>
      into(refusedConversations)
          .insert(RefusedConversationsCompanion.insert(convId: convId), mode: InsertMode.insertOrIgnore);

  Future<bool> isRefused(String convId) async =>
      await (select(refusedConversations)..where((r) => r.convId.equals(convId))).getSingleOrNull() != null;

  Future<void> unrefuseConversation(String convId) =>
      (delete(refusedConversations)..where((r) => r.convId.equals(convId))).go();

  /// They are looked at again, and refused again if nothing changed for them.
  Future<void> clearRefusedConversations() => delete(refusedConversations).go();

  /// "Kumiko shared the chat history with Naoko", where [share] is in the
  /// timeline: once it is sent, as one that turns out empty never is.
  Future<void> _addHistoryLine(Envelope share, int seq) async {
    final line = Envelope(
      id: ulidFor(share.ts, seq),
      conv: share.conv,
      from: share.from,
      ts: share.ts,
      type: Envelope.membershipType,
      body: {'change': 'history', 'user': share.sharedWith},
    );
    await into(messages).insertOnConflictUpdate(
      MessagesCompanion.insert(
        id: line.id,
        convId: line.conv,
        seq: Value(seq),
        sender: line.from,
        ts: line.ts,
        envelope: jsonEncode(line.toJson()),
        state: DeliveryState.sent,
        isSystem: const Value(true),
      ),
    );
  }

  static MediaRef? _mediaRef(String? json) =>
      json == null ? null : MediaRef.fromJson((jsonDecode(json) as Map).cast<String, Object?>());

  /// A [MediaRef] from its JSON in a column.
  static MediaRef? mediaRefOf(String? json) => _mediaRef(json);

  Future<int?> oldestSeq(String convId) async {
    final min = messages.seq.min();
    final row =
        await (selectOnly(messages)
              ..addColumns([min])
              ..where(messages.convId.equals(convId)))
            .getSingle();
    return row.read(min);
  }

  Future<int?> newestSeq(String convId) async {
    final max = messages.seq.max();
    final row =
        await (selectOnly(messages)
              ..addColumns([max])
              ..where(messages.convId.equals(convId)))
            .getSingle();
    return row.read(max);
  }

  Future<ConversationRow?> conversation(String id) =>
      (select(conversations)..where((c) => c.id.equals(id))).getSingleOrNull();

  /// Messages from others that are newer than the read marker and than
  /// [after], grouped by conversation, oldest first.
  Future<Map<String, List<ChatMessage>>> unreadIncoming(String me, {int after = 0}) async {
    final query = select(messages).join([innerJoin(conversations, conversations.id.equalsExp(messages.convId))])
      ..where(
        messages.sender.equals(me).not() &
            messages.isSystem.equals(false) &
            messages.kind.isNull() &
            messages.seq.isBiggerThan(conversations.readUpTo) &
            messages.seq.isBiggerThanValue(after),
      )
      ..orderBy([OrderingTerm.asc(messages.seq)]);
    final rows = [for (final row in await query.get()) row.readTable(messages)];
    final out = <String, List<ChatMessage>>{};
    for (final message in _resolve(rows, await _hiddenAbout([for (final r in rows) r.id]))) {
      // Deleted before it was read: nothing to notify about.
      if (!message.isDeleted) {
        out.putIfAbsent(message.envelope.conv, () => []).add(message);
      }
    }
    return out;
  }

  /// Reactions from others to [me]'s messages that are newer than the read
  /// marker and than [after] and still stand (not taken back since, the
  /// message not deleted), by conversation, oldest first.
  Future<Map<String, List<ReactionNotice>>> unreadReactions(String me, {int after = 0}) async {
    final target = alias(messages, 'reacted_to');
    final query =
        select(messages).join([
            innerJoin(conversations, conversations.id.equalsExp(messages.convId)),
            innerJoin(target, target.id.equalsExp(messages.target)),
          ])
          ..where(
            messages.kind.equals(Envelope.reactionType) &
                messages.sender.equals(me).not() &
                target.sender.equals(me) &
                messages.seq.isBiggerThan(conversations.readUpTo) &
                messages.seq.isBiggerThanValue(after),
          )
          ..orderBy([OrderingTerm.asc(messages.seq)]);
    final rows = await query.get();
    if (rows.isEmpty) return const {};
    final hidden = await _hiddenAbout({for (final r in rows) r.readTable(messages).target!});
    final standing = _reactions(hidden).addedBy;
    // As the messages read now (edited, or deleted).
    final reactedTo = {
      for (final m in _resolve({for (final r in rows) r.readTable(target)}.toList(), hidden)) m.id: m.envelope,
    };
    final out = <String, List<ReactionNotice>>{};
    for (final row in rows) {
      final reaction = row.readTable(messages);
      final reacted = reactedTo[reaction.target]!;
      final emoji = _envelope(reaction).emoji;
      // Taken back since.
      if (emoji == null || standing['${reaction.target}|${reaction.sender}|$emoji'] != reaction.id) {
        continue;
      }
      if (reacted.type == Envelope.deletedType) continue;
      out
          .putIfAbsent(reaction.convId, () => [])
          .add(
            ReactionNotice(
              seq: reaction.seq!,
              from: reaction.sender,
              emoji: emoji,
              time: DateTime.fromMillisecondsSinceEpoch(reaction.ts),
              target: reacted,
            ),
          );
    }
    return out;
  }

  Future<List<Profile>> allProfiles() => select(profiles).get();

  Future<Map<String, String>> profileNames() async => {
    for (final p in await select(profiles).get()) p.id: p.displayName,
  };

  Stream<List<UserProfile>> watchProfiles() => select(profiles).watch().map(
    (rows) => [
      for (final p in rows) UserProfile(id: p.id, displayName: p.displayName, avatar: _avatar(p), card: _card(p)),
    ],
  );

  static ProfileCard _card(Profile row) {
    final json = row.cardJson == null ? null : jsonDecode(row.cardJson!);
    return json is Map ? ProfileCard.fromJson(json.cast<String, Object?>()) : ProfileCard.empty;
  }

  /// The direct conversation with [userId], if there is one locally.
  Future<String?> directConversationWith(String userId) async {
    final query = select(conversations).join([innerJoin(members, members.convId.equalsExp(conversations.id))])
      ..where(conversations.isDirect.equals(true) & members.userId.equals(userId));
    return (await query.get()).firstOrNull?.readTable(conversations).id;
  }

  Stream<List<ConversationSummary>> watchSummaries(String me) {
    final query = customSelect(
      '''
      SELECT c.id, c.title, c.is_direct, c.added_at, c.security_issue, c.picture, c.description,
        (SELECT COUNT(*) FROM messages m
           WHERE m.conv_id = c.id AND m.sender != ?1 AND m.seq > c.read_up_to AND m.is_system = 0
             AND m.kind IS NULL) AS unread,
        (SELECT m.id FROM messages m WHERE m.conv_id = c.id AND m.kind IS NULL
           ORDER BY m.seq IS NULL DESC, m.seq DESC, m.ts DESC LIMIT 1) AS last_id
      FROM conversations c
      WHERE c.id NOT IN (SELECT conv_id FROM refused_conversations)
      ''',
      variables: [Variable.withString(me)],
      readsFrom: {conversations, messages, members, profiles, refusedConversations},
    );
    return query.watch().asyncMap((rows) async {
      final memberRows = await select(members).get();
      final names = {for (final p in await select(profiles).get()) p.id: p.displayName};
      final lastIds = [for (final r in rows) ?r.readNullable<String>('last_id')];
      final lastRows = await (select(messages)..where((m) => m.id.isIn(lastIds))).get();
      final lastMessages = {for (final m in _resolve(lastRows, await _hiddenAbout(lastIds))) m.id: m};

      final summaries = <(int, ConversationSummary)>[];
      for (final r in rows) {
        final id = r.read<String>('id');
        final memberIds = [
          for (final m in memberRows)
            if (m.convId == id) m.userId,
        ];
        final conversation = Conversation(
          id: id,
          members: memberIds,
          isDirect: r.read<bool>('is_direct'),
          title: r.readNullable<String>('title'),
        );
        final other = memberIds.firstWhere((m) => m != me, orElse: () => me);
        final last = lastMessages[r.readNullable<String>('last_id')];
        summaries.add((
          // Pending messages are the newest activity of all.
          last == null ? r.read<int>('added_at') : (last.seq == null ? 1 << 62 : last.envelope.ts),
          ConversationSummary(
            conversation: conversation,
            // A group whose state has yet to reach this device has no name yet.
            title: conversation.title ?? (conversation.isDirect ? names[other] ?? other : 'Group chat'),
            avatarId: conversation.isDirect ? other : id,
            picture: _mediaRef(r.readNullable<String>('picture')),
            description: r.readNullable<String>('description'),
            lastMessage: last,
            unreadCount: r.read<int>('unread'),
            securityIssue: r.readNullable<String>('security_issue'),
          ),
        ));
      }
      summaries.sort((a, b) => b.$1.compareTo(a.$1));
      return [for (final s in summaries) s.$2];
    });
  }
}
