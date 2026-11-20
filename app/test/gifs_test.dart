import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/chat_repository.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/remote/klipy.dart';
import 'package:hanashi/data/remote/remote_media.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/media/gif_view.dart';
import 'package:hanashi/ui/media/media_viewer.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_app.dart';

/// A GIF on KLIPY's media host.
RemoteMedia _klipy(String slug, String size) => RemoteMedia(
  provider: RemoteMedia.klipy,
  id: slug,
  url: 'https://static.klipy.com/ii/$slug/$size.gif',
  mime: 'image/gif',
  width: 200,
  height: 150,
);

class _FakeGifSearch implements GifSearch {
  final searches = <String>[];

  static GifResult result(String slug) => GifResult(preview: _klipy(slug, 'sm'), full: _klipy(slug, 'md'));

  @override
  Future<GifPage> trending({int page = 1}) async => GifPage([result('dance'), result('wave')], hasNext: false);

  @override
  Future<GifPage> search(String query, {int page = 1}) async {
    searches.add(query);
    return GifPage([result('cat-$query')], hasNext: false);
  }
}

final _gifBytes = img.encodeGif(img.Image(width: 4, height: 3));

/// A loader that answers every request with a small GIF and notes it.
RemoteMediaLoader _loader(List<Uri> requests) => RemoteMediaLoader(
  client: MockClient((request) async {
    requests.add(request.url);
    return http.Response.bytes(_gifBytes, 200);
  }),
);

/// One KLIPY result as their API sends it.
Map<String, Object?> _item(String slug, {String host = 'static.klipy.com', bool webp = true}) => {
  'id': 7,
  'slug': slug,
  'title': 'Title of $slug',
  'type': 'gif',
  'blur_preview': 'data:image/jpeg;base64,AAAA',
  'file': {
    for (final (size, width) in [('hd', 498), ('md', 360), ('sm', 220), ('xs', 90)])
      size: {
        'gif': {'url': 'https://$host/ii/$slug/$size.gif', 'width': width, 'height': 200, 'size': 9000},
        if (webp) 'webp': {'url': 'https://$host/ii/$slug/$size.webp', 'width': width, 'height': 200, 'size': 4000},
        'mp4': {'url': 'https://$host/ii/$slug/$size.mp4', 'width': width, 'height': 200, 'size': 3000},
      },
  },
};

