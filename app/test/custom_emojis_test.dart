import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/custom_emojis.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/emojis/custom_emoji_picker.dart';
import 'package:hanashi/ui/emojis/emoji_suggestions.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:hanashi/ui/widgets/emoji_text.dart';
import 'package:hanashi/ui/widgets/format.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sticker_packs.dart';
import 'support/test_app.dart';

MediaRef _picture(int n) => MediaRef(
  hash: 'sha256:${'$n'.padLeft(64, '0')}',
  size: 100,
  mime: 'image/png',
  width: 128,
  height: 128,
  key: 'a2V5',
);

/// Made-up pictures (see `syntheticSticker`), standing in for those of
/// custom emojis.
class _WithPictures extends MockChatRepository {
  _WithPictures() : super(latency: Duration.zero, autoReply: false, now: testNow);

  static final files = <String, File>{};

  @override
  Future<File?> mediaFile(MediaRef media, {void Function(double progress)? onProgress}) async => files[media.hash];
}

void main() {
  setUpAll(loadRealFonts);

  late Directory pictures;
  setUpAll(() {
    pictures = Directory.systemTemp.createTempSync('hanashi_emoji_pictures_');
    for (var n = 1; n <= 4; n++) {
      _WithPictures.files[_picture(n).hash] = File('${pictures.path}/$n.png')..writeAsBytesSync(syntheticSticker(n));
    }
  });
  tearDownAll(() => pictures.delete(recursive: true));

  String typed(WidgetTester tester, Finder field) => tester.widget<TextField>(field).controller!.text;

  Future<void> openClubRoom(WidgetTester tester, MockChatRepository repo) async {
    SharedPreferences.setMockInitialValues({}); // For the emoji tab, which opens first.
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
  }

  group('words', () {
    test('a name from a file, made free of those taken', () {
      expect(
        [
          for (final path in [
            '/a/Kumiko Smile!.png',
            r'C:\x\über-cool.webp',
            '/a/a.png',
            '/a/.png',
            '/a/${'x' * 40}.gif',
          ])
            emojiNameFromFile(path),
        ],
        ['kumiko_smile', 'ber_cool', 'emoji', 'png', 'x' * 32],
      );
      expect(freeEmojiName('cat', {'dog'}), 'cat');
      expect(freeEmojiName('cat', {'cat', 'cat_2'}), 'cat_3');
      expect(freeEmojiName('x' * 32, {'x' * 32}), '${'x' * 30}_2');
    });

    test('how many emoji a text is counts the custom ones it carries', () {
      expect(
        [
          for (final text in [':cat:', ':cat: 😂 :cat:', ':cat::cat:', ':cat: hi', ':owl:', ':cat:dog:'])
            emojiOnlyCount(text, custom: {'cat', 'dog'}),
        ],
        [1, 3, 2, null, null, null],
      );
    });

    test('suggestions: custom ones beginning with what is typed first, then the picker\'s by a word', () {
      final custom = {'kumiko_smile': _picture(1), 'akemi': _picture(2), 'smiley_kumiko': _picture(3)};
      List<String> names(String query) => [for (final s in suggestEmojis(query, custom, max: 8)) s.name];
      expect(names('kumiko').take(2), ['kumiko_smile', 'smiley_kumiko']);
      expect(names('KUM').first, 'kumiko_smile', reason: 'written in capitals');
      expect(names('joy').take(2), ['face with tears of joy', 'cat face with tears of joy']);
      expect(names('tears_of').first, 'face with tears of joy');
      expect(suggestEmojis('joy', const {}).first.text, '😂');
      expect(suggestEmojis('akemi', custom).first.text, ':akemi: ');
      expect(typedEmojiName.firstMatch('Hi :ka')?[1], 'ka');
      for (final text in ['Hi :k', 'at 12:30', 'Hi:ka', 'Hi :ka:', 'Hi :ka ']) {
        expect(typedEmojiName.hasMatch(text), isFalse, reason: text);
      }
    });

    test("a group's change of emojis, in words", () {
      final (cat, dog) = (_picture(1), _picture(2));
      String said(Map<String, MediaRef> before, Map<String, MediaRef> after) => describeGroupChange(
        Envelope(
          id: newUlid(),
          conv: 'c',
          from: 'kumiko@b',
          ts: 0,
          type: Envelope.membershipType,
          body: emojiChangeLine(before, after)!,
        ),
        me: 'sota@b',
        nameOf: (id) => 'Kumiko',
      );
      expect(said({}, {'cat': cat}), 'Kumiko added the emoji :cat:');
      expect(said({'cat': cat}, {}), 'Kumiko removed the emoji :cat:');
      expect(said({'cat': cat}, {'kitty': cat}), 'Kumiko renamed the emoji :cat: to :kitty:');
      expect(said({'cat': cat}, {'cat': dog}), 'Kumiko changed the emoji :cat:');
      expect(said({'cat': cat}, {'dog': dog}), "Kumiko changed the group's emojis");
      expect(emojiChangeLine({'cat': cat}, {'cat': cat}), isNull);
      expect(emojiChangeLine({}, {'cat': cat})!['picture'], cat.toJson());
    });
  });

  testWidgets('text shows the custom emojis it carries, as large as its letters; not in a link', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(testRepository())],
        child: MaterialApp(
          home: Scaffold(
            body: EmojiText(
              'Hi :cat: :owl: https://example.com/:cat: :cat:',
              style: const TextStyle(fontSize: 16),
              emojis: {'cat': _picture(1)},
              onLink: (_) {},
              onEmoji: (name, _) => tapped.add(name),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final shown = find.byKey(const ValueKey('custom-emoji-cat'));
    expect(shown, findsNWidgets(2));
    expect(tester.getSize(shown.first), const Size(20, 20));
    final text = tester.widget<RichText>(find.byType(RichText).first).text.toPlainText();
    expect(text, allOf(contains(':owl:'), contains('https://example.com/:cat:')));
    await tester.tap(shown.first);
    expect(tapped, ['cat']);
  });

  testWidgets('a custom emoji by itself is large; tapped, it can be added to the user\'s own', (tester) async {
    final repo = testRepository();
    addTearDown(repo.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildHanashiTheme(),
          home: Scaffold(
            body: MessageBubble(
              message: ChatMessage(
                envelope: Envelope.text(
                  conv: 'c',
                  from: 'kumiko@localhost',
                  text: ':cat:',
                  emojis: {'cat': _picture(1)},
                  now: testNow,
                ),
              ),
              isMine: false,
              senderName: 'Kumiko',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('big-emoji')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('custom-emoji-cat'))), const Size(60, 60));

    await tester.tap(find.byKey(const ValueKey('custom-emoji-cat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('custom-emoji-info')), findsOneWidget);
    await tester.tap(find.byKey(const Key('keep-emoji')));
    await tester.pumpAndSettle();
    expect(typed(tester, find.byKey(const Key('emoji-name'))), 'cat');
    await tester.tap(find.byKey(const Key('emoji-name-save')));
    await tester.pumpAndSettle();
    expect(find.text('Added :cat: to your emojis'), findsOneWidget);
    final mine = (await tester.runAsync(() => repo.watchEmojis().first))!;
    expect(mine['cat']?.hash, _picture(1).hash);

    // Once the user has it, it says so.
    await tester.tap(find.byKey(const ValueKey('custom-emoji-cat')));
    await tester.pumpAndSettle();
    expect(find.text('In your emojis'), findsOneWidget);
    expect(find.byKey(const Key('keep-emoji')), findsNothing);
  });

  testWidgets('typing :name suggests emojis; Enter or Tab writes one, Escape closes them; the message carries it', (
    tester,
  ) async {
    final repo = testRepository();
    addTearDown(repo.dispose);
    await repo.changeEmojis((_) => {'kumiko_smile': _picture(1), 'akemi': _picture(2)});
    await openClubRoom(tester, repo);
    final field = find.byKey(const Key('composer-field'));
    final suggestions = find.byKey(const Key('emoji-suggestions'));

    await tester.enterText(field, 'Hi :ku');
    await tester.pump();
    expect(find.byKey(const ValueKey('emoji-suggestion-kumiko_smile')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(typed(tester, field), 'Hi :kumiko_smile: ');
    expect(suggestions, findsNothing);

    // The picker's emoji too, by a word of their name.
    await tester.enterText(field, 'Hi :kumiko_smile: :joy');
    await tester.pump();
    expect(find.byKey(const ValueKey('emoji-suggestion-face with tears of joy')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(suggestions, findsNothing);
    await tester.enterText(field, 'Hi :kumiko_smile: :joy_');
    await tester.pump();
    expect(suggestions, findsNothing, reason: 'closed until another is written');
    await tester.enterText(field, 'Hi :kumiko_smile: ');
    await tester.pump();
    await tester.enterText(field, 'Hi :kumiko_smile: :tears');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final second = suggestEmojis('tears', const {})[1].text;
    expect(typed(tester, field), 'Hi :kumiko_smile: $second');

    // Sent with the picture it shows.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final sent = (await tester.runAsync(() => repo.watchMessages('club').first))!.last;
    expect((sent.envelope.text, sent.envelope.emojis.keys.join()), ('Hi :kumiko_smile: $second', 'kumiko_smile'));
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byKey(const ValueKey('custom-emoji-kumiko_smile')),
      ),
      findsOneWidget,
    );
  });

  testWidgets("the custom tab: the group's and the user's own; made from an image, renamed, removed, kept", (
    tester,
  ) async {
    final repo = testRepository();
    addTearDown(repo.dispose);
    String? picked = '/somewhere/Kumiko Smile!.png';
    final written = <String>[];
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildHanashiTheme(),
          home: Scaffold(
            body: CustomEmojiPicker(
              height: 600,
              conversationId: 'club',
              onEmoji: written.add,
              pickImage: () async => picked,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final name = find.byKey(const Key('emoji-name'));
    final save = find.byKey(const Key('emoji-name-save'));
    expect(find.text('Club Room'), findsOneWidget);
    expect(find.textContaining('Anyone in it can add one'), findsOneWidget);
    expect(find.textContaining('write :its_name: in any chat'), findsOneWidget);

    // Made from an image, named after its file.
    await tester.tap(find.byKey(const Key('add-my-emoji')));
    await tester.pumpAndSettle();
    expect(typed(tester, name), 'kumiko_smile');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Added :kumiko_smile:'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-emoji-kumiko_smile')));
    expect(written, ['kumiko_smile']);

    // Renamed; what a name cannot have is left out as it is typed.
    await tester.longPress(find.byKey(const ValueKey('my-emoji-kumiko_smile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emoji-action-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(name, 'Kumiko Grin!');
    await tester.pump();
    expect(typed(tester, name), 'kumiko_grin');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-emoji-kumiko_grin')), findsOneWidget);

    // One of the group's: a line says so in the chat.
    picked = '/somewhere/a.png';
    await tester.tap(find.byKey(const Key('add-group-emoji')));
    await tester.pumpAndSettle();
    expect(typed(tester, name), 'emoji');
    await tester.enterText(name, 'kumiko_grin');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-emoji-kumiko_grin')), findsOneWidget);
    final line = (await tester.runAsync(() => repo.watchMessages('club').first))!.last.envelope;
    expect(describeGroupChange(line, me: repo.me, nameOf: (id) => id), 'You added the emoji :kumiko_grin:');

    // The user's own of that name is the group's here: tapping it writes nothing.
    await tester.tap(find.byKey(const ValueKey('my-emoji-kumiko_grin')));
    await tester.pumpAndSettle();
    expect(written, ['kumiko_smile']);
    expect(find.textContaining("Here :kumiko_grin: is Club Room's own"), findsOneWidget);

    // Removed, then back with Undo.
    await tester.longPress(find.byKey(const ValueKey('my-emoji-kumiko_grin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emoji-action-remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-emoji-kumiko_grin')), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-emoji-kumiko_grin')), findsOneWidget);

    // The group's added to the user's own, under a name not taken; a taken
    // one is refused.
    await tester.longPress(find.byKey(const ValueKey('group-emoji-kumiko_grin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emoji-action-keep')));
    await tester.pumpAndSettle();
    expect(typed(tester, name), 'kumiko_grin_2');
    await tester.enterText(name, 'kumiko_grin');
    await tester.pump();
    expect(find.text('There is already a :kumiko_grin:'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(name, 'grin');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final group = (await tester.runAsync(() => repo.watchEmojis(conversationId: 'club').first))!;
    final mine = (await tester.runAsync(() => repo.watchEmojis().first))!;
    expect(mine.keys.toSet(), {'kumiko_grin', 'grin'});
    expect(mine['grin']!.hash, group['kumiko_grin']!.hash);
  });

  testWidgets('phone: custom emojis in a group, and their tab', (tester) async {
    final repo = _WithPictures();
    addTearDown(repo.dispose);
    await repo.changeEmojis((_) => {'akemi_wave': _picture(1), 'kumiko_smile': _picture(2), 'hiroko_ok': _picture(3)});
    await repo.changeEmojis((_) => {'club_cheer': _picture(4)}, conversationId: 'club');
    SharedPreferences.setMockInitialValues({});
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    // Decoded first (real I/O), so that they show as soon as they are built.
    await tester.runAsync(() async {
      final context = tester.element(find.byType(Scaffold).first);
      for (final file in _WithPictures.files.values) {
        await precacheImage(FileImage(file), context);
      }
    });
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('composer-field'));
    for (final text in ['Morning :akemi_wave: ready for practice? :club_cheer:', ':kumiko_smile:']) {
      await tester.enterText(field, text);
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('expression-tab-custom')));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_custom_emojis.png'));
  });
}
