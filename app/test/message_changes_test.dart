import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

const _me = 'sota@test.local';
const _kumiko = 'kumiko@test.local';
const _naoko = 'naoko@test.local';
const _hash = 'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
const _thumb = 'sha256:0000000000000000000000000000000000000000000000000000000000000001';

/// Reactions, edits, deletions, replies and profiles as the local database
/// stores and applies them, in whatever order they arrive.
void main() {
  late AppDatabase db;
  var seq = 0;
  var ts = 1000;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seq = 0;
    await db.applyConversation(
      const ConversationInfo(
        id: 'c',
        isDirect: false,
        members: [
          MemberInfo(id: _me),
          MemberInfo(id: _kumiko),
          MemberInfo(id: _naoko),
        ],
      ),
    );
  });
  tearDown(() => db.close());

  DateTime next() => DateTime.fromMillisecondsSinceEpoch(ts += 1000);

  /// Delivers [envelope] as the server would, with the next seq.
  Future<void> receive(Envelope envelope, {int? at}) {
    final s = at ?? ++seq;
    return db.applyEvents(
      [SyncEvent(seq: s, type: EventType.message, conv: 'c', ts: envelope.ts, data: const {})],
      me: _me,
      received: {s: ReceivedMessage(envelope: envelope, contentKey: 'a2V5')},
    );
  }

  Envelope text(String from, String text, {ReplyRef? replyTo}) =>
      Envelope.text(conv: 'c', from: from, text: text, replyTo: replyTo, now: next());

  Future<List<ChatMessage>> timeline() => db.watchMessages('c').first;
  Future<ChatMessage> message(String id) async => (await timeline()).singleWhere((m) => m.id == id);

  test("a group's state shows in the chat list, and what a commit changed in lines there", () async {
    const first = MediaRef(hash: _hash, size: 1, mime: 'image/jpeg', key: 'a2V5');
    String encoded(GroupDocument d) => base64.encode(utf8.encode(jsonEncode(d.toJson())));
    Future<ConversationSummary> summary() async => (await db.watchSummaries(_me).first).single;
    List<String> lines(List<ChatMessage> l) => [
      for (final m in l)
        if (m.envelope.type == Envelope.membershipType) '${m.envelope.from} ${m.envelope.body['change']}',
    ];

    // Before its state came: a group, nameless, not named after anyone in it.
    expect(((await summary()).title, (await summary()).avatarId), ('Group chat', 'c'));
    const club = GroupDocument(salt: 'a', title: 'Club');
    await db.setGroupState('c', hash: 'h1', document: encoded(club), verified: true);
    expect((await summary()).title, 'Club');

    const pictured = GroupDocument(salt: 'b', title: 'Club', picture: first);
    await db.setGroupState('c', hash: 'h2', document: encoded(pictured));
    await db.addGroupChangeLines('c', seq: 1, ts: 1000, by: _kumiko, before: club, after: pictured);
    expect((await summary()).picture!.hash, _hash);
    const renamed = GroupDocument(salt: 'c', title: 'Club Room');
    await db.addGroupChangeLines('c', seq: 2, ts: 2000, by: _naoko, before: pictured, after: renamed);
    expect(lines(await timeline()), ['$_kumiko picture', '$_naoko renamed', '$_naoko pictureRemoved']);
    // An emoji added in the same commit as a new name: a line each.
    const emoji = GroupDocument(salt: 'd', title: 'The Club', emojis: {'cat': first});
    await db.addGroupChangeLines('c', seq: 4, ts: 4000, by: _kumiko, before: renamed, after: emoji);
    final added = (await timeline()).last.envelope;
    expect(lines(await timeline()).skip(3), ['$_kumiko renamed', '$_kumiko emojiAdded']);
    expect((added.body['name'], (added.body['picture']! as Map)['hash']), ('cat', _hash));
    await db.setGroupState('c', hash: 'h3', document: encoded(emoji));
    expect((await db.groupDocument('c'))!.emojis.keys, ['cat']);
    await db.setGroupState('c', hash: 'h2', document: encoded(pictured));
    // The lines are not news, and the first document says nothing new.
    expect((await summary()).unreadCount, 0);
    await db.addGroupChangeLines('c', seq: 3, ts: 3000, by: _naoko, before: null, after: club);
    expect(await timeline(), hasLength(5));
    // Applying a commit twice makes no second line.
    await db.addGroupChangeLines('c', seq: 1, ts: 1000, by: _kumiko, before: club, after: pictured);
    expect(await timeline(), hasLength(5));

    // A conversation row that comes later takes the state that came first.
    await db.setGroupState('later', hash: 'h', document: encoded(club));
    await db.applyConversation(
      const ConversationInfo(
        id: 'later',
        isDirect: false,
        members: [MemberInfo(id: _me)],
      ),
    );
    expect((await db.conversation('later'))!.title, 'Club');
    // And a direct chat is named after the other one, whatever it holds.
    await db.applyConversation(
      const ConversationInfo(
        id: 'dm',
        isDirect: true,
        members: [
          MemberInfo(id: _me),
          MemberInfo(id: _naoko),
        ],
      ),
    );
    final direct = (await db.watchSummaries(_me).first).singleWhere((s) => s.id == 'dm');
    expect((direct.title, direct.avatarId), ('naoko', _naoko));
  });

  test("an edit's custom emojis replace the message's, sent or not", () async {
    const cat = MediaRef(hash: _hash, size: 1, mime: 'image/png', key: 'a2V5');
    const dog = MediaRef(hash: _thumb, size: 1, mime: 'image/png', key: 'a2V5');
    final original = Envelope.text(conv: 'c', from: _kumiko, text: ':cat:', emojis: {'cat': cat}, now: next());
    await receive(original);
    // An edit carries those of its text: without any, the message has none.
    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: original.id, text: 'cat !', now: next()));
    expect((await message(original.id)).envelope.body.containsKey('emojis'), isFalse);
    await receive(
      Envelope.edit(
        conv: 'c',
        from: _kumiko,
        target: original.id,
        text: ':cat: :dog:',
        emojis: {'cat': dog, 'dog': dog},
        now: next(),
      ),
    );
    final edited = (await message(original.id)).envelope;
    expect((edited.text, edited.emojis['cat']?.hash, edited.emojis['dog']?.hash), (':cat: :dog:', _thumb, _thumb));

    // Not sent yet: it goes out with the new text's, and none of the old.
    final unsent = Envelope.text(conv: 'c', from: _me, text: ':cat:', emojis: {'cat': cat}, now: next());
    await db.insertPending(PendingMessage(unsent));
    await db.setPendingText(unsent.id, ':dog:', emojis: {'dog': dog});
    expect((await message(unsent.id)).envelope.emojis.keys, ['dog']);
    await db.setPendingText(unsent.id, 'Nothing');
    expect((await message(unsent.id)).envelope.body.containsKey('emojis'), isFalse);
  });

  test('an edit by the sender changes the text; one by anyone else does not', () async {
    final original = text(_kumiko, 'See you at 5');
    await receive(original);
    await receive(Envelope.edit(conv: 'c', from: _naoko, target: original.id, text: 'forged', now: next()));
    expect((await message(original.id)).edited, isFalse);

    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: original.id, text: 'See you at 6', now: next()));
    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: original.id, text: 'See you at 7', now: next()));
    final edited = await message(original.id);
    expect((edited.envelope.text, edited.edited), ('See you at 7', true));
    // Edits are not messages of their own: the timeline, unread count and
    // chat list show the message itself.
    expect([for (final m in await timeline()) m.id], [original.id]);
    final summary = (await db.watchSummaries(_me).first).single;
    expect((summary.unreadCount, summary.lastMessage!.envelope.text), (1, 'See you at 7'));
  });

  test('an edit that arrives before its message still applies', () async {
    final original = text(_kumiko, 'v1');
    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: original.id, text: 'v2', now: next()), at: 5);
    await receive(original, at: 3); // Older history, fetched later.
    expect((await message(original.id)).envelope.text, 'v2');
  });

  test('reactions: several per person, each taken back on its own', () async {
    final original = text(_kumiko, 'Parfait?');
    await receive(original);
    Future<void> react(String from, String emoji, {bool remove = false}) => receive(
      Envelope.reaction(conv: 'c', from: from, target: original.id, emoji: emoji, remove: remove, now: next()),
    );
    await react(_naoko, '👍');
    await react(_me, '❤️');
    await react(_kumiko, '👍');
    await react(_naoko, '😂');
    await react(_naoko, '👍'); // Again: no change.
    expect((await message(original.id)).reactions, {
      '👍': [_naoko, _kumiko],
      '❤️': [_me],
      '😂': [_naoko],
    });
    await react(_naoko, '👍', remove: true);
    await react(_me, '❤️', remove: true);
    expect((await message(original.id)).reactions, {
      '👍': [_kumiko],
      '😂': [_naoko],
    });
  });

  test('pending reactions and edits show at once; failed ones do not', () async {
    final mine = text(_me, 'helo');
    await receive(mine);
    final edit = Envelope.edit(conv: 'c', from: _me, target: mine.id, text: 'hello', now: next());
    await db.insertPending(PendingMessage(edit));
    await db.insertPending(
      PendingMessage(Envelope.reaction(conv: 'c', from: _me, target: mine.id, emoji: '👍', now: next())),
    );
    var shown = await message(mine.id);
    expect(shown.envelope.text, 'hello');
    expect(shown.reactions, {
      '👍': [_me],
    });

    await db.setState(edit.id, DeliveryState.failed);
    shown = await message(mine.id);
    expect((shown.envelope.text, shown.edited), ('helo', false));
  });

  test('a deletion removes the content (and files) of the sender\'s own message only', () async {
    final deletedFiles = <String>[];
    db.onMediaDeleted = deletedFiles.add;
    final photo = Envelope.media(
      conv: 'c',
      from: _kumiko,
      type: MessageType.image,
      media: const MediaRef(
        hash: _hash,
        size: 10,
        mime: 'image/jpeg',
        thumb: MediaRef(hash: _thumb, size: 1, mime: 'image/jpeg'),
      ),
      caption: 'secret',
      now: next(),
    );
    await receive(photo);
    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: photo.id, text: 'also secret', now: next()));
    await receive(Envelope.delete(conv: 'c', from: _naoko, target: photo.id, now: next()));
    expect((await message(photo.id)).isDeleted, isFalse);

    await receive(Envelope.reaction(conv: 'c', from: _me, target: photo.id, emoji: '😮', now: next()));
    await receive(Envelope.delete(conv: 'c', from: _kumiko, target: photo.id, now: next()));
    final deleted = await message(photo.id);
    expect((deleted.isDeleted, deleted.envelope.preview), (true, 'This message was deleted'));
    expect(deleted.reactions, isEmpty);
    expect(deletedFiles, [_hash, _thumb]);
    // Nothing of it is left in the database, edits included.
    final rows = await db.select(db.messages).get();
    expect(rows.where((r) => r.envelope.contains('secret') || r.contentKey != null && r.id == photo.id), isEmpty);
  });

  test('a message deleted before it arrives here keeps no content', () async {
    final original = text(_kumiko, 'oops');
    final edit = Envelope.edit(conv: 'c', from: _kumiko, target: original.id, text: 'oops 2', now: next());
    await receive(Envelope.delete(conv: 'c', from: _kumiko, target: original.id, now: next()), at: 9);
    await receive(original, at: 2);
    await receive(edit, at: 4);
    expect((await message(original.id)).isDeleted, isTrue);
    expect((await db.messageRow(edit.id))!.envelope, isNot(contains('oops')));
  });

  test('a reply quotes the original as it reads now, or what was quoted', () async {
    final original = text(_kumiko, 'Meeting at 5?');
    final elsewhere = ReplyRef(id: newUlid(), from: _naoko, text: 'From before you joined');
    await receive(original);
    final reply = text(
      _me,
      'Yes',
      replyTo: ReplyRef(id: original.id, from: _kumiko, text: 'Meeting at 5?'),
    );
    final older = text(_me, 'Agreed', replyTo: elsewhere);
    await receive(reply);
    await receive(older);
    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: original.id, text: 'Meeting at 6?', now: next()));
    expect((await message(reply.id)).replyTo!.text, 'Meeting at 6?');
    expect((await message(older.id)).replyTo!.text, 'From before you joined');

    await receive(Envelope.delete(conv: 'c', from: _kumiko, target: original.id, now: next()));
    expect((await message(reply.id)).replyTo!.text, 'This message was deleted');
    // The reply does not keep the quoted text either, even one that arrives later.
    final late = text(
      _naoko,
      'Too late',
      replyTo: ReplyRef(id: original.id, from: _kumiko, text: 'Meeting at 5?'),
    );
    await receive(late, at: 1);
    expect(await db.messageRow(late.id).then((r) => r!.envelope), isNot(contains('Meeting')));
    expect(await db.messageRow(reply.id).then((r) => r!.envelope), isNot(contains('Meeting')));
  });

  test('a profile: only a newer version counts, picture and name together', () async {
    const first = MediaRef(hash: _hash, size: 10, mime: 'image/jpeg', key: 'a2V5');
    const second = MediaRef(hash: _thumb, size: 10, mime: 'image/jpeg', key: 'a2V5');
    Future<UserProfile> kumiko() async => (await db.watchProfiles().first).singleWhere((p) => p.id == _kumiko);
    expect((await kumiko()).displayName, 'kumiko'); // Named after their ID until then.

    expect(
      await db.noteProfile(_kumiko, const ProfileDocument(displayName: 'Kumiko', avatar: first), version: 10),
      isTrue,
    );
    expect(((await kumiko()).displayName, (await kumiko()).avatar!.hash), ('Kumiko', _hash));
    expect(
      await db.noteProfile(_kumiko, const ProfileDocument(displayName: 'Kumiko', avatar: second), version: 20),
      isTrue,
    );
    expect((await kumiko()).avatar!.hash, _thumb);
    // An older one changes nothing.
    expect(await db.noteProfile(_kumiko, const ProfileDocument(displayName: 'Old'), version: 15), isFalse);
    expect(((await kumiko()).displayName, (await kumiko()).avatar!.hash), ('Kumiko', _thumb));
    await db.noteProfile(_kumiko, const ProfileDocument(displayName: 'Kumiko'), version: 30);
    expect((await kumiko()).avatar, isNull);
    // One announced stays wanted until it is taken.
    await db.noteWantedProfile(_kumiko, 40);
    expect(await db.wantedProfiles(), [_kumiko]);
    await db.noteProfile(_kumiko, const ProfileDocument(), version: 40);
    expect(await db.wantedProfiles(), isEmpty);
    expect((await kumiko()).displayName, 'kumiko');
  });

  test('notifications skip hidden and deleted messages and show edits', () async {
    final kept = text(_kumiko, 'tpyo');
    final gone = text(_kumiko, 'nevermind');
    await receive(kept);
    await receive(gone);
    await receive(Envelope.edit(conv: 'c', from: _kumiko, target: kept.id, text: 'typo', now: next()));
    await receive(Envelope.delete(conv: 'c', from: _kumiko, target: gone.id, now: next()));
    await receive(Envelope.reaction(conv: 'c', from: _kumiko, target: kept.id, emoji: '👍', now: next()));
    final unread = await db.unreadIncoming(_me);
    expect([for (final m in unread['c']!) m.envelope.text], ['typo']);
  });

  test(
    'a shared history: a line once sent, its keys taken once, each opening only an earlier message of its chat',
    () async {
      const keys = MediaRef(hash: _hash, size: 100, mime: 'application/json', key: 'a2V5');
      List<String> lines(List<ChatMessage> l) => [
        for (final m in l)
          if (m.envelope.type == Envelope.membershipType)
            '${m.envelope.from} ${m.envelope.body['change']} ${m.envelope.body['user']}',
      ];

      /// A message Sota cannot read (yet), in [conv] at [at].
      Future<String> waiting(String conv, int at) async {
        final envelope = Envelope(
          id: newUlid(now: next()),
          conv: conv,
          from: _kumiko,
          ts: ts,
          type: Envelope.encryptedType,
          body: const {},
        );
        await db.applyEvents(
          [SyncEvent(seq: at, type: EventType.message, conv: conv, ts: ts, data: const {})],
          me: _me,
          received: {at: ReceivedMessage(envelope: envelope, wire: '{}')},
        );
        return envelope.id;
      }

      final before = await waiting('c', 1);
      final elsewhere = await waiting('d', 2);
      final share = Envelope.history(conv: 'c', from: _kumiko, user: _me, keys: keys, now: next());
      await receive(share, at: 3);
      final after = await waiting('c', 4);
      await receive(Envelope.history(conv: 'c', from: _kumiko, user: _naoko, keys: keys, now: next()), at: 5);
      expect(lines(await timeline()), ['$_kumiko history $_me', '$_kumiko history $_naoko']);

      // Only Sota's share is for this device, and only until its keys are taken.
      expect([for (final s in await db.untakenShares(_me)) s.id], [share.id]);
      await db.addSharedKeys(share, {before: 'a2V5', elsewhere: 'a2V5', after: 'a2V5'});
      expect(await db.untakenShares(_me), isEmpty);
      // Its keys open what came before it in its chat, nothing else.
      expect(await db.sharedKeysFor(await db.undecrypted()), {
        before: ['a2V5'],
      });

      // Sota's own share shows once it is sent; one never sent leaves no trace.
      final sent = Envelope.history(conv: 'c', from: _me, user: _naoko, now: next());
      final dropped = Envelope.history(conv: 'c', from: _me, user: _naoko, now: next());
      await db.insertPending(PendingMessage(sent));
      await db.insertPending(PendingMessage(dropped));
      expect(lines(await timeline()), hasLength(2));
      await db.markSent(sent.id, 6);
      await db.deleteMessage(dropped.id);
      expect(lines(await timeline()), ['$_kumiko history $_me', '$_kumiko history $_naoko', '$_me history $_naoko']);
      // The shares and their lines are not news; the two waiting messages are.
      expect((await db.watchSummaries(_me).first).single.unreadCount, 2);
    },
  );

  group('lines about members', () {
    /// What the server's event for a change of members brings.
    Future<void> event(String type, Map<String, Object?> data) => db.applyEvents([
      SyncEvent(
        seq: ++seq,
        type: type,
        conv: 'c',
        ts: ts += 1000,
        data: {
          'conversation': {
            'id': 'c',
            'isDirect': false,
            'members': [
              for (final m in [_me, _kumiko, _naoko]) {'id': m},
            ],
          },
          ...data,
        },
      ),
    ], me: _me);

    Envelope said(String from, String change, {String? user}) =>
        Envelope.member(conv: 'c', from: from, change: change, user: user, now: next());

    Future<List<String>> lines() async => [
      for (final m in await timeline())
        if (m.envelope.isGroupLine)
          '${m.envelope.from} ${m.envelope.body['change']}'
              '${m.envelope.body['user'] == null ? '' : ' ${m.envelope.body['user']}'}'
              '${m.envelope.type == Envelope.memberType ? '' : ' (server)'}',
    ];

    test("a member's own word replaces the server's, whichever comes first", () async {
      await event(EventType.conversationCreated, {'by': _me});
      await receive(said(_me, 'created'));
      await event(EventType.memberAdded, {'user': _naoko, 'by': _kumiko});
      await receive(said(_kumiko, 'added', user: _naoko));
      // Someone leaving says so before the server does.
      await receive(said(_naoko, 'left'));
      await event(EventType.memberRemoved, {'user': _naoko});
      expect(await lines(), ['$_me created', '$_kumiko added $_naoko', '$_naoko left']);
    });

    test('each word goes with the change it is about, and nobody speaks for someone else', () async {
      await event(EventType.memberAdded, {'user': _naoko, 'by': _kumiko});
      await event(EventType.memberRemoved, {'user': _naoko});
      await event(EventType.memberAdded, {'user': _naoko, 'by': _kumiko});
      // Kumiko says she added Naoko: the second time, not the first, with Naoko
      // leaving in between. And Naoko cannot say that someone else added her.
      await receive(said(_kumiko, 'added', user: _naoko));
      await receive(said(_naoko, 'added', user: _naoko));
      expect(await lines(), [
        '$_kumiko added $_naoko (server)',
        '$_naoko left (server)',
        '$_kumiko added $_naoko',
        '$_naoko added $_naoko',
      ]);
    });

    test('lines about members are never unread', () async {
      await receive(said(_kumiko, 'added', user: _naoko));
      await receive(text(_kumiko, 'hi'));
      expect((await db.watchSummaries(_me).first).single.unreadCount, 1);
    });
  });
}
