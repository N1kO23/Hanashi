import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

/// Whole-app goldens at desktop and phone sizes, rendered with real fonts.
void main() {
  setUpAll(loadRealFonts);

  testWidgets('desktop: chat open beside the list', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 760));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo, windowControls: FakeWindowControls()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/desktop_chat.png'));
    repo.dispose();
  });

  testWidgets('phone: chat list', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_list.png'));
    repo.dispose();
  });

  testWidgets('phone: open chat', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_chat.png'));
    repo.dispose();
  });

  testWidgets('phone: group info over a group with a timeline line', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await repo.addMember('club', 'naoko@localhost');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-title-group-info')));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_group_info.png'));
    repo.dispose();
  });

  testWidgets("phone: a contact's profile, as the game shows a student's", (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository()
      ..setCard(
        'kumiko@localhost',
        const ProfileCard(statusMessage: 'Only the best for you!', birthday: Birthday(3, 24)),
      );
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-title-profile')));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_profile.png'));
    repo.dispose();
  });

  testWidgets('phone: contacts, birthdays first, as the game lists students', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_contacts.png'));
    repo.dispose();
  });

  testWidgets('desktop: contacts, with the profile of the one picked beside them', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 760));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo, windowControls: FakeWindowControls()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sweets after school?'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/desktop_contacts.png'));
    repo.dispose();
  });

  testWidgets("phone: a muted chat's settings", (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await repo.setChatSettings(
      'dm-kumiko',
      ChatSettings(mutedUntil: testNow.add(const Duration(hours: 8)).millisecondsSinceEpoch, sound: false),
    );
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-menu-settings')));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_chat_settings.png'));
    repo.dispose();
  });

  testWidgets("phone: a contact's profile in place of the list", (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository()
      ..setCard(
        'kumiko@localhost',
        const ProfileCard(statusMessage: 'Only the best for you!', birthday: Birthday(3, 24)),
      );
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_contact_profile.png'));
    repo.dispose();
  });

  group('themes', () {
    testWidgets('desktop: chat open beside the list, in dark mode', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 760));
      final repo = testRepository();
      await tester.pumpWidget(
        testApp(
          repo,
          windowControls: FakeWindowControls(),
          overrides: [themesShowing(mode: ThemeMode.dark)],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Club Room'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/desktop_chat_dark.png'));
      repo.dispose();
    });

    testWidgets('phone: chat list, in dark mode', (tester) async {
      await setSurfaceSize(tester, const Size(400, 860));
      final repo = testRepository();
      await tester.pumpWidget(testApp(repo, overrides: [themesShowing(mode: ThemeMode.dark)]));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_list_dark.png'));
      repo.dispose();
    });

    testWidgets("phone: a muted chat's settings, in dark mode", (tester) async {
      await setSurfaceSize(tester, const Size(400, 860));
      final repo = testRepository();
      await repo.setChatSettings(
        'dm-kumiko',
        ChatSettings(mutedUntil: testNow.add(const Duration(hours: 8)).millisecondsSinceEpoch, sound: false),
      );
      await tester.pumpWidget(testApp(repo, overrides: [themesShowing(mode: ThemeMode.dark)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kumiko'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-menu-settings')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_chat_settings_dark.png'));
      repo.dispose();
    });

    for (final (mode, golden) in [(ThemeMode.light, 'phone_appearance'), (ThemeMode.dark, 'phone_appearance_dark')]) {
      testWidgets("phone: Settings, the app's appearance (${mode.name})", (tester) async {
        await setSurfaceSize(tester, const Size(400, 860));
        final repo = testRepository();
        await tester.pumpWidget(testApp(repo, overrides: [themesShowing(mode: mode)]));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();
        final header = find.text('Appearance');
        final settings = find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first;
        await tester.scrollUntilVisible(header, 200, scrollable: settings);
        await tester.ensureVisible(header);
        // With the end of the section before it.
        await tester.drag(settings, const Offset(0, 60));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$golden.png'));
        repo.dispose();
      });
    }
  });
}
