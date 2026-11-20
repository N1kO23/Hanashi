import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';

import 'support/test_app.dart';

/// Notes where the user was said to be typing.
class _Typing extends MockChatRepository {
  _Typing() : super(latency: Duration.zero, autoReply: false, now: testNow);

  final sent = <String>[];

  @override
  void sendTyping(String conversationId) => sent.add(conversationId);
}

void main() {
  testWidgets('others can be kept from seeing that the user is typing', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = _Typing();
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(repo, overrides: [databaseProvider.overrideWithValue(db)]));
    await tester.pumpAndSettle();
    Future<void> type(String text) async {
      await tester.enterText(find.byKey(const Key('composer-field')), text);
      await tester.pump();
    }

    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await type('On my w');
    expect(repo.sent, ['club']);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final setting = find.byKey(const Key('typing-notifications'));
    await tester.scrollUntilVisible(
      setting,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(setting);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(setting).value, isTrue);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    // Saved outside the test's clock.
    expect(await tester.runAsync(() => db.getValue('privacy.typing')), 'false');
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(setting).value, isFalse);

    await tester.tap(find.byIcon(Icons.sms_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await type('On my way');
    await type('On my way!');
    expect(repo.sent, ['club'], reason: 'nothing more was sent');
    // Seeing others type does not depend on it.
    repo.setTyping('club', {'kumiko@localhost'});
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Kumiko is typing...'), findsOneWidget);
    repo.setTyping('club', {});
    await tester.pumpAndSettle();
  });
}
