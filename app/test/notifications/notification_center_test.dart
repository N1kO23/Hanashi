import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/notifications/notification_center.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../support/fake_display.dart';

const me = 'sota@test.local';
const kumiko = 'kumiko@test.local';
const naoko = 'naoko@test.local';

void main() {
  late AppDatabase db;
  late FakeDisplay display;
  var foreground = false;
  late NotificationCenter center;
  var seq = 0;
  var now = DateTime(2026, 10, 28, 12);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    display = FakeDisplay();
    foreground = false;
    seq = 0;
    now = DateTime(2026, 10, 28, 12);
    center = NotificationCenter(
      db: db,
      me: me,
      notifier: display,
      appInForeground: () => foreground,
      clock: () => now,
    );
    MemberInfo member(String id) => MemberInfo(id: id);
    await db.noteProfile(me, const ProfileDocument(displayName: 'Sota'), version: 1);
    await db.noteProfile(kumiko, const ProfileDocument(displayName: 'KUMIKO'), version: 1);
    await db.noteProfile(naoko, const ProfileDocument(displayName: 'NAOKO'), version: 1);
    await db.applyConversation(
      ConversationInfo(
        id: 'dm',
        isDirect: true,
        members: [member(me), member(kumiko)],
      ),
    );
    await db.applyConversation(
      ConversationInfo(
        id: 'club',
        isDirect: false,
        members: [member(me), member(kumiko), member(naoko)],
      ),
    );
    await db.setGroupState(
      'club',
      document: base64.encode(utf8.encode(jsonEncode(const GroupDocument(salt: 'a', title: 'Club Room').toJson()))),
    );
  });

  tearDown(() => db.close());

  /// Stores a received message, as sync would.
  Future<int> receive(
    String conv,
    String from,
    String text, {
    bool undecryptable = false,
  }) async {
    final envelope = undecryptable
        ? Envelope(
            id: newUlid(),
            conv: conv,
            from: from,
            ts: 1,
            type: Envelope.encryptedType,
            body: const {},
          )
        : Envelope.text(conv: conv, from: from, text: text);
    final event = SyncEvent(
      seq: ++seq,
      type: EventType.message,
      conv: conv,
      ts: 1,
      data: envelope.toJson(),
    );
    await db.applyEvents(
      [event],
      me: me,
      received: {event.seq: ReceivedMessage(envelope: envelope)},
    );
    return event.seq;
  }

  /// Stores any message, as sync would.
  Future<Envelope> deliver(Envelope envelope) async {
    final event = SyncEvent(seq: ++seq, type: EventType.message, conv: envelope.conv, ts: 1, data: const {});
    await db.applyEvents([event], me: me, received: {event.seq: ReceivedMessage(envelope: envelope)});
    return envelope;
  }

  List<String> texts(ChatNotification n) => [for (final l in n.lines) l.text];

  test('messages from before notifications started never alert', () async {
    await receive('dm', kumiko, 'old news');
    await center.update();
    expect(display.shown, isEmpty);
    await receive('dm', kumiko, 'new');
    await center.update();
    expect(display.shown.single.lines.map((l) => l.text), ['new']);
  });

  test('one notification per conversation, alerting once per new message, gone once read', () async {
    await center.update();
    await receive('dm', kumiko, 'Sota!');
    await center.update();
    await center.update(); // Nothing new: no second alert.
    expect(display.shown, hasLength(1));
    final first = display.shown.single;
    expect((first.title, first.isGroup, first.unread), ('KUMIKO', false, 1));
    expect(first.lines.single.sender, 'KUMIKO');

    final upTo = await receive('dm', kumiko, 'Are you free?');
    await receive('dm', me, 'My own reply does not count');
    await center.update();
    expect(display.shown, hasLength(2));
    expect(display.shown.last.lines.map((l) => l.text), [
      'Sota!',
      'Are you free?',
    ]);

    // Read here or on another device (the read marker arrives by sync).
    await db.advanceReadMarker('dm', upTo);
    await center.update();
    expect(display.active, isEmpty);
  });

  test('groups are titled after the group; undecryptable messages say "New message"', () async {
    await center.update();
    await receive('club', naoko, 'Meeting moved', undecryptable: true);
    await receive('club', kumiko, 'Got it');
    await center.update();
    final n = display.shown.single;
    expect((n.title, n.isGroup), ('Club Room', true));
    expect(
      [for (final l in n.lines) '${l.sender}: ${l.text}'],
      ['NAOKO: New message', 'KUMIKO: Got it'],
    );
  });

  test(
    'nothing pops up while the app is in the foreground, not even later',
    () async {
      await center.update();
      foreground = true;
      await receive('dm', kumiko, 'seen live');
      await center.update();
      foreground = false;
      await center.update();
      expect(display.shown, isEmpty);
      await receive('dm', kumiko, 'arrived in the background');
      await center.update();
      expect(display.shown.single.lines.last.text, 'arrived in the background');
    },
  );

  test("a call of two rings instead of notifying; a group's call notifies like a message", () async {
    await center.update();
    await deliver(Envelope.call(conv: 'dm', from: kumiko, call: newUlid()));
    await center.update();
    expect(display.shown, isEmpty);
    await deliver(Envelope.call(conv: 'club', from: naoko, call: newUlid()));
    await center.update();
    expect(display.shown.single.lines.single.text, '[Voice call]');
  });

  test('previews off: no names or text', () async {
    await center.update();
    await const NotificationPreferences(preview: false).save(db);
    await receive('dm', kumiko, 'secret plans');
    await receive('dm', kumiko, 'more secret plans');
    await center.update();
    final n = display.shown.single;
    expect((n.title, n.lines.length, n.unread), ('Hanashi', 0, 2));
  });

  test('turning notifications off removes them and shows no more', () async {
    await center.update();
    await receive('dm', kumiko, 'hi');
    await center.update();
    expect(display.active, hasLength(1));
    await const NotificationPreferences(enabled: false).save(db);
    await center.update();
    expect(display.active, isEmpty);
    await receive('dm', kumiko, 'hello?');
    await center.update();
    expect(display.shown, hasLength(1));
  });

  test('at most five lines', () async {
    await center.update();
    for (var i = 1; i <= 7; i++) {
      await receive('dm', kumiko, 'm$i');
    }
    await center.update();
    final n = display.shown.single;
    expect(n.unread, 7);
    expect(n.lines.map((l) => l.text), ['m3', 'm4', 'm5', 'm6', 'm7']);
  });

  test('reactions to your messages notify while they stand; replies to you say so', () async {
    await center.update();
    final mine = await deliver(Envelope.text(conv: 'dm', from: me, text: 'Parfait after school?'));
    final theirs = await deliver(Envelope.text(conv: 'club', from: naoko, text: 'Report done'));
    Future<void> react(String from, Envelope target, String emoji, {bool remove = false}) =>
        deliver(Envelope.reaction(conv: target.conv, from: from, target: target.id, emoji: emoji, remove: remove));

    await react(kumiko, mine, '👍');
    await react(kumiko, theirs, '🙏'); // Not about the user's message.
    await center.update();
    expect(display.active['dm']!.lines.single.text, 'Reacted 👍 to "Parfait after school?"');
    expect(display.active['club']!.lines.map((l) => l.text), ['Report done']);

    // Another reaction alerts again.
    await react(kumiko, mine, '❤️');
    await center.update();
    expect(display.shown.last.lines.map((l) => l.text), [
      'Reacted 👍 to "Parfait after school?"',
      'Reacted ❤️ to "Parfait after school?"',
    ]);
    // Taking one back does not alert again; the next notification leaves it out.
    final shown = display.shown.length;
    await react(kumiko, mine, '👍', remove: true);
    await center.update();
    expect(display.shown, hasLength(shown));
    await react(kumiko, mine, '😂');
    await center.update();
    expect(display.shown.last.lines.map((l) => l.text), [
      'Reacted ❤️ to "Parfait after school?"',
      'Reacted 😂 to "Parfait after school?"',
    ]);
    await react(kumiko, mine, '❤️', remove: true);
    await react(kumiko, mine, '😂', remove: true);
    await center.update();
    expect(display.active.containsKey('dm'), isFalse);

    final question = await deliver(Envelope.text(conv: 'club', from: me, text: 'Who has the key?'));
    await deliver(
      Envelope.text(
        conv: 'club',
        from: kumiko,
        text: 'I do',
        replyTo: ReplyRef(id: question.id, from: me, text: question.text),
      ),
    );
    await center.update();
    expect(display.active['club']!.lines.last.text, 'Replied to you: I do');
  });

  test('a muted chat notifies nothing, for a while or for good, and its notification goes', () async {
    await center.update();
    await receive('dm', kumiko, 'before muting');
    await center.update();
    expect(display.active.keys, ['dm']);

    await db.setChatSettings({'dm': ChatSettings(mutedUntil: now.add(const Duration(hours: 1)).millisecondsSinceEpoch)});
    await center.update();
    expect(display.active, isEmpty);
    await receive('dm', kumiko, 'while muted');
    await center.update();
    expect(display.shown, hasLength(1));

    // The hour is over: nothing alerts until something new comes.
    now = now.add(const Duration(hours: 2));
    await center.update();
    expect(display.shown, hasLength(1));
    await receive('dm', kumiko, 'after');
    await center.update();
    expect(texts(display.shown.last), ['before muting', 'while muted', 'after']);

    await db.setChatSettings({'dm': const ChatSettings(notify: ChatNotify.off)});
    await receive('dm', kumiko, 'never');
    await center.update();
    expect(display.active, isEmpty);
    expect(display.shown, hasLength(2));
  });

  test('what notifies, and with a sound or not: per kind on this device, then per chat', () async {
    await center.update();
    await const NotificationPreferences(
      styles: {NotifyKind.direct: NotifyStyle.off, NotifyKind.group: NotifyStyle.silent},
    ).save(db);
    await receive('dm', kumiko, 'direct');
    await receive('club', naoko, 'group');
    await center.update();
    expect(display.active.keys, ['club']);
    expect(display.active['club']!.audible, isFalse);

    // A reply to the user in the group is a kind of its own, with a sound.
    final question = await deliver(Envelope.text(conv: 'club', from: me, text: 'Who has the key?'));
    await deliver(
      Envelope.text(conv: 'club', from: kumiko, text: 'I do', replyTo: ReplyRef(id: question.id, from: me)),
    );
    await center.update();
    expect(display.shown.last.audible, isTrue);

    // A chat's own settings come first: all of the direct chat, silently.
    await db.setChatSettings({'dm': const ChatSettings(notify: ChatNotify.all, sound: false)});
    await receive('dm', kumiko, 'again');
    await center.update();
    expect(texts(display.active['dm']!), ['direct', 'again']);
    expect(display.active['dm']!.audible, isFalse);

    // Only replies and reactions to the user in the group.
    await db.setChatSettings({'club': const ChatSettings(notify: ChatNotify.replies)});
    final shown = display.shown.length;
    await receive('club', naoko, 'not for you');
    await center.update();
    expect(display.shown, hasLength(shown));
  });

  test('in Focus, notifications wait; once it ends, they show without a sound', () async {
    await center.update();
    await db.setPresenceMode(PresenceMode.focus);
    await receive('dm', kumiko, 'while you focus');
    await center.update();
    await center.update();
    expect(display.shown, isEmpty);

    await db.setPresenceMode(PresenceMode.auto);
    await center.update();
    expect(texts(display.shown.single), ['while you focus']);
    expect(display.shown.single.audible, isFalse);
    await receive('dm', kumiko, 'after Focus');
    await center.update();
    expect(display.shown.last.audible, isTrue);
  });

  test('what waited for Focus but was then seen in the app, or read, never shows', () async {
    await center.update();
    await db.setPresenceMode(PresenceMode.focus);
    await receive('dm', kumiko, 'seen in the app');
    final read = await receive('club', naoko, 'read on another device');
    await center.update();
    await db.advanceReadMarker('club', read);
    await db.setPresenceMode(PresenceMode.auto);
    foreground = true;
    await center.update();
    foreground = false;
    await center.update();
    expect(display.shown, isEmpty);
  });

  test("each line shows its sender's picture, when there is one to be had", () async {
    final picture = MediaRef(hash: 'sha256:${'a' * 64}', size: 1, mime: 'image/jpeg', key: 'a2V5');
    final broken = MediaRef(hash: 'sha256:${'b' * 64}', size: 1, mime: 'image/jpeg', key: 'a2V5');
    await db.noteProfile(kumiko, ProfileDocument(displayName: 'KUMIKO', avatar: picture), version: 2);
    await db.noteProfile(naoko, ProfileDocument(displayName: 'NAOKO', avatar: broken), version: 2);
    final withPictures = NotificationCenter(
      db: db,
      me: me,
      notifier: display,
      pictureBytes: (ref) async =>
          ref.hash == broken.hash ? throw StateError('offline') : Uint8List.fromList(ref.hash.codeUnits),
    );
    await withPictures.update();
    await receive('club', kumiko, 'Sota!');
    await receive('club', naoko, 'Report done');
    await receive('club', 'aiko@test.local', 'No picture yet');
    await withPictures.update();
    expect([for (final l in display.shown.single.lines) l.picture], [
      picture.hash.codeUnits,
      null, // Not to be had now: the notification shows anyway.
      null,
    ]);
  });

  group('contacts', () {
    const hiroko = 'hiroko@test.local';
    const remote = 'yuriko@other.example';

    test('a request notifies once, by the ID of whoever asks, and goes once answered here or elsewhere', () async {
      // Asked before notifications started: that one never alerts.
      await db.setContactState(naoko, ContactState.incoming);
      await center.update();
      expect(display.contacts, isEmpty);

      await db.setContactState(hiroko, ContactState.incoming);
      await db.setContactState(remote, ContactState.incoming);
      await center.update();
      await center.update(); // Nothing new: no second alert.
      expect([for (final n in display.contacts) (n.notice, n.title, n.body, n.audible)], [
        (ContactNotice.request, 'Contact request', '$hiroko wants to be your contact', true),
        (ContactNotice.request, 'Contact request', '$remote wants to be your contact', true),
      ]);

      // Accepted on another device, declined here.
      await db.setContactState(hiroko, ContactState.accepted);
      await db.setTrustedContacts({hiroko});
      await db.setContactState(remote, ContactState.none);
      await center.update();
      expect(display.activeContacts, isEmpty);
      expect(display.contacts, hasLength(2), reason: 'accepting it is no news to the user');

      // Asked again later: that is new.
      await db.setContactState(remote, ContactState.incoming);
      await center.update();
      expect(display.activeContacts.keys, [remote]);
    });

    test("someone the user asked accepting is told once, by the name they go by", () async {
      await center.update();
      await db.setContactState(kumiko, ContactState.outgoing);
      await db.setTrustedContacts({kumiko});
      await center.update();
      expect(display.contacts, isEmpty);

      await db.setContactState(kumiko, ContactState.accepted);
      await center.update();
      await center.update();
      final told = display.contacts.single;
      expect((told.notice, told.userId, told.title, told.body), (
        ContactNotice.accepted,
        kumiko,
        'KUMIKO',
        'Accepted your contact request',
      ));

      // The server's word alone makes nobody a contact: not on the user's own
      // list, nothing to tell.
      await db.setContactState(naoko, ContactState.outgoing);
      await center.update();
      await db.setContactState(naoko, ContactState.accepted);
      await center.update();
      expect(display.contacts, hasLength(1));
    });

    test('they follow the settings: previews, silent or off', () async {
      await center.update();
      await const NotificationPreferences(preview: false, styles: {NotifyKind.requests: NotifyStyle.silent}).save(db);
      await db.setContactState(hiroko, ContactState.incoming);
      await center.update();
      final hidden = display.contacts.single;
      expect((hidden.title, hidden.body, hidden.audible), ('Hanashi', 'New contact request', false));

      // Off: what shows goes, and nothing more shows, then or later.
      await const NotificationPreferences(styles: {NotifyKind.requests: NotifyStyle.off}).save(db);
      await db.setContactState(remote, ContactState.incoming);
      await center.update();
      expect(display.activeContacts, isEmpty);
      await const NotificationPreferences().save(db);
      await center.update();
      expect(display.contacts, hasLength(1));
    });

    test('in Focus they wait, and show without a sound; seen in the app, never', () async {
      await center.update();
      await db.setContactState(kumiko, ContactState.outgoing);
      await db.setTrustedContacts({kumiko});
      await center.update();
      await db.setPresenceMode(PresenceMode.focus);
      await db.setContactState(hiroko, ContactState.incoming);
      await db.setContactState(kumiko, ContactState.accepted);
      await center.update();
      await center.update();
      expect(display.contacts, isEmpty);

      await db.setPresenceMode(PresenceMode.auto);
      await center.update();
      expect([for (final n in display.contacts) (n.notice, n.audible)], [
        (ContactNotice.request, false),
        (ContactNotice.accepted, false),
      ]);

      // A request that comes while the user looks at the app shows only there.
      foreground = true;
      await db.setContactState(remote, ContactState.incoming);
      await center.update();
      foreground = false;
      await center.update();
      expect(display.contacts, hasLength(2));
    });
  });
}
