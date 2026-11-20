import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/notifications/notification_center.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/widgets/unread_badge.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/fake_display.dart';
import 'support/test_app.dart';

/// A chat's own settings, and which kinds of messages notify on this device.
void main() {
  /// The unread counts shown, in order: the tab's, then the chats'.
  List<(int, bool)> badges(WidgetTester tester) => [
    for (final b in tester.widgetList<UnreadBadge>(find.byType(UnreadBadge))) (b.count, b.muted),
  ];

  testWidgets('a chat muted from its menu: marked so, a grey count, and left out of the total', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    expect(badges(tester), [(4, false), (3, false), (1, false)]);

    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-mute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-mute-60')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-muted-icon')), findsOneWidget);
    expect(find.byKey(const Key('chat-title-muted')), findsOneWidget);

    // Its settings say until when.
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Muted until 19:30'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(badges(tester), [(1, false), (1, false)]); // Kumiko's chat is read now.

    // A muted chat's unread count is grey, and the total leaves it out.
    final until = testNow.add(const Duration(days: 1)).millisecondsSinceEpoch;
    await repo.setChatSettings('dm-naoko', ChatSettings(mutedUntil: until));
    await tester.pumpAndSettle();
    expect(badges(tester), [(1, true)]);
    expect(find.textContaining('Unread Messages'), findsNothing);

    // Muted for good, then unmuted, in its settings.
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-unmute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-mute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-mute-forever')));
    await tester.pumpAndSettle();
    expect(find.text('Muted'), findsOneWidget);
    expect(repo.chatSettings['dm-kumiko'], const ChatSettings(notify: ChatNotify.off));
    await tester.tap(find.byKey(const Key('chat-unmute')));
    await tester.pumpAndSettle();
    expect(repo.chatSettings.keys, ['dm-naoko']);
    repo.dispose();
  });

  testWidgets("a chat's menu also opens from the list, with a right click", (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naoko'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    // Unread, so it can be marked read from here.
    expect(find.byKey(const ValueKey('chat-menu-markRead')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-menu-mute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-mute-forever')));
    await tester.pumpAndSettle();
    expect(repo.chatSettings, {'dm-naoko': const ChatSettings(notify: ChatNotify.off)});
    expect(find.byKey(const Key('chat-muted-icon')), findsOneWidget);
    expect(find.text('Select a chat to start messaging'), findsOneWidget); // Not opened.
    repo.dispose();
  });

  testWidgets('what notifies in a chat, and with a sound or not', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-settings')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('As in your settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replies and reactions to you').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('As in your settings').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Silent').last);
    await tester.pumpAndSettle();
    expect(repo.chatSettings, {'club': const ChatSettings(notify: ChatNotify.replies, sound: false)});
    repo.dispose();
  });

  testWidgets('which kinds of messages notify on this device, and how', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 900));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = testRepository();
    await tester.pumpWidget(
      testApp(
        repo,
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationDisplayProvider.overrideWithValue(FakeDisplay()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('notify-kind-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notify-kind-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notify-style-group-silent')));
    await tester.pumpAndSettle();
    expect((await NotificationPreferences.load(db)).styleOf(NotifyKind.group), NotifyStyle.silent);
    expect((await NotificationPreferences.load(db)).styleOf(NotifyKind.direct), NotifyStyle.sound);
    repo.dispose();
  });
}