void main() {
  group('KLIPY', () {
    test('searches without a user ID; medium WebP for messages, small for the grid', () async {
      final requests = <Uri>[];
      final search = KlipyGifSearch(
        'the-key',
        locale: 'fi',
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'result': true,
              'data': {
                'data': [
                  _item('happy-cat'),
                  {'type': 'ad', 'content': '<iframe></iframe>', 'width': 300, 'height': 250},
                  _item('old-gif', webp: false),
                  _item('elsewhere', host: 'cdn.example.com'),
                ],
                'current_page': 2,
                'per_page': 24,
                'has_next': true,
              },
            }),
            200,
          );
        }),
      );
      final page = await search.search('happy cat', page: 2);
      final uri = requests.single;
      expect((uri.host, uri.path), ('api.klipy.com', '/api/v1/the-key/gifs/search'));
      expect(uri.queryParameters, {'q': 'happy cat', 'page': '2', 'per_page': '24', 'locale': 'fi'});

      expect(page.hasNext, isTrue);
      expect([for (final r in page.items) r.full.id], ['happy-cat', 'old-gif']);
      final [cat, old] = page.items;
      expect((cat.preview.url, cat.preview.mime), ('https://static.klipy.com/ii/happy-cat/sm.webp', 'image/webp'));
      expect((cat.full.url, cat.full.width, cat.full.title), ('https://static.klipy.com/ii/happy-cat/md.webp', 360, 'Title of happy-cat'));
      expect(old.full.url, 'https://static.klipy.com/ii/old-gif/md.gif');

      await search.trending();
      expect(requests.last.path, '/api/v1/the-key/gifs/trending');
    });

    test('errors are for the user', () async {
      final failing = KlipyGifSearch('k', client: MockClient((_) async => http.Response('{}', 500)));
      await expectLater(failing.trending(), throwsA(isA<GifSearchException>()));
      final offline = KlipyGifSearch('k', client: MockClient((_) async => throw http.ClientException('offline')));
      await expectLater(
        offline.search('x'),
        throwsA(isA<GifSearchException>().having((e) => e.message, 'message', 'Cannot reach KLIPY')),
      );
    });
  });

  group('remote media', () {
    test("is kept in memory, and only KLIPY's hosts are contacted, redirects included", () async {
      final requests = <Uri>[];
      final loader = RemoteMediaLoader(
        cacheBytes: 2 * _gifBytes.length,
        client: MockClient((request) async {
          requests.add(request.url);
          return switch (request.url.path) {
            '/ii/moved/md.gif' => http.Response('', 302, headers: {'location': 'https://static2.klipy.com/moved.gif'}),
            '/ii/away/md.gif' => http.Response('', 301, headers: {'location': 'https://tracker.example/pixel.gif'}),
            '/ii/huge/md.gif' => http.Response.bytes(List.filled(64, 0), 200),
            _ => http.Response.bytes(_gifBytes, 200),
          };
        }),
      );
      final dance = _klipy('dance', 'md');
      expect(await loader.load(dance), _gifBytes);
      expect(await loader.load(dance), _gifBytes);
      expect(requests, hasLength(1));

      expect(await loader.load(_klipy('moved', 'md')), _gifBytes);
      expect(requests.last, Uri.parse('https://static2.klipy.com/moved.gif'));
      await expectLater(loader.load(_klipy('away', 'md')), throwsA(isA<RemoteMediaException>()));
      expect(requests.where((u) => u.host == 'tracker.example'), isEmpty);

      // The least recently used goes first.
      await loader.load(_klipy('wave', 'md'));
      expect(loader.cached(dance), isNull);
      expect(loader.cached(_klipy('wave', 'md')), isNotNull);

      final small = RemoteMediaLoader(maxBytes: 32, client: MockClient((_) async => http.Response.bytes(List.filled(64, 0), 200)));
      await expectLater(small.load(_klipy('huge', 'md')), throwsA(isA<RemoteMediaException>()));
    });
  });

  Future<void> openClubRoom(WidgetTester tester, Widget app) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
  }

  Future<void> openGifTab(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({}); // For the emoji tab, which opens first.
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('expression-tab-gif')));
    await tester.pumpAndSettle();
  }

  /// Waits for snack bars to go, so that they cover nothing.
  Future<void> letSnackBarsGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  /// The repository's saved GIFs, read outside the test's fake clock.
  Future<List<GifRef>> savedGifs(WidgetTester tester, ChatRepository repository) async =>
      (await tester.runAsync(() => repository.watchSavedGifs().first))!;

  final gifBubbles = find.byWidgetPredicate((w) => w is MessageBubble && w.message.envelope.messageType == MessageType.gif);
  final theGif = find.descendant(of: gifBubbles, matching: find.byType(GifView));
  List<GifRef> sentGifs(WidgetTester tester) => [
    for (final b in tester.widgetList<MessageBubble>(gifBubbles)) b.message.envelope.gif!,
  ];

  testWidgets('the GIF tab: trending and search from KLIPY; a tap sends one, a long press saves it', (tester) async {
    final search = _FakeGifSearch();
    final requests = <Uri>[];
    final repository = testRepository();
    await openClubRoom(
      tester,
      testApp(
        repository,
        overrides: [
          gifSearchProvider.overrideWith((ref) async => search),
          remoteMediaLoaderProvider.overrideWithValue(_loader(requests)),
        ],
      ),
    );
    await openGifTab(tester);
    expect(find.text('Search KLIPY'), findsOneWidget);
    expect(find.text('Trending on KLIPY'), findsOneWidget);
    expect(find.byKey(const ValueKey('gif-dance')), findsOneWidget);
    // The grid shows the small versions, straight from KLIPY.
    expect(requests, contains(Uri.parse('https://static.klipy.com/ii/dance/sm.gif')));

    await tester.longPress(find.byKey(const ValueKey('gif-wave')));
    await tester.pumpAndSettle();
    expect(find.text('Saved to your GIFs'), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-gif-klipy:wave')), findsOneWidget);
    expect((await savedGifs(tester, repository)).single.remote!.url, 'https://static.klipy.com/ii/wave/md.gif');
    await letSnackBarsGo(tester);

    await tester.enterText(find.byKey(const Key('gif-search')), 'cat');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(search.searches, ['cat']);
    expect(find.text('Trending on KLIPY'), findsNothing);
    expect(find.byKey(const ValueKey('saved-gif-klipy:wave')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('gif-cat-cat')));
    await tester.pumpAndSettle();

    // Sent as the medium version; the panel closes.
    expect(find.byKey(const Key('expression-panel')), findsNothing);
    expect([for (final gif in sentGifs(tester)) gif.remote!.url], ['https://static.klipy.com/ii/cat-cat/md.gif']);
  });

  testWidgets('GIFs saved from chats; without search on the server the GIF tab has those', (tester) async {
    final repository = testRepository();
    // A GIF file sent as a photo.
    repository.sendGif('club', const GifRef.media(MediaRef(hash: _hash, size: 900, mime: 'image/gif', width: 40, height: 30)));
    await openClubRoom(tester, testApp(repository, overrides: [remoteMediaLoaderProvider.overrideWithValue(_loader([]))]));

    await tester.longPress(theGif);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-saveGif')));
    await tester.pumpAndSettle();
    expect((await savedGifs(tester, repository)).single.key, _hash);
    await letSnackBarsGo(tester);
    // Saved already: the action takes it back instead.
    await tester.longPress(theGif);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-saveGif')), findsNothing);
    expect(find.byKey(const ValueKey('action-unsaveGif')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // Closes the actions.
    await tester.pumpAndSettle();

    await openGifTab(tester);
    expect(find.text('GIF search is not set up on this server.'), findsOneWidget);
    expect(find.text('Search KLIPY'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('saved-gif-$_hash')));
    await tester.pumpAndSettle();
    // The same file again: nothing to upload.
    expect([for (final gif in sentGifs(tester)) gif.media!.hash], [_hash, _hash]);
  });

  testWidgets("a KLIPY GIF opens in the viewer, where it can be saved to the user's GIFs and taken out", (tester) async {
    final loader = _loader([]);
    final repository = testRepository();
    const dance = RemoteMedia(
      provider: RemoteMedia.klipy,
      id: 'dance',
      url: 'https://static.klipy.com/ii/dance/md.gif',
      mime: 'image/gif',
      width: 200,
      height: 150,
      title: 'Happy dance',
    );
    repository.sendGif('club', const GifRef.remote(dance));
    await openClubRoom(tester, testApp(repository, overrides: [remoteMediaLoaderProvider.overrideWithValue(loader)]));
    await tester.runAsync(() => loader.load(dance)); // Loaded outside the test's fake clock.
    await tester.pump();

    // KLIPY does not allow keeping copies.
    await tester.longPress(theGif);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-saveGif')), findsOneWidget);
    expect(find.byKey(const ValueKey('action-download')), findsNothing);
    await tester.tapAt(const Offset(10, 10)); // Closes the actions.
    await tester.pumpAndSettle();

    await tester.tap(theGif);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerScreen), findsOneWidget);
    expect(find.text('Happy dance'), findsOneWidget);
    expect(find.descendant(of: find.byType(MediaViewerScreen), matching: find.byType(Image)), findsOneWidget);
    // KLIPY does not allow keeping copies.
    expect(find.byTooltip('Download'), findsNothing);

    await tester.tap(find.byKey(const Key('viewer-save-gif')));
    await tester.pumpAndSettle();
    expect((await savedGifs(tester, repository)).single.key, 'klipy:dance');
    expect(find.byTooltip('Remove from saved GIFs'), findsOneWidget);
    await tester.tap(find.byKey(const Key('viewer-save-gif')));
    await tester.pumpAndSettle();
    expect(await savedGifs(tester, repository), isEmpty);
    expect(find.byTooltip('Save GIF'), findsOneWidget);

    // Escape closes the viewer.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerScreen), findsNothing);
  });

  testWidgets("KLIPY's GIFs in chats wait for a tap when loading them by themselves is off", (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final requests = <Uri>[];
    final loader = _loader(requests);
    final repository = testRepository();
    repository.sendGif('club', GifRef.remote(_klipy('dance', 'md')));
    final app = testApp(
      repository,
      overrides: [databaseProvider.overrideWithValue(db), remoteMediaLoaderProvider.overrideWithValue(loader)],
    );
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Turned off in Settings.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('gifs-autoload')),
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    // Wholly in view: the scrolling stops as soon as part of it is.
    await tester.ensureVisible(find.byKey(const Key('gifs-autoload')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gifs-autoload')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.getValue('gifs.autoload')), 'false');

    await tester.tap(find.byIcon(Icons.sms_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    final bubble = gifBubbles;
    expect(find.descendant(of: bubble, matching: find.byKey(const Key('gif-tap-to-load'))), findsOneWidget);
    expect(requests, isEmpty);

    await tester.tap(find.descendant(of: bubble, matching: find.byKey(const Key('gif-tap-to-load'))));
    await tester.pumpAndSettle();
    expect(requests, [Uri.parse('https://static.klipy.com/ii/dance/md.gif')]);
    // The download finishes outside the test's fake clock.
    await tester.runAsync(() => loader.load(_klipy('dance', 'md')));
    await tester.pump();
    expect(find.descendant(of: bubble, matching: find.byType(Image)), findsOneWidget);
  });
}

const _hash = 'sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae';
