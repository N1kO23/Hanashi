import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/bubble_look.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/settings/chat_look_settings.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:hanashi/ui/widgets/emoji_text.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// The text style of the bubble showing [text].
  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.widget<EmojiText>(find.ancestor(of: find.text(text), matching: find.byType(EmojiText)).first).style!;

  /// The padding of the bubble showing [text].
  EdgeInsetsGeometry? paddingOf(WidgetTester tester, String text) => tester
      .widget<Container>(find.ancestor(of: find.text(text), matching: find.byType(Container)).first)
      .padding;

  test('values are kept to what can be chosen, in its steps', () {
    expect(BubbleLook.fit(17.4, BubbleLook.textSizes), 17);
    expect(BubbleLook.fit(99, BubbleLook.textSizes), BubbleLook.textSizes.max);
    expect(BubbleLook.fit(1.33, BubbleLook.lineSpacings), 1.35);
    expect(BubbleLook.fit(0, BubbleLook.paddings), BubbleLook.paddings.min);
    expect(BubbleLook.fit(double.nan, BubbleLook.paddings), isNull);
    expect(const BubbleLook().isDefault, isTrue);
    expect(const BubbleLook(textSize: 20).isDefault, isFalse);
  });

  test('each device keeps its own: stored here, the default stored as nothing', () async {
    ProviderContainer app() => ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    final first = app();
    expect(await first.read(bubbleLookProvider.future), const BubbleLook());
    const chosen = BubbleLook(textSize: 22, lineSpacing: 1.5, padding: 10);
    await first.read(bubbleLookProvider.notifier).set(chosen);
    first.dispose();

    final again = app();
    expect(await again.read(bubbleLookProvider.future), chosen);
    await again.read(bubbleLookProvider.notifier).set(const BubbleLook());
    again.dispose();
    expect(await db.valuesWithPrefix('chat.'), isEmpty);

    // Something stored that cannot be chosen: what can, or the default.
    await db.setValue('chat.text_size', '99');
    await db.setValue('chat.line_spacing', 'wide');
    final odd = app();
    expect(await odd.read(bubbleLookProvider.future), const BubbleLook(textSize: 28));
    odd.dispose();
  });

  testWidgets('bubbles take their text and padding from the look around them', (tester) async {
    final message = ChatMessage(envelope: Envelope.text(conv: 'c', from: 'kumiko@localhost', text: 'Sota!', now: testNow));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(testRepository())],
        child: MaterialApp(
          theme: buildHanashiTheme(),
          home: Scaffold(
            body: BubbleLookScope(
              look: const BubbleLook(textSize: 24, lineSpacing: 1.5, padding: 10),
              child: MessageBubble(message: message, isMine: false, senderName: 'Kumiko'),
            ),
          ),
        ),
      ),
    );
    final style = styleOf(tester, 'Sota!');
    expect((style.fontSize, style.height), (24, 1.5));
    expect(paddingOf(tester, 'Sota!'), const EdgeInsets.symmetric(horizontal: 14, vertical: 10));
  });

  testWidgets('Settings: the sample follows the sliders, which keep their choice; Reset goes back', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          chatRepositoryProvider.overrideWithValue(testRepository()),
        ],
        child: MaterialApp(
          theme: buildHanashiTheme(),
          home: const Scaffold(body: SingleChildScrollView(child: ChatLookSettings())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const sample = 'Sounds good! See you there.';
    expect(styleOf(tester, sample).fontSize, BubbleLook.defaultTextSize);
    expect(find.byKey(const Key('chat-look-reset')), findsNothing);

    // Moving the slider shows the size at once, and keeps it when let go.
    final textSize = tester.widget<Slider>(find.byKey(const Key('chat-text-size')));
    textSize.onChanged!(23.2);
    await tester.pump();
    expect(styleOf(tester, sample).fontSize, 23);
    expect(await tester.runAsync(() => db.getValue('chat.text_size')), isNull, reason: 'not while it moves');
    textSize.onChangeEnd!(23.2);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.getValue('chat.text_size')), '23.0');

    final padding = tester.widget<Slider>(find.byKey(const Key('chat-padding')));
    padding.onChanged!(12);
    padding.onChangeEnd!(12);
    await tester.pumpAndSettle();
    expect(paddingOf(tester, sample), const EdgeInsets.symmetric(horizontal: 16, vertical: 12));

    await tester.tap(find.byKey(const Key('chat-look-reset')));
    await tester.pumpAndSettle();
    expect(styleOf(tester, sample).fontSize, BubbleLook.defaultTextSize);
    expect(await tester.runAsync(() => db.valuesWithPrefix('chat.')), isEmpty);
    expect(find.byKey(const Key('chat-look-reset')), findsNothing);
  });
}
