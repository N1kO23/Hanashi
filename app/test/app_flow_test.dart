import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/ui/widgets/hanashi_title_bar.dart';

import 'support/test_app.dart';

void main() {
  testWidgets('phone: open a chat, unread clears, send a message', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();

    expect(find.text('Unread Messages (4)'), findsOneWidget);
    expect(find.text('Club Room'), findsOneWidget);
    expect(find.text('Naoko'), findsOneWidget);

    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    expect(find.text('It is my treat this time!'), findsOneWidget);

    final field = find.byKey(const Key('composer-field'));
    await tester.enterText(field, 'Sure, see you at five!');
    await tester.pump(); // Enables the send button.
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('Sure, see you at five!'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    // Only Naoko's photo is still unread; the chat list preview shows the new message.
    expect(find.text('Unread Messages (1)'), findsOneWidget);
    expect(find.text('Sure, see you at five!'), findsOneWidget);
    repo.dispose();
  });

  testWidgets('wide: list and chat side by side; a contact shows their profile, which opens a direct chat', (
    tester,
  ) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    expect(find.text('Select a chat to start messaging'), findsOneWidget);

    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    expect(find.text('Select a contact.'), findsOneWidget);
    await tester.tap(find.text('Aiko'));
    await tester.pumpAndSettle();

    // Her profile beside the contacts, and no chat started yet.
    expect(find.byKey(const Key('profile-name')), findsOneWidget);
    expect(find.text('Practice at four!'), findsNWidgets(2)); // In the list and on her profile.
    expect(find.byKey(const Key('profile-verify')), findsOneWidget);
    expect(find.byKey(const Key('composer-field')), findsNothing);

    // New, empty direct chat is open next to the list.
    await tester.tap(find.byKey(const Key('profile-message')));
    await tester.pumpAndSettle();
    expect(find.text('No messages yet. Say hello!'), findsOneWidget);
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    expect(find.text('Club Room'), findsOneWidget);
    repo.dispose();
  });

  testWidgets('desktop: window buttons and dragging live in the app', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    final window = FakeWindowControls();
    await tester.pumpWidget(testApp(repo, windowControls: window));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Maximize'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Restore'), findsOneWidget); // Icon follows the window state.
    await tester.tap(find.byTooltip('Restore'));
    await tester.tap(find.byTooltip('Minimize'));
    await tester.tap(find.byTooltip('Close'));

    // Dragging the title bar moves the window; double-clicking maximizes.
    final title = find.byType(HanashiLogo);
    await tester.drag(title, const Offset(80, 40));
    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(title);
    await tester.pumpAndSettle();

    expect(window.calls, ['toggleMaximize', 'toggleMaximize', 'minimize', 'close', 'startDragging', 'toggleMaximize']);
    repo.dispose();
  });

  testWidgets('phones get no window buttons', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close'), findsNothing);
    repo.dispose();
  });

  testWidgets('a chat explains why sending is paused', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = _SecurityRepository()
      ..issues['dm-naoko'] = 'An unverified device was found in this chat and is being removed.';
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('security-banner')), findsOneWidget);
    expect(find.text('An unverified device was found in this chat and is being removed.'), findsOneWidget);
    // Nothing for the user to decide here: the device is removed automatically.
    expect(find.byKey(const Key('accept-identity')), findsNothing);
    repo.dispose();
  });

  testWidgets("a contact's changed security key can be accepted", (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = _SecurityRepository()..changed.add('kumiko@localhost');
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Kumiko's security key changed"), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-identity')));
    await tester.pumpAndSettle();
    expect(repo.changed, isEmpty);
    expect(find.byKey(const Key('security-banner')), findsNothing);

    // Chats without the user show nothing.
    repo.changed.add('kumiko@localhost');
    repo.notifyIdentityChanges();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('security-banner')), findsNothing);
    repo.dispose();
  });
}

/// Sample data plus per-chat security issues and changed identity keys.
class _SecurityRepository extends MockChatRepository {
  _SecurityRepository() : super(latency: Duration.zero, autoReply: false, now: testNow);

  final issues = <String, String>{};
  final changed = <String>{};
  final _identityChanges = StreamController<Set<String>>.broadcast(sync: true);

  void notifyIdentityChanges() => _identityChanges.add({...changed});

  @override
  Stream<List<ConversationSummary>> watchConversations() => super.watchConversations().map(
    (list) => [
      for (final s in list)
        ConversationSummary(
          conversation: s.conversation,
          title: s.title,
          avatarId: s.avatarId,
          lastMessage: s.lastMessage,
          unreadCount: s.unreadCount,
          securityIssue: issues[s.id],
        ),
    ],
  );

  @override
  Stream<Set<String>> watchIdentityChanges() async* {
    yield {...changed};
    yield* _identityChanges.stream;
  }

  @override
  Future<void> acceptIdentityChange(String userId) async {
    changed.remove(userId);
    notifyIdentityChanges();
  }

  @override
  void dispose() {
    _identityChanges.close();
    super.dispose();
  }
}
