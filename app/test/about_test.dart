import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/settings/about_settings.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:material_ui/material_ui.dart';

import 'support/test_app.dart';

ServerInfo _server({String? source}) => ServerInfo.fromJson({
  'host': 'example.org',
  'version': '0.9.1',
  'registration': 'open',
  'maxUploadBytes': 1,
  'source': ?source,
});

void main() {
  late List<Uri> opened;

  /// Settings, scrolled to its About section.
  Future<void> openAbout(WidgetTester tester, {ServerInfo? server}) async {
    opened = [];
    await setSurfaceSize(tester, const Size(1200, 800));
    final repository = testRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      testApp(
        repository,
        overrides: <Override>[
          appVersionProvider.overrideWith((ref) async => '0.9.1 (45)'),
          serverInfoProvider.overrideWith((ref) async => server),
          openLinkProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-licenses')),
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
  }

  test("the license the app carries is the repository's", () {
    expect(File('assets/LICENSE').readAsStringSync(), File('../LICENSE').readAsStringSync());
  });

  testWidgets("Settings says what the app is, its license, and where its and the server's source is", (tester) async {
    await openAbout(tester, server: _server(source: 'https://git.example.org/hanashi'));

    final app = find.byKey(const Key('about-app'));
    expect(find.descendant(of: app, matching: find.text('Hanashi 0.9.1 (45)')), findsOneWidget);
    expect(
      find.descendant(of: app, matching: find.textContaining('GNU Affero General Public License, version 3')),
      findsOneWidget,
    );
    expect(find.descendant(of: app, matching: find.textContaining('no warranty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('about-source')));
    await tester.pumpAndSettle();
    expect(opened, [hanashiSource]);

    final server = find.byKey(const Key('about-server'));
    await tester.ensureVisible(server);
    expect(
      find.descendant(
        of: server,
        matching: find.text('Hanashi server 0.9.1. Its source code: https://git.example.org/hanashi'),
      ),
      findsOneWidget,
    );
    await tester.tap(server);
    await tester.pumpAndSettle();
    expect(opened.last, Uri.parse('https://git.example.org/hanashi'));
  });

  testWidgets('a server that does not say where its source is, says so', (tester) async {
    await openAbout(tester, server: _server());
    final server = find.byKey(const Key('about-server'));
    await tester.ensureVisible(server);
    expect(
      find.descendant(of: server, matching: find.textContaining('It does not say where its source code is')),
      findsOneWidget,
    );
    await tester.tap(server);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets("the licenses start with Hanashi's own, the AGPL", (tester) async {
    await openAbout(tester);
    expect(find.byKey(const Key('about-server')), findsNothing);
    await tester.tap(find.byKey(const Key('about-licenses')));
    await tester.pumpAndSettle();

    final page = find.byType(LicensePage);
    expect(page, findsOneWidget);
    final hanashi = find.descendant(of: page, matching: find.text('Hanashi'));
    // The page's heading, and the first package listed.
    expect(hanashi, findsWidgets);
    await tester.tap(hanashi.last);
    await tester.pumpAndSettle();
    expect(find.textContaining('GNU AFFERO GENERAL PUBLIC LICENSE'), findsWidgets);
    expect(find.textContaining('Version 3, 19 November 2007'), findsWidgets);
  });
}
