import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/ui/chat_list/chat_list_screen.dart';
import 'package:hanashi/ui/contacts/contacts_screen.dart';
import 'package:hanashi/ui/widgets/format.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

/// Contacts as the game lists students: today's and upcoming birthdays
/// first, then everyone, sorted as the user likes. (The demo's made-up
/// birthdays: Naoko's is today, Yoko's in five days.)
void main() {
  test('days until a birthday, around the year and in leap years', () {
    final now = DateTime(2026, 10, 22, 18, 30);
    expect(daysUntilBirthday(const Birthday(10, 22), now), 0);
    expect(daysUntilBirthday(const Birthday(10, 27), now), 5);
    expect(daysUntilBirthday(const Birthday(10, 21), now), 364);
    expect(daysUntilBirthday(const Birthday(1, 1), DateTime(2026, 12, 31)), 1);
    // In 2027, February 29 falls on the 28th; in 2028 it is there.
    expect(daysUntilBirthday(const Birthday(2, 29), DateTime(2027, 2, 27)), 1);
    expect(daysUntilBirthday(const Birthday(2, 29), DateTime(2028, 2, 27)), 2);
  });

  List<String> names(WidgetTester tester) => [
    for (final tile in tester.widgetList<ContactTile>(find.byType(ContactTile))) tile.profile.displayName,
  ];

  testWidgets('birthdays come first, then everyone, sorted by name, status or birthday', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 900));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();

    expect(find.text('Contacts (4)'), findsOneWidget);
    for (final section in ["Today's Birthdays", 'Upcoming Birthdays', 'All Contacts']) {
      expect(find.text(section), findsOneWidget);
    }
    expect(find.byKey(const Key('birthday-today')), findsNWidgets(2)); // Naoko, in both lists.
    expect(find.text('D-5'), findsNWidgets(2)); // Yoko.
    expect(names(tester), ['Naoko', 'Yoko', 'Aiko', 'Kumiko', 'Naoko', 'Yoko']);

    Future<void> sortBy(String label) async {
      await tester.tap(find.byTooltip('Sort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    // Who can answer first: online, idle, in focus, offline.
    await sortBy('Status');
    expect(names(tester).skip(2), ['Kumiko', 'Aiko', 'Yoko', 'Naoko']);
    await sortBy('Birthday');
    expect(names(tester).skip(2), ['Naoko', 'Yoko', 'Aiko', 'Kumiko']);
    await tester.tap(find.byKey(const Key('contacts-order')));
    await tester.pumpAndSettle();
    expect(names(tester).skip(2), ['Kumiko', 'Aiko', 'Yoko', 'Naoko']);
    repo.dispose();
  });

  testWidgets('without birthdays to tell, there are no sections', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 900));
    final repo = testRepository()
      ..setCard('naoko@localhost', const ProfileCard())
      ..setCard('yoko@localhost', const ProfileCard(birthday: Birthday(1, 1)));
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    expect(find.text('All Contacts'), findsNothing);
    expect(names(tester), ['Aiko', 'Kumiko', 'Naoko', 'Yoko']);
    repo.dispose();
  });

  testWidgets('on a computer, the one picked shows their profile beside the list', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 900));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    // Their picture shows it too, rather than a dialog over it.
    await tester.tap(find.byKey(const ValueKey('contact-profile-naoko@localhost')).first);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const Key('profile-birthday')), findsOneWidget);
    expect(
      [for (final t in tester.widgetList<ContactTile>(find.byType(ContactTile))) if (t.selected) t.profile.displayName],
      ['Naoko', 'Naoko'],
    );
    repo.dispose();
  });

  testWidgets('on a phone, a contact opens their profile in place of the list, and from there the chat', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = testRepository();
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sweets after school?'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactTile), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const Key('profile-status-message')), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactTile), findsWidgets);

    // Their picture opens it too.
    await tester.tap(find.byKey(const ValueKey('contact-profile-kumiko@localhost')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-message')));
    await tester.pumpAndSettle();
    expect(find.text('It is my treat this time!'), findsOneWidget);
    repo.dispose();
  });

  group('requests', () {
    Future<void> openContacts(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Contacts'));
      await tester.pumpAndSettle();
    }

    testWidgets('asking by user ID, and taking it back', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 900));
      final repo = testRepository();
      await tester.pumpWidget(testApp(repo));
      await tester.pumpAndSettle();
      await openContacts(tester);

      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-contact')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('add-contact-field')), 'not an id');
      await tester.tap(find.byKey(const Key('add-contact-confirm')));
      await tester.pump();
      expect(find.text('Enter an ID like name@host'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('add-contact-field')), 'Hiroko@localhost');
      await tester.tap(find.byKey(const Key('add-contact-confirm')));
      await tester.pumpAndSettle();

      // Waiting for an answer: not a contact yet, and no chat to open.
      expect(find.text('Waiting for an Answer'), findsOneWidget);
      expect(find.text('Contacts (4)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('contact-request-hiroko@localhost')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile-message')), findsNothing);
      await tester.tap(find.byKey(const Key('profile-cancel-request')));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for an Answer'), findsNothing);
      repo.dispose();
    });

    testWidgets('a request shows nothing but who asks; accepting makes a contact and a chat', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 900));
      final repo = testRepository()..setContactState('hiroko@localhost', ContactState.incoming);
      await tester.pumpWidget(testApp(repo));
      await tester.pumpAndSettle();
      await openContacts(tester);

      expect(find.text('Contact Requests (1)'), findsOneWidget);
      expect(find.text('hiroko@localhost'), findsOneWidget);
      expect(find.text('Contacts (4)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('contact-request-hiroko@localhost')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-accept')));
      await tester.pumpAndSettle();
      expect(find.text('Contact Requests (1)'), findsNothing);
      expect(find.text('Contacts (5)'), findsOneWidget);
      expect(find.byKey(const Key('profile-message')), findsOneWidget);

      // An empty chat stays out of the list of chats until there is something in it.
      await tester.tap(find.byTooltip('Chats'));
      await tester.pumpAndSettle();
      expect(find.text('Hiroko'), findsNothing);
      repo.dispose();
    });

    testWidgets('declining and blocking take the request away', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 900));
      final repo = testRepository()
        ..setContactState('hiroko@localhost', ContactState.incoming)
        ..setContactState('asako@localhost', ContactState.incoming);
      await tester.pumpWidget(testApp(repo));
      await tester.pumpAndSettle();
      await openContacts(tester);
      expect(find.text('Contact Requests (2)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('contact-request-hiroko@localhost')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-decline')));
      await tester.pumpAndSettle();
      expect(find.text('Contact Requests (1)'), findsOneWidget);
      // Someone declined can be asked after all, from their profile.
      expect(find.byKey(const Key('profile-add-contact')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('contact-request-asako@localhost')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-block')));
      await tester.pumpAndSettle();
      expect(find.text('Contact Requests (1)'), findsNothing);
      expect(find.byKey(const Key('profile-unblock')), findsOneWidget);
      repo.dispose();
    });

    testWidgets('a contact can be removed from their profile, and is gone from the list', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 900));
      final repo = testRepository();
      await tester.pumpWidget(testApp(repo));
      await tester.pumpAndSettle();
      await openContacts(tester);
      await tester.tap(find.byKey(const ValueKey('contact-profile-kumiko@localhost')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-contact-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Contacts (3)'), findsOneWidget);
      expect(find.byKey(const Key('profile-add-contact')), findsOneWidget);
      repo.dispose();
    });

    testWidgets('someone who is not a contact is not listed, even if the device knows them', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 900));
      final repo = testRepository()..setContactState('yoko@localhost', ContactState.none);
      await tester.pumpWidget(testApp(repo));
      await tester.pumpAndSettle();
      await openContacts(tester);
      expect(find.text('Contacts (3)'), findsOneWidget);
      expect(find.text('Yoko'), findsNothing);
      repo.dispose();
    });
  });

  testWidgets('a new contact has a chat, which shows among the chats once something is said in it', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 900));
    final repo = testRepository()..setContactState('hiroko@localhost', ContactState.incoming);
    await repo.acceptContact('hiroko@localhost');
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    final hiroko = find.widgetWithText(ConversationTile, 'Hiroko');
    expect(find.byType(ConversationTile), findsWidgets);
    expect(hiroko, findsNothing);

    // Message opens it meanwhile, and it shows while it is open.
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('contact-profile-hiroko@localhost')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-message')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    expect(hiroko, findsOneWidget);

    await tester.tap(find.byTooltip('Chats'));
    await tester.pumpAndSettle();
    expect(hiroko, findsNothing);

    // Shows at once, while on its way.
    repo.sendText('dm-hiroko', 'Hello').ignore();
    await tester.pumpAndSettle();
    expect(hiroko, findsOneWidget);
    repo.dispose();
  });
}
