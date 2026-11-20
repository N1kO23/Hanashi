import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/encryption/verification_dialog.dart';
import 'package:hanashi/ui/widgets/avatar.dart';

import 'support/test_app.dart';

/// A server that refuses a member who has not set up encryption.
class _NoKeysRepository extends MockChatRepository {
  _NoKeysRepository()
    : super(latency: Duration.zero, autoReply: false, now: testNow);

  @override
  Future<String> createGroup(String title, List<String> members) async =>
      throw StateError(
        'naoko@localhost has not set up encryption on any device yet.',
      );
}

void main() {
  testWidgets(
    'create a group from Contacts, of contacts',
    (tester) async {
      await setSurfaceSize(tester, const Size(1200, 800));
      final repo = testRepository();
      await tester.pumpWidget(testApp(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-group')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('group-create')))
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const Key('group-title-field')),
        'Study Group',
      );
      await tester.tap(find.byKey(const ValueKey('member-kumiko@localhost')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('member-naoko@localhost')));
      await tester.pumpAndSettle();
      expect(find.text('Create with 3'), findsOneWidget);
      // Only contacts: nobody else can be typed in.
      expect(find.byKey(const Key('member-id-field')), findsNothing);

      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      // The new group is open, with a line saying who made it.
      expect(find.text('Study Group'), findsWidgets);
      expect(find.text('3 members'), findsOneWidget);
      // In the timeline, and as the list's preview.
      expect(
        find.text('You created the group "Study Group"'),
        findsNWidgets(2),
      );
      repo.dispose();
    },
  );

  testWidgets('a member without encryption: the dialog says so', (
    tester,
  ) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = _NoKeysRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-group')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-title-field')),
      'Study Group',
    );
    await tester.tap(find.byKey(const ValueKey('member-naoko@localhost')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('group-create')));
    await tester.pumpAndSettle();
    expect(
      find.text('naoko@localhost has not set up encryption on any device yet.'),
      findsOneWidget,
    );
    repo.dispose();
  });

  testWidgets("a group's info opens from its name and from the chat's menu: no button of its own", (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Group info'), findsNothing);
    expect(find.byKey(const Key('chat-title-profile')), findsNothing);
    await tester.tap(find.byKey(const Key('chat-title-group-info')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('group-info-title'))).data, 'Club Room');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-info-title')), findsNothing);
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-groupInfo')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('group-info-title'))).data, 'Club Room');
  });

  testWidgets('group info: rename, add people, leave', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    expect(find.text('4 members'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-title-group-info')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-field')),
      'Club Room 2',
    );
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-info-title')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('group-info-title'))).data,
      'Club Room 2',
    );

    await tester.tap(find.byKey(const Key('group-add-members')));
    await tester.pumpAndSettle();
    // Current members are not offered again.
    expect(find.byKey(const ValueKey('member-kumiko@localhost')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('member-naoko@localhost')));
    await tester.pump();
    // The history is shared unless unticked.
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('share-history'))).value, isTrue);
    await tester.tap(find.byKey(const Key('share-history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('add-members-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('5 members'), findsWidgets);
    expect(find.text('You added Naoko'), findsWidgets);
    expect(find.textContaining('shared the chat history'), findsNothing);

    await tester.tap(find.byKey(const Key('group-leave')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-confirm')));
    await tester.pumpAndSettle();
    // Back at the list, without the group.
    expect(find.text('Club Room 2'), findsNothing);
    expect(find.text('Select a chat to start messaging'), findsOneWidget);
    repo.dispose();
  });

  testWidgets('group info: a description, to add, change and remove', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-title-group-info')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-describe')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('description-remove')), findsNothing);
    await tester.enterText(find.byKey(const Key('description-field')), 'After school.\nBring snacks.');
    await tester.tap(find.byKey(const Key('description-save')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const Key('group-description')), matching: find.textContaining('Bring snacks.')),
      findsOneWidget,
    );
    expect(find.text('You changed the group description'), findsWidgets);

    // Tapping it changes it; it can go.
    await tester.tap(find.byKey(const Key('group-description')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('description-remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-description')), findsNothing);
    expect(find.byKey(const Key('group-describe')), findsOneWidget);
    expect(find.text('You removed the group description'), findsWidgets);
    repo.dispose();
  });

  testWidgets('group info: the picture can be changed and removed', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await repo.setGroupPicture('club', 'picture.png');
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-title-group-info')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-picture')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-picture-change')), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-picture-remove')));
    await tester.pumpAndSettle();
    // Read outside the test's fake clock.
    final summaries = (await tester.runAsync(() => repo.watchConversations().first))!;
    expect(summaries.firstWhere((s) => s.id == 'club').picture, isNull);
    // In the chat, and as its latest news in the list.
    expect(find.text('You removed the group picture'), findsWidgets);
    // Nothing left to remove.
    await tester.tap(find.byKey(const Key('group-picture')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-picture-remove')), findsNothing);
    expect(find.byKey(const Key('group-picture-change')), findsOneWidget);
    repo.dispose();
  });

  testWidgets('the chat shows who is typing: in its title, and as a bubble below the last message', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    final bubble = find.byKey(const Key('typing-bubble'));
    expect(bubble, findsNothing);

    // The dots never stop moving: a fixed time instead of settling.
    repo.setTyping('club', {'yoko@localhost', 'kumiko@localhost'});
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Kumiko and Yoko are typing...'), findsOneWidget);
    expect(
      tester.getSemantics(bubble),
      matchesSemantics(label: 'Kumiko and Yoko are typing...', isLiveRegion: true),
    );
    // Below the newest message, with both pictures.
    final lowest = [
      for (final i in Iterable<int>.generate(find.byType(MessageBubble).evaluate().length))
        tester.getBottomLeft(find.byType(MessageBubble).at(i)).dy,
    ].reduce(max);
    expect(tester.getTopLeft(bubble).dy, greaterThanOrEqualTo(lowest));
    expect(find.descendant(of: bubble, matching: find.byType(Avatar)), findsNWidgets(2));

    repo.setTyping('club', {'kumiko@localhost'});
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.descendant(of: bubble, matching: find.byType(Avatar)), findsOneWidget);
    expect(tester.widget<Avatar>(find.descendant(of: bubble, matching: find.byType(Avatar))).id, 'kumiko@localhost');

    repo.setTyping('club', {});
    await tester.pumpAndSettle();
    expect(find.text('4 members'), findsOneWidget);
    expect(bubble, findsNothing);
    repo.dispose();
  });

  testWidgets('verified contacts get a badge, others a verify button', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository()..verified.add('kumiko@localhost');
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Kumiko is verified'), findsOneWidget);
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Verify Naoko'), findsOneWidget);

    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-title-group-info')));
    await tester.pumpAndSettle();
    expect(find.byType(VerifiedBadge), findsOneWidget); // Kumiko
    expect(find.byKey(const ValueKey('verify-aiko@localhost')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // Close the dialog.
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    expect(find.byType(VerifiedBadge), findsOneWidget);
    repo.dispose();
  });
}
