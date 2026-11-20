import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:hanashi/ui/widgets/emoji_text.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

const _hash =
    'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
const _me = 'sota@localhost';
const _them = 'kumiko@localhost';

ChatMessage _text(
  String from,
  String text, {
  DeliveryState state = DeliveryState.sent,
}) => ChatMessage(
  envelope: Envelope.text(conv: 'c', from: from, text: text, now: testNow),
  state: state,
);

ChatMessage _media(MessageType type, MediaRef ref, {String? caption}) =>
    ChatMessage(
      envelope: Envelope.media(
        conv: 'c',
        from: _them,
        type: type,
        media: ref,
        caption: caption,
        now: testNow,
      ),
    );

Widget _host(List<Widget> children) => ProviderScope(
  overrides: [chatRepositoryProvider.overrideWithValue(testRepository())],
  child: MaterialApp(
    theme: buildHanashiTheme(),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: HanashiPalette.light.chatBackground,
      body: ListView(children: children),
    ),
  ),
);

void main() {
  testWidgets('incoming group: only the first bubble shows name and avatar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        MessageBubble(
          message: _text(_them, 'one'),
          isMine: false,
          senderName: 'Kumiko',
          isLastInGroup: false,
        ),
        MessageBubble(
          message: _text(_them, 'two'),
          isMine: false,
          senderName: 'Kumiko',
          isFirstInGroup: false,
        ),
      ]),
    );
    expect(find.text('Kumiko'), findsOneWidget);
    expect(find.text('K'), findsOneWidget); // Avatar initial.
    expect(find.text('18:30'), findsOneWidget); // Time only on the last bubble.
  });

  testWidgets('outgoing pending and failed states', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _host([
        MessageBubble(
          message: _text(_me, 'sending', state: DeliveryState.pending),
          isMine: true,
          senderName: 'Me',
        ),
        MessageBubble(
          message: _text(_me, 'oops', state: DeliveryState.failed),
          isMine: true,
          senderName: 'Me',
          onRetry: () => retried = true,
        ),
      ]),
    );
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('a message this device has no keys for yet waits for them', (
    tester,
  ) async {
    final placeholder = ChatMessage(
      envelope: Envelope(
        id: newUlid(),
        conv: 'c',
        from: _them,
        ts: testNow.millisecondsSinceEpoch,
        type: Envelope.encryptedType,
        body: const {},
      ),
    );
    await tester.pumpWidget(
      _host([
        MessageBubble(
          message: placeholder,
          isMine: false,
          senderName: 'Kumiko',
        ),
      ]),
    );
    expect(find.text('Waiting for keys...'), findsOneWidget);
    expect(find.byIcon(Icons.lock_clock_outlined), findsOneWidget);
  });

  testWidgets('file bubble shows name and size', (tester) async {
    await tester.pumpWidget(
      _host([
        MessageBubble(
          message: _media(
            MessageType.file,
            const MediaRef(
              hash: _hash,
              size: 284331,
              mime: 'application/pdf',
              name: 'report.pdf',
            ),
          ),
          isMine: false,
          senderName: 'Kumiko',
        ),
      ]),
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('278 KB'), findsOneWidget);
  });

  testWidgets('an audio file shows its length and plays in the viewer', (tester) async {
    await tester.pumpWidget(
      _host([
        MessageBubble(
          message: _media(
            MessageType.file,
            const MediaRef(hash: _hash, size: 3145728, mime: 'audio/mpeg', name: 'song.mp3', durationMs: 204000),
          ),
          isMine: false,
          senderName: 'Kumiko',
        ),
      ]),
    );
    expect(find.text('3:24 · 3.0 MB'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.tap(find.text('song.mp3'));
    await tester.pumpAndSettle();
    // Opened in the viewer, as audio (the demo has no files to play).
    expect(find.text('Could not load the audio: It is not available.'), findsOneWidget);
    expect(find.text('song.mp3'), findsOneWidget);
  });

  testWidgets('bubble variants golden', (tester) async {
    await tester.runAsync(loadRealFonts);
    await setSurfaceSize(tester, const Size(480, 900));
    await tester.pumpWidget(
      _host([
        MessageBubble(
          message: _text(_them, 'Sota!'),
          isMine: false,
          senderName: 'Kumiko',
          isLastInGroup: false,
        ),
        MessageBubble(
          message: _text(
            _them,
            'There is a new cafe near the station and I want to try their parfait.',
          ),
          isMine: false,
          senderName: 'Kumiko',
          isFirstInGroup: false,
        ),
        MessageBubble(
          message: _text(_me, 'Sounds good. After class?'),
          isMine: true,
          senderName: 'Sota',
        ),
        MessageBubble(
          message: _text(_me, 'Sending...', state: DeliveryState.pending),
          isMine: true,
          senderName: 'Sota',
          isFirstInGroup: false,
        ),
        MessageBubble(
          message: _media(
            MessageType.image,
            const MediaRef(
              hash: _hash,
              size: 512000,
              mime: 'image/jpeg',
              width: 1080,
              height: 1440,
            ),
          ),
          isMine: false,
          senderName: 'Kumiko',
        ),
        MessageBubble(
          message: _media(
            MessageType.video,
            const MediaRef(
              hash: _hash,
              size: 4200000,
              mime: 'video/mp4',
              width: 1280,
              height: 720,
              durationMs: 42000,
            ),
            caption: 'Practice run',
          ),
          isMine: false,
          senderName: 'Kumiko',
        ),
        MessageBubble(
          message: _media(
            MessageType.file,
            const MediaRef(
              hash: _hash,
              size: 284331,
              mime: 'application/pdf',
              name: 'weekly-report.pdf',
            ),
          ),
          isMine: false,
          senderName: 'Kumiko',
        ),
      ]),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/bubbles.png'),
    );
  });

  test('ordinary text never falls back to the emoji font', () {
    // It also has digits and a space: wherever the main font is missing
    // (Roboto on most Linux desktops), those would come out emoji-wide.
    final text = buildHanashiTheme().textTheme;
    for (final style in [text.bodyLarge, text.bodyMedium, text.bodySmall, text.titleMedium, text.labelLarge]) {
      expect(style!.fontFamilyFallback ?? const <String>[], isNot(contains('Noto Color Emoji')));
    }
  });

  testWidgets('one to three emoji by themselves are large, without a bubble', (tester) async {
    await tester.pumpWidget(
      _host([
        for (final text in ['😂', '👍🏽❤️', '🇫🇮 🎉 😂', '😂 nice', '😂😂😂😂'])
          MessageBubble(message: _text(_me, text), isMine: true, senderName: 'Sota'),
      ]),
    );
    expect(
      [
        for (final t in tester.widgetList<EmojiText>(find.byKey(const Key('big-emoji')))) (t.text, t.style!.fontSize),
      ],
      [('😂', 48.0), ('👍🏽❤️', 40.0), ('🇫🇮 🎉 😂', 32.0)],
    );
    // With other text, or more emoji: as usual.
    for (final text in ['😂 nice', '😂😂😂😂']) {
      final shown = tester.widget<EmojiText>(find.ancestor(of: find.text(text), matching: find.byType(EmojiText)));
      expect(shown.style!.fontSize, 18);
    }
  });
}
