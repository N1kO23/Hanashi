import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/data/remote/link_previews.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/media/gif_view.dart';
import 'package:hanashi/ui/media/media_viewer.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

/// Previews made up front; records which links were asked for.
class _Previews extends LinkPreviewFetcher {
  _Previews(this.drafts, {http.Client? client})
    : super(client: client ?? MockClient((_) async => http.Response('', 404)));

  final Map<String, LinkPreviewDraft> drafts;
  final asked = <String>[];

  @override
  Future<LinkPreviewDraft?> fetch(String address) async {
    asked.add(address);
    return drafts[address];
  }
}

const _video = LinkPreviewDraft(
  url: 'https://www.youtube.com/watch?v=abc',
  kind: LinkKind.video,
  title: 'A video',
  description: 'A channel',
  site: 'YouTube',
);

const _hash = 'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
const _gifHash = 'sha256:60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752';

const _pdf = LinkPreviewDraft(
  url: 'https://b.example/menu.pdf',
  kind: LinkKind.file,
  title: 'menu.pdf',
  mime: 'application/pdf',
  size: 2400000,
);

void main() {
  late MockChatRepository repository;
  late _Previews previews;
  late List<Uri> opened;

  Future<void> openClubRoom(WidgetTester tester, {AppDatabase? db, MockChatRepository? repo, _Previews? links}) async {
    repository = repo ?? testRepository();
    previews = links ?? _Previews({_video.url: _video, _pdf.url: _pdf});
    opened = [];
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(
      testApp(
        repository,
        linkPreviews: previews,
        overrides: [
          openLinkProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
          if (db != null) databaseProvider.overrideWithValue(db),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('composer-field')), text);
    await tester.pump();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
  }

  Future<LinkPreview?> lastSentLink() async => (await repository.watchMessages('club').first).last.envelope.link;

  /// [text] in a message (not in the chat list), to tap on.
  FinderBase<TextRangeContext> inMessage(String text) =>
      find.textRange.ofSubstring(text, descendentOf: find.byType(MessageBubble));

  Finder inCard(String text) => find.descendant(of: find.byKey(const Key('link-card')), matching: find.text(text));

  testWidgets('a link gets a preview before it is sent; the message shows it, and both open the link', (tester) async {
    await openClubRoom(tester);
    const text = 'Watch www.youtube.com/watch?v=abc tonight';
    await type(tester, text);
    // Once the user stops typing for a moment.
    expect(find.text('Making a preview...'), findsOneWidget);
    expect(previews.asked, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(previews.asked, [_video.url]);
    final bar = find.byKey(const Key('composer-link'));
    expect(find.descendant(of: bar, matching: find.text('YouTube')), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('A video')), findsOneWidget);

    await send(tester);
    expect(bar, findsNothing);
    final link = (await tester.runAsync(lastSentLink))!;
    expect((link.url, link.kind, link.title, link.description), (_video.url, LinkKind.video, 'A video', 'A channel'));
    expect(
      find.descendant(of: find.byType(MessageBubble), matching: find.byKey(const Key('link-card'))),
      findsOneWidget,
    );
    for (final line in ['YouTube', 'A video', 'A channel']) {
      expect(inCard(line), findsOneWidget);
    }

    // The card shows what the sender's app made of the link: the address
    // is shown first. The address in the text opens at once.
    await tester.tap(find.byKey(const Key('link-card')));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('open-link-dialog'));
    expect(find.descendant(of: dialog, matching: find.text('youtube.com')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text(_video.url)), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const Key('link-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-link-confirm')));
    await tester.pumpAndSettle();
    await tester.tapOnText(inMessage('www.youtube.com/watch?v=abc'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(_video.url), Uri.parse(_video.url)]);
    // Only links are links.
    await tester.tapOnText(inMessage('tonight'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
  });

  testWidgets("a link's picture opens in the viewer, which opens the link; a video's is for watching it", (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('hanashi_links_');
    addTearDown(() => dir.delete(recursive: true));
    final picture = File('${dir.path}/picture.jpg')..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 32)));
    const thumb = MediaRef(hash: _hash, size: 100, mime: 'image/jpeg', width: 64, height: 32);
    const page = LinkPreview(url: 'https://news.example/cats', title: 'Cats & dogs', site: 'Pet News', thumb: thumb);
    const video = LinkPreview(url: 'https://www.youtube.com/watch?v=abc', kind: LinkKind.video, thumb: thumb);
    opened = [];
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_Pictures(picture)),
          openLinkProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (final link in [page, video])
                  MessageBubble(
                    message: ChatMessage(
                      envelope: Envelope.text(conv: 'c', from: 'kumiko@localhost', text: link.url, link: link),
                    ),
                    isMine: false,
                    senderName: 'Kumiko',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('open-link-dialog'));

    await tester.tap(find.byKey(const Key('link-picture')));
    await tester.pumpAndSettle();
    final viewer = find.byType(MediaViewerScreen);
    expect(find.descendant(of: viewer, matching: find.text('Cats & dogs')), findsOneWidget);
    final shown = tester.widget<Image>(find.descendant(of: viewer, matching: find.byType(Image)));
    expect((shown.image as MemoryImage).bytes, picture.readAsBytesSync());
    // Only a picture the sender's app made: the link has the real thing.
    expect(find.byKey(const Key('viewer-download')), findsNothing);
    await tester.tap(find.byKey(const Key('viewer-open-link')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: dialog, matching: find.text(page.url)), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-link-confirm')));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(page.url)]);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);

    // Its play button is for watching it, on the site.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(find.descendant(of: dialog, matching: find.text(video.url)), findsOneWidget);
  });

  testWidgets('a GIF a link brings plays in place; a video plays in the viewer, not on the site', (tester) async {
    final dir = Directory.systemTemp.createTempSync('hanashi_links_');
    addTearDown(() => dir.delete(recursive: true));
    final picture = File('${dir.path}/picture.jpg')..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 32)));
    const thumb = MediaRef(hash: _hash, size: 100, mime: 'image/jpeg', width: 64, height: 32);
    final animation = File('${dir.path}/dance.gif')..writeAsBytesSync(img.encodeGif(img.Image(width: 64, height: 32)));
    const dance = LinkPreview(
      url: 'https://cdn.example/dance.gif',
      kind: LinkKind.gif,
      mime: 'image/gif',
      thumb: thumb,
      media: MediaRef(hash: _gifHash, size: 100, mime: 'image/gif', width: 64, height: 32),
    );
    const tweet = LinkPreview(
      url: 'https://fxtwitter.com/kumiko/status/1',
      kind: LinkKind.video,
      title: 'Kumiko (@kumiko)',
      site: 'FxTwitter',
      color: '#6363ff',
      thumb: thumb,
      media: MediaRef(hash: _hash, size: 5000, mime: 'video/mp4', width: 1280, height: 720, durationMs: 42000),
    );
    opened = [];
    await setSurfaceSize(tester, const Size(1200, 1600));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_NoVideos(picture, animation)),
          openLinkProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (final link in [dance, tweet])
                  MessageBubble(
                    key: Key(link.url),
                    message: ChatMessage(
                      envelope: Envelope.text(conv: 'c', from: 'kumiko@localhost', text: link.url, link: link),
                    ),
                    isMine: false,
                    senderName: 'Kumiko',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder within(String url, Finder finder) => find.descendant(of: find.byKey(Key(url)), matching: finder);

    // The GIF itself, playing; no button to play it.
    final shown = tester.widget<Image>(within(dance.url, find.byType(Image)));
    expect((shown.image as MemoryImage).bytes, animation.readAsBytesSync());
    expect(within(dance.url, find.byType(GifBadge)), findsOneWidget);
    expect(within(dance.url, find.byIcon(Icons.play_arrow_rounded)), findsNothing);

    // The video waits for a tap, with how long it is, in the site's colour.
    expect(within(tweet.url, find.text('0:42')), findsOneWidget);
    expect(
      tester.widgetList<Container>(within(tweet.url, find.byType(Container))).map((c) => c.color),
      contains(const Color(0xFF6363FF)),
    );
    await tester.tap(within(tweet.url, find.byIcon(Icons.play_arrow_rounded)));
    await tester.pumpAndSettle();
    final viewer = find.byType(MediaViewerScreen);
    expect(find.descendant(of: viewer, matching: find.text('Kumiko (@kumiko)')), findsOneWidget);
    expect(find.byKey(const Key('open-link-dialog')), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('pictures show large below the text, as videos do; only an icon small beside it', (tester) async {
    final dir = Directory.systemTemp.createTempSync('hanashi_links_');
    addTearDown(() => dir.delete(recursive: true));
    final picture = File('${dir.path}/picture.jpg')..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 64)));
    MediaRef square(int side) => MediaRef(hash: _hash, size: 100, mime: 'image/jpeg', width: side, height: side);
    final post = LinkPreview(
      url: 'https://fxtwitter.com/kumiko/status/2',
      title: 'Kumiko (@kumiko)',
      thumb: square(1280),
      media: square(1814),
    );
    // From before pictures went along as the site has them.
    final older = LinkPreview(url: 'https://news.example/cats', title: 'Cats', thumb: square(480));
    final forum = LinkPreview(url: 'https://forum.example/r/cats', title: 'r/cats', thumb: square(192));
    await setSurfaceSize(tester, const Size(1200, 1600));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(_Pictures(picture))],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (final link in [post, older, forum])
                  MessageBubble(
                    key: Key(link.url),
                    message: ChatMessage(
                      envelope: Envelope.text(conv: 'c', from: 'kumiko@localhost', text: link.url, link: link),
                    ),
                    isMine: false,
                    senderName: 'Kumiko',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Size shown(LinkPreview link) =>
        tester.getSize(find.descendant(of: find.byKey(Key(link.url)), matching: find.byKey(const Key('link-picture'))));

    for (final link in [post, older]) {
      // As wide as the card, and square as it is.
      expect(shown(link).width, greaterThan(250), reason: link.url);
      expect(shown(link).height, closeTo(shown(link).width, 1), reason: link.url);
    }
    expect(shown(forum), const Size(56, 56));
  });

  testWidgets('a draft shows that its GIF or video plays in the chat; a picture for the viewer does not', (
    tester,
  ) async {
    final picture = (bytes: img.encodeJpg(img.Image(width: 8, height: 8)), mime: 'image/jpeg', width: 8, height: 8);
    final still = LinkPreviewDraft(
      url: 'https://news.example/cats',
      kind: LinkKind.page,
      title: 'Cats',
      picture: picture,
      media: const LinkMediaFile(path: 'cats.jpg', mime: 'image/jpeg', size: 100),
    );
    final gif = LinkPreviewDraft(
      url: 'https://fxtwitter.com/kumiko/status/3',
      kind: LinkKind.gif,
      title: 'Kumiko (@kumiko)',
      picture: picture,
      media: const LinkMediaFile(path: 'dance.mp4', mime: 'video/mp4', size: 100),
    );
    await openClubRoom(tester, links: _Previews({still.url: still, gif.url: gif}));
    for (final (draft, plays) in [(still, false), (gif, true)]) {
      await type(tester, draft.url);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('composer-link')), findsOneWidget);
      expect(find.byKey(const Key('composer-link-media')), plays ? findsOneWidget : findsNothing, reason: draft.url);
    }
  });

  group('loading from the site what did not come with the message', () {
    late Directory dir;
    late File picture;
    late List<Uri> asked;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('hanashi_links_');
      picture = File('${dir.path}/picture.jpg')..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 36)));
      asked = [];
    });
    tearDown(() => dir.delete(recursive: true));
    const thumb = MediaRef(hash: _hash, size: 100, mime: 'image/jpeg', width: 1280, height: 720);
    final dance = img.encodeGif(img.Image(width: 40, height: 20)..addFrame(img.Image(width: 40, height: 20)));

    Future<void> showLink(WidgetTester tester, LinkPreview link, {required bool load}) async {
      opened = [];
      await setSurfaceSize(tester, const Size(1200, 800));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(_Pictures(picture)),
            linkSourcesProvider.overrideWith(() => _Sources(load)),
            linkPreviewFetcherProvider.overrideWithValue(
              LinkPreviewFetcher(
                mediaDir: dir,
                client: MockClient((request) async {
                  asked.add(request.url);
                  return request.url.path == '/dance.gif'
                      ? http.Response.bytes(dance, 200, headers: {'content-type': 'image/gif'})
                      : http.Response('', 404);
                }),
              ),
            ),
            openLinkProvider.overrideWithValue((url) async {
              opened.add(url);
              return true;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: MessageBubble(
                message: ChatMessage(
                  envelope: Envelope.text(conv: 'c', from: 'kumiko@localhost', text: link.url, link: link),
                ),
                isMine: false,
                senderName: 'Kumiko',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Lets files be written and read, outside the test's fake clock.
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    const long = LinkPreview(
      url: 'https://fxtwitter.com/kumiko/status/9',
      kind: LinkKind.video,
      title: 'Kumiko (@kumiko)',
      thumb: thumb,
      source: LinkSource(url: 'https://video.example/long.mp4', mime: 'video/mp4', durationMs: 600000),
    );

    testWidgets('without the setting, a video that did not come plays on the site', (tester) async {
      await showLink(tester, long, load: false);
      expect(find.text('10:00'), findsNothing);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-link-dialog')), findsOneWidget);
      expect(find.byType(MediaViewerScreen), findsNothing);
    });

    testWidgets('with it, the viewer asks before it loads anything from the site', (tester) async {
      await showLink(tester, long, load: true);
      expect(find.text('10:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('link-picture')));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsOneWidget);
      final dialog = find.byKey(const Key('source-dialog'));
      expect(find.descendant(of: dialog, matching: find.text('Load from video.example?')), findsOneWidget);

      await tester.tap(find.byKey(const Key('source-cancel')));
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
      // It can be asked for again; the bar is there to go back.
      expect(find.byKey(const Key('source-ask')), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.tap(find.byKey(const Key('source-ask')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-load')));
      await settle(tester, () => find.textContaining('Could not load the video').evaluate().isNotEmpty);
      // The site was asked (and here has nothing).
      expect(asked, [Uri.parse('https://video.example/long.mp4')]);
      expect(find.textContaining('Could not load the video'), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('a GIF loaded from its site shows as it is, and opens again without asking', (tester) async {
      const link = LinkPreview(
        url: 'https://cdn.example/dance',
        kind: LinkKind.gif,
        thumb: MediaRef(hash: _hash, size: 100, mime: 'image/jpeg', width: 40, height: 20),
        source: LinkSource(url: 'https://cdn.example/dance.gif', mime: 'image/gif', width: 40, height: 20),
      );
      await showLink(tester, link, load: true);
      expect(find.byType(GifBadge), findsOneWidget);
      final image = find.byKey(const Key('viewer-image'));

      await tester.tap(find.byKey(const Key('link-picture')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-load')));
      await settle(tester, () => image.evaluate().isNotEmpty);
      final file = (tester.widget<Image>(image).image as FileImage).file;
      expect(file.readAsBytesSync(), dance);
      expect(asked, [Uri.parse('https://cdn.example/dance.gif')]);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('link-picture')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-dialog')), findsNothing);
      expect((tester.widget<Image>(image).image as FileImage).file.path, file.path);
      expect(asked, hasLength(1));
    });

    testWidgets(
      "on phones, the system's bars stay while the video's bar shows, though another copy of it takes its place",
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final system = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) system.add(call.method);
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        try {
          await showLink(tester, long, load: true);
          await tester.tap(find.byKey(const Key('link-picture')));
          await tester.pumpAndSettle();
          // The bar over the picture, then the one over the video loading.
          await tester.tap(find.byKey(const Key('source-load')));
          await settle(tester, () => find.textContaining('Could not load the video').evaluate().isNotEmpty);
          expect(find.byType(BackButton), findsOneWidget);
          expect(system, isEmpty);

          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          expect(find.byType(MediaViewerScreen), findsNothing);
          expect(system, isEmpty);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  testWidgets('loading from websites is off until turned on in Settings', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openClubRoom(tester, db: db);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final setting = find.byKey(const Key('link-sources'));
    await tester.scrollUntilVisible(
      setting,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(setting);
    await tester.pumpAndSettle();
    // Read from the database outside the test's fake clock.
    for (var i = 0; i < 100 && tester.widget<SwitchListTile>(setting).onChanged == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(tester.widget<SwitchListTile>(setting).value, isFalse);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.getValue('links.sources')), 'true');
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(setting).value, isTrue);
  });

  testWidgets('a closed preview is not sent; the next link gets one; files show their type and size', (tester) async {
    await openClubRoom(tester);
    await type(tester, 'Menu: https://b.example/nothing-here');
    await tester.pump(const Duration(milliseconds: 600));
    // Nothing to show.
    expect(find.byKey(const Key('composer-link')), findsNothing);

    await type(tester, 'Video ${_video.url} and menu ${_pdf.url}');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('A video'), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-link-close')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('menu.pdf'), findsOneWidget);
    await send(tester);
    final link = (await tester.runAsync(lastSentLink))!;
    expect((link.url, link.kind, link.mime, link.size), (_pdf.url, LinkKind.file, 'application/pdf', 2400000));
    expect(inCard('menu.pdf'), findsOneWidget);
    expect(inCard('PDF · 2.3 MB · b.example'), findsOneWidget);

    // Closed for every link in it: sent without one, but still a link.
    await type(tester, 'Again ${_pdf.url}');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const Key('composer-link-close')));
    await tester.pump();
    expect(find.byKey(const Key('composer-link')), findsNothing);
    await send(tester);
    expect(await tester.runAsync(lastSentLink), isNull);
    expect(find.byKey(const Key('link-card')), findsOneWidget);
    await tester.tapOnText(inMessage(_pdf.url).last);
    expect(opened, [Uri.parse(_pdf.url)]);
  });

  testWidgets('an edit gets no preview; the link can be copied', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await openClubRoom(tester);
    await type(tester, 'See you there');
    await send(tester);

    await tester.longPress(find.text('See you there'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-copyLink')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('action-edit')));
    await tester.pumpAndSettle();
    await type(tester, 'See you there: ${_video.url}');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('composer-link')), findsNothing);
    expect(previews.asked, isEmpty);
    await send(tester);

    await tester.longPress(
      find.descendant(of: find.byType(MessageBubble), matching: find.textContaining('See you there:')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-copyLink')));
    await tester.pumpAndSettle();
    expect(copied, [_video.url]);
  });

  testWidgets('previews can be turned off in Settings', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openClubRoom(tester, db: db);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final setting = find.byKey(const Key('link-previews'));
    await tester.scrollUntilVisible(
      setting,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    // Wholly in view: the scrolling stops as soon as part of it is.
    await tester.ensureVisible(setting);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(setting).value, isTrue);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.getValue('links.previews')), 'false');

    await tester.tap(find.byIcon(Icons.sms_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await type(tester, _video.url);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('composer-link')), findsNothing);
    expect(previews.asked, isEmpty);
  });

  testWidgets('a link to an image or a file can be sent as the file itself', (tester) async {
    final png = img.encodePng(img.Image(width: 8, height: 8));
    const photo = LinkPreviewDraft(
      url: 'https://cdn.example/cat.png',
      kind: LinkKind.image,
      title: 'cat.png',
      mime: 'image/png',
      size: 70,
    );
    const huge = LinkPreviewDraft(
      url: 'https://cdn.example/huge.iso',
      kind: LinkKind.file,
      title: 'huge.iso',
      size: 200 << 20,
    );
    final repo = _Recording();
    await openClubRoom(
      tester,
      repo: repo,
      links: _Previews({
        photo.url: photo,
        huge.url: huge,
        _video.url: _video,
      }, client: MockClient((request) async => http.Response.bytes(png, 200, headers: {'content-type': 'image/png'}))),
    );

    // Not for pages, nor for files larger than the server takes.
    for (final url in [_video.url, huge.url]) {
      await type(tester, url);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('composer-link')), findsOneWidget);
      expect(find.byKey(const Key('composer-link-file')), findsNothing);
    }

    await type(tester, 'Look ${photo.url} so cute');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Send as photo'));
    // Downloaded outside the test's fake clock.
    for (var i = 0; i < 200 && repo.sent.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(
      [
        for (final s in repo.sent) [s.name, s.bytes],
      ],
      [
        ['cat.png', png],
      ],
    );
    // The rest of the text is left to send.
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'Look so cute');
    expect(find.byKey(const Key('composer-link')), findsNothing);
  });
}

/// Notes the files that would be sent, and their bytes at that moment.
class _Recording extends MockChatRepository {
  _Recording() : super(latency: Duration.zero, autoReply: false, now: testNow);

  final sent = <({String name, Uint8List bytes})>[];

  @override
  Future<void> sendAttachment(
    String conversationId, {
    required String path,
    required String name,
    String? replyTo,
  }) async => sent.add((name: name, bytes: File(path).readAsBytesSync()));
}

/// Has [gif] for GIFs and [picture] for other files asked for, but not
/// videos (there is no player in tests).
class _NoVideos extends _Pictures {
  _NoVideos(super.picture, this.gif);

  final File gif;

  @override
  File? mediaFileOf(MediaRef media) => switch (media.hash) {
    _gifHash => gif,
    _ when media.mime.startsWith('video/') => null,
    _ => picture,
  };
}

/// Has [picture] for every file asked for.
class _Pictures extends MockChatRepository {
  _Pictures(this.picture) : super(latency: Duration.zero, autoReply: false, now: testNow);

  final File picture;

  @override
  File? mediaFileOf(MediaRef media) => picture;
}

/// The setting to load from websites, as given.
class _Sources extends LinkSourcesController {
  _Sources(this.load);

  final bool load;

  @override
  Future<bool> build() async => load;
}
