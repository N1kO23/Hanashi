import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/ui/widgets/format.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

const _hash = 'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
const _newer = 'sha256:0000000000000000000000000000000000000000000000000000000000000001';

/// Profiles as the game's messenger shows them: picture with a status badge,
/// name, status message, birthday.
void main() {
  test('birthdays read as the game writes them', () {
    expect(
      [for (final (m, d) in [(3, 24), (1, 1), (2, 2), (5, 3), (6, 11), (7, 12), (8, 13), (9, 21), (12, 31)]) formatBirthday(Birthday(m, d))],
      ['March 24th', 'January 1st', 'February 2nd', 'May 3rd', 'June 11th', 'July 12th', 'August 13th', 'September 21st', 'December 31st'],
    );
  });

  test('a profile card shows once fetched, the last one until a newer one is', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const user = 'kumiko@test.local';
    const card = MediaRef(hash: _hash, size: 50, mime: 'application/json', key: 'a2V5');
    const newer = MediaRef(hash: _newer, size: 50, mime: 'application/json', key: 'a2V5');
    Future<ProfileCard> shown() async => (await db.watchProfiles().first).single.card;

    await db.noteProfile(user, const ProfileDocument(card: card), version: 10);
    expect([for (final c in await db.cardsToFetch()) c.card.hash], [_hash]);
    expect(await shown(), ProfileCard.empty);
    await db.setFetchedCard(user, _hash, '{"statusMessage":"Sweets after school?"}');
    expect((await shown()).statusMessage, 'Sweets after school?');
    expect(await db.cardsToFetch(), isEmpty);

    // A newer card: the last one shows until it is fetched; a late answer
    // for the older one changes nothing.
    await db.noteProfile(user, const ProfileDocument(card: newer), version: 20);
    expect((await shown()).statusMessage, 'Sweets after school?');
    await db.setFetchedCard(user, _hash, '{"statusMessage":"stale"}');
    expect((await shown()).statusMessage, 'Sweets after school?');
    await db.setFetchedCard(user, _newer, '{"birthday":{"month":8,"day":5}}');
    expect(await shown(), const ProfileCard(birthday: Birthday(8, 5)));
    // An older version changes nothing; none at all clears it.
    await db.noteProfile(user, const ProfileDocument(card: card), version: 15);
    expect(AppDatabase.mediaRefOf((await db.profileRow(user))!.card)!.hash, _newer);
    await db.noteProfile(user, const ProfileDocument(), version: 30);
    expect(await shown(), ProfileCard.empty);
    expect(await db.cardsToFetch(), isEmpty);
  });

  testWidgets("a contact's profile opens from Contacts, and messages them", (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    // The list shows each contact's status message, as the game lists students.
    expect(find.text('Sweets after school?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('contact-profile-kumiko@localhost')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-name')), findsOneWidget);
    expect(find.byKey(const Key('profile-status-message')), findsOneWidget);
    expect(find.byKey(const Key('profile-birthday')), findsNothing); // She has not told it.
    expect(find.byKey(const Key('status-online')), findsWidgets);
    repo.setPresence('kumiko@localhost', Presence.idle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status-idle')), findsWidgets);

    await tester.tap(find.byKey(const Key('profile-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-name')), findsNothing);
    expect(find.text('It is my treat this time!'), findsWidgets); // The chat with her is open.
    repo.dispose();
  });

  testWidgets('your status message, about me, birthday and status, from Settings', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit-profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('status-message-field')), 'Only the best for you!');
    await tester.enterText(find.byKey(const Key('bio-field')), '  Teacher at Minato.\nLikes figures.  ');
    await tester.tap(find.byKey(const Key('birthday-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('birthday-month')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('March').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('birthday-day-3')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('24'), 100, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('24').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('birthday-save')));
    await tester.pumpAndSettle();
    expect(find.text('March 24th'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status-message-field')), findsNothing);

    // The way others see it.
    await tester.tap(find.byKey(const Key('own-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Only the best for you!'), findsOneWidget);
    expect(find.text('March 24th'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('profile-bio')), matching: find.textContaining('Teacher at Minato.\nLikes')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('profile-edit')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('presence-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('presence-mode-focus')));
    await tester.pumpAndSettle();
    expect(find.text('Status: Focus'), findsOneWidget);
    await tester.tap(find.byKey(const Key('presence-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('presence-mode-invisible')));
    await tester.pumpAndSettle();
    expect(find.text('Status: Invisible'), findsOneWidget);
    repo.dispose();
  });
}
