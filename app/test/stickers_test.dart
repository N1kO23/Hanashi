import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/data/packs/sticker_pack.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/media/gif_view.dart';
import 'package:hanashi/ui/stickers/sticker_picker.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sticker_packs.dart';
import 'support/test_app.dart';

const _hash = 'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

void main() {
  setUpAll(loadRealFonts);

  late Directory files;
  late File pack;
  setUpAll(() {
    files = Directory.systemTemp.createTempSync('hanashi_sticker_tests_');
    pack = syntheticStickerPack(files);
  });
  tearDownAll(() => files.delete(recursive: true));

  /// A repository whose user keeps the test pack.
  Future<MockChatRepository> withPack(WidgetTester tester) async {
    final repo = testRepository();
    addTearDown(repo.dispose);
    await tester.runAsync(() => repo.importStickerPack(pack.path));
    return repo;
  }

  Future<MockChatRepository> openClubRoom(WidgetTester tester, [MockChatRepository? repository]) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final repo = repository ?? await withPack(tester);
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    return repo;
  }

  Future<void> openStickers(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({}); // For the emoji tab, which opens first.
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('expression-tab-sticker')));
    await tester.pumpAndSettle();
  }

  Future<StickerRef> lastSent(WidgetTester tester, MockChatRepository repo) async {
    final chats = (await tester.runAsync(() => repo.watchConversations().first))!;
    final club = chats.firstWhere((c) => c.title == 'Club Room').conversation.id;
    final messages = (await tester.runAsync(() => repo.watchMessages(club).first))!;
    return messages.last.envelope.sticker!;
  }

  Widget host(ChatMessage message, {MockChatRepository? repo}) => ProviderScope(
    overrides: [chatRepositoryProvider.overrideWithValue(repo ?? testRepository())],
    child: MaterialApp(
      theme: buildHanashiTheme(),
      home: Scaffold(body: MessageBubble(message: message, isMine: false, senderName: 'Kumiko')),
    ),
  );

  testWidgets('the sticker tab lists the packs the user keeps; a tap sends one as its picture, with its pack', (
    tester,
  ) async {
    final repo = await openClubRoom(tester);
    await openStickers(tester);
    expect(find.text('Test pack'), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-test-pack-01')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sticker-test-pack-03')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sticker-picker')), findsNothing, reason: 'the panel closes');
    final sent = find.byKey(const ValueKey('sticker-test-pack:03'));
    expect(sent, findsOneWidget);
    expect(tester.getSize(sent), const Size(160, 160));
    // Without a bubble around it.
    final bubble = find.byWidgetPredicate(
      (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == HanashiPalette.light.outgoingBubble,
    );
    expect(find.ancestor(of: sent, matching: bubble), findsNothing);

    // Its picture goes with it, so whoever gets it sees it, pack or not.
    final sticker = await lastSent(tester, repo);
    expect((sticker.isNamed, sticker.media!.mime, sticker.media!.width), (false, 'image/png', 128));
    final source = sticker.source!;
    expect((source.pack, source.id, source.title, source.archive != null), ('test-pack', '03', 'Test pack', true));
  });

  testWidgets("a reply's quote sits above it", (tester) async {
    final reply = ReplyRef(id: newUlid(), from: 'sota@localhost', text: 'Ready?');
    await tester.pumpWidget(host(ChatMessage(
      envelope: Envelope.sticker(
        conv: 'c',
        from: 'kumiko@localhost',
        sticker: const StickerRef.media(MediaRef(hash: _hash, size: 1, mime: 'image/png', key: 'a2V5')),
        replyTo: reply,
        now: testNow,
      ),
      replyTo: reply,
    )));
    await tester.pumpAndSettle();
    final sticker = tester.getRect(find.byKey(const ValueKey('sticker-$_hash')));
    expect(tester.getRect(find.byKey(const Key('reply-quote'))).bottom, lessThanOrEqualTo(sticker.top));
  });

  testWidgets("one named from a pack the user lacks says so; one sent as its picture shows, whatever packs they have", (
    tester,
  ) async {
    await tester.pumpWidget(host(ChatMessage(
      envelope: Envelope.sticker(
        conv: 'c',
        from: 'kumiko@localhost',
        sticker: const StickerRef.named(pack: 'a-pack-i-lack', id: '01'),
        now: testNow,
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unknown-sticker')), findsOneWidget);
    expect(find.text('Sticker'), findsOneWidget);
    expect(find.byTooltip("From a sticker pack you don't have"), findsOneWidget);

    const own = MediaRef(hash: _hash, size: 30000, mime: 'image/png', width: 512, height: 512, key: 'a2V5');
    await tester.pumpWidget(host(ChatMessage(
      envelope: Envelope.sticker(
        conv: 'c',
        from: 'kumiko@localhost',
        sticker: const StickerRef.media(own, source: StickerSource(pack: 'a-pack-i-lack', id: '01')),
        now: testNow,
      ),
    )));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('sticker-a-pack-i-lack:01')), matching: find.byType(UploadedImage)),
      findsOneWidget,
    );
    // Tapped: where it is from; the pack did not come with it.
    await tester.tap(find.byKey(const ValueKey('sticker-a-pack-i-lack:01')));
    await tester.pumpAndSettle();
    expect(find.text('From a sticker pack'), findsOneWidget);
    expect(find.text("Its pack didn't come with it."), findsOneWidget);
    expect(find.byKey(const Key('add-sticker-pack')), findsNothing);
  });

  testWidgets('a sticker from a pack the user lacks offers the pack; adding it makes it theirs', (tester) async {
    final repo = testRepository();
    addTearDown(repo.dispose);
    final archive = MediaRef(hash: 'sha256:${'a' * 64}', size: 1000, mime: 'application/zip', key: 'a2V5');
    repo.packFiles[archive.hash] = pack.path;
    const picture = MediaRef(hash: _hash, size: 1000, mime: 'image/png', width: 128, height: 128, key: 'a2V5');
    await tester.pumpWidget(host(
      ChatMessage(
        envelope: Envelope.sticker(
          conv: 'c',
          from: 'kumiko@localhost',
          sticker: StickerRef.media(
            picture,
            source: StickerSource(pack: 'test-pack', id: '03', title: 'Test pack', archive: archive),
          ),
          now: testNow,
        ),
      ),
      repo: repo,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sticker-test-pack:03')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sticker-pack-info')), findsOneWidget);
    expect(find.text('From Test pack'), findsOneWidget);
    expect(find.text('Add its pack to send its stickers too.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-sticker-pack')));
    await tester.pumpAndSettle();
    expect(find.text('In your sticker packs'), findsOneWidget);
    expect(find.byKey(const Key('add-sticker-pack')), findsNothing);
    expect(find.text('Added Test pack to your sticker packs'), findsOneWidget);
    final kept = (await tester.runAsync(() => repo.watchStickerPacks().first))!;
    expect([for (final p in kept) (p.id, p.stickers.length)], [('test-pack', 8)]);
  });

  testWidgets('a pack goes from its menu; a file of one the user has replaces it if they say so', (tester) async {
    final repo = await withPack(tester);
    String? picked;
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildHanashiTheme(),
          home: Scaffold(
            body: StickerPicker(height: 600, onSticker: (_) {}, pickPackFile: () async => picked),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Test pack'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pack-menu-test-pack')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove pack…'));
    await tester.pumpAndSettle();
    expect(find.text('Remove "Test pack"?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Test pack'), findsNothing);
    expect(find.textContaining('tap one to add its pack'), findsOneWidget);

    // Picking no file adds nothing; a pack's file adds it.
    await tester.tap(find.byKey(const Key('import-sticker-pack')));
    await tester.pumpAndSettle();
    expect(find.text('Test pack'), findsNothing);
    picked = pack.path;
    await tester.tap(find.byKey(const Key('import-sticker-pack')));
    await tester.pumpAndSettle();
    expect(find.text('Test pack'), findsOneWidget);
    expect(find.text('Added Test pack to your sticker packs'), findsOneWidget);

    // One the user has: only if they say so.
    final newer = File('${files.path}/newer.zip')
      ..writeAsBytesSync(syntheticStickerPackBytes(title: 'Test pack 2', count: 3, version: 2));
    picked = newer.path;
    await tester.tap(find.byKey(const Key('import-sticker-pack')));
    await tester.pumpAndSettle();
    expect(find.text('Replace "Test pack"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Test pack'), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-sticker-pack')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(find.text('Test pack 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-test-pack-04')), findsNothing);

    // Anything else says what is wrong with it.
    picked = (File('${files.path}/notes.zip')..writeAsStringSync('not a zip')).path;
    await tester.tap(find.byKey(const Key('import-sticker-pack')));
    await tester.pumpAndSettle();
    expect(find.text('This is not a sticker pack: it has no pack.json'), findsOneWidget);
  });

  testWidgets('my stickers: a long press keeps one (as its picture) or lets it go, with Undo; an image makes one', (
    tester,
  ) async {
    final repo = await withPack(tester);
    Future<List<StickerRef>> mine() async => (await tester.runAsync(() => repo.watchSavedStickers().first))!;
    String? picked = '/somewhere/cat.png';
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: buildHanashiTheme(),
          home: Scaffold(
            body: StickerPicker(height: 600, onSticker: (_) {}, pickImage: () async => picked),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('long-press any sticker'), findsOneWidget);

    const kept = StickerRef.named(pack: 'test-pack', id: '03');
    final keptTile = find.byKey(ValueKey('my-sticker-${kept.key}'));
    await tester.longPress(find.byKey(const ValueKey('sticker-test-pack-03')));
    await tester.pumpAndSettle();
    expect(find.text('Added to your stickers'), findsOneWidget);
    expect(keptTile, findsOneWidget);
    expect(find.textContaining('long-press any sticker'), findsNothing);
    // Kept as its picture: it stays if the pack goes.
    final keptOne = (await mine()).single;
    expect((keptOne.media != null, keptOne.source?.pack, keptOne), (true, 'test-pack', kept));

    // Let go from among the user's, then back with Undo.
    await tester.longPress(keptTile);
    await tester.pumpAndSettle();
    expect(keptTile, findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(keptTile, findsOneWidget);

    // Made from an image: first among them.
    await tester.tap(find.byKey(const Key('make-sticker')));
    await tester.pumpAndSettle();
    final made = await mine();
    expect((made.length, made.first.isNamed, made.first.source, made.last), (2, false, null, kept));
    expect(find.byKey(ValueKey('my-sticker-${made.first.key}')), findsOneWidget);
    // Picking no image makes none.
    picked = null;
    await tester.tap(find.byKey(const Key('make-sticker')));
    await tester.pumpAndSettle();
    expect(await mine(), hasLength(2));
  });

  testWidgets('a sticker in a chat is kept from its actions, and let go again', (tester) async {
    final repo = await openClubRoom(tester);
    Future<List<StickerRef>> mine() async => (await tester.runAsync(() => repo.watchSavedStickers().first))!;
    await openStickers(tester);
    await tester.tap(find.byKey(const ValueKey('sticker-test-pack-04')));
    await tester.pumpAndSettle();
    final sent = find.byKey(const ValueKey('sticker-test-pack:04'));
    await tester.longPress(sent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-saveSticker')));
    await tester.pumpAndSettle();
    expect(await mine(), [const StickerRef.named(pack: 'test-pack', id: '04')]);

    await tester.longPress(sent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-unsaveSticker')));
    await tester.pumpAndSettle();
    expect(await mine(), isEmpty);
  });

  testWidgets('a sticker of a pack the user removed says so, rather than sending nothing', (tester) async {
    final repo = await openClubRoom(tester);
    await openStickers(tester);
    await tester.runAsync(() => repo.removeStickerPack('test-pack'));
    await expectLater(repo.sendSticker('c', const StickerRef.named(pack: 'test-pack', id: '01')), throwsA(isA<StickerPackMissing>()));
  });

  testWidgets('phone: a sticker sent, and the sticker tab', (tester) async {
    final repo = await withPack(tester);
    final stickers = (await tester.runAsync(() => repo.watchStickerPacks().first))!.single.stickers;
    await openClubRoom(tester, repo);
    // Decoded first (real I/O), at the sizes they show at (the picker's
    // cells, a sent sticker), so that they show as soon as they are built.
    await tester.runAsync(() async {
      final context = tester.element(find.byType(Scaffold).first);
      for (final sticker in stickers) {
        await precacheImage(ResizeImage(FileImage(File(sticker.path!)), width: 96), context);
      }
      await precacheImage(ResizeImage(FileImage(File(stickers[1].path!)), width: 160), context);
    });
    await openStickers(tester);
    await tester.tap(find.byKey(const ValueKey('sticker-test-pack-02')));
    await tester.pumpAndSettle();
    await openStickers(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_stickers.png'));
  });
}
