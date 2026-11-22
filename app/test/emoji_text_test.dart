import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/chat_list/chat_list_screen.dart';
import 'package:hanashi/ui/widgets/emoji_text.dart';

import 'support/test_app.dart';

/// The parts of [span] in the emoji font, and the rest.
List<List<String>> parts(InlineSpan? span) {
  final emoji = <String>[], other = <String>[];
  for (final child in (span as TextSpan?)?.children?.cast<TextSpan>() ?? const <TextSpan>[]) {
    (child.style == emojiStyle ? emoji : other).add(child.text!);
  }
  return [emoji, other];
}

void main() {
  test('emoji go in the emoji font, whole; the text around them does not', () {
    expect(parts(emojiSpan('Hi 😂👍🏽 ❤️ 1️⃣ 🇫🇮 👨‍👩‍👧!')), [
      ['😂👍🏽', '❤️', '1️⃣', '🇫🇮', '👨‍👩‍👧'],
      ['Hi ', ' ', ' ', ' ', ' ', '!'],
    ]);
    // Digits, # and * are emoji only in a keycap, © and ❤ only when asked
    // to be (with U+FE0F); the emoji font has them too, as wide as emoji.
    expect(emojiSpan('Room #1, 2*3 © ❤ ok'), isNull);
  });

  test('how many emoji a text is, if nothing else', () {
    expect(
      [
        for (final text in ['😂', ' 👍🏽❤️ ', '👨‍👩‍👧 1️⃣', '🇫🇮🇫🇮🇫🇮', '😂 nice', '❤', '123', ''])
          emojiOnlyCount(text),
      ],
      [1, 2, 2, 3, null, null, null, null],
    );
  });

  testWidgets('emoji in colour as typed, in the message and in the chat list', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();

    const text = 'See you 👋';
    await tester.enterText(find.byKey(const Key('composer-field')), text);
    await tester.pump();
    final field = find.byKey(const Key('composer-field'));
    final typed = tester
        .widget<TextField>(field)
        .controller!
        .buildTextSpan(context: tester.element(field), withComposing: false);
    expect(parts(typed), [
      ['👋'],
      ['See you '],
    ]);

    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    final message = find.descendant(of: find.byType(MessageBubble), matching: find.text(text));
    expect(parts(tester.widget<Text>(message).textSpan), [
      ['👋'],
      ['See you '],
    ]);
    final preview = find.descendant(of: find.byType(ConversationTile), matching: find.textContaining(text));
    expect(parts(tester.widget<Text>(preview).textSpan).first, ['👋']);
  });
}
