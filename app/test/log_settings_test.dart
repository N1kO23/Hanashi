import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/diagnostics/app_log.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';

import 'support/test_app.dart';

void main() {
  tearDown(AppLog.instance.reset);

  testWidgets('the log detail is chosen in Settings, and the log can be read, copied and cleared', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    final level = find.byKey(const Key('log-level'));
    await tester.scrollUntilVisible(
      level,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    expect(find.descendant(of: level, matching: find.textContaining('Normal.')), findsOneWidget);
    await tester.ensureVisible(level);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log detail'));
    await tester.pumpAndSettle();
    expect(find.text('Normal (now)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('log-level-debug')));
    await tester.pumpAndSettle();
    expect(AppLog.instance.level, LogLevel.debug);
    expect(find.descendant(of: level, matching: find.textContaining('Detailed.')), findsOneWidget);

    const Log('sync').debug('Event 7: message in c1');
    await tester.tap(find.byKey(const Key('log-view')));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('log-dialog'));
    expect(find.descendant(of: dialog, matching: find.textContaining('I account: Log level debug')), findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('D sync: Event 7: message in c1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('log-copy')));
    await tester.pumpAndSettle();
    expect(copied.single, allOf(contains('Log level debug'), contains('Event 7'), endsWith('\n')));
    expect(find.text('Copied'), findsOneWidget);

    await tester.tap(find.byKey(const Key('log-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('log-clear-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing logged yet'), findsOneWidget);
    expect(await AppLog.instance.read(), isEmpty);
  });
}
