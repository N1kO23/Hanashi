import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:hanashi/data/attachments.dart';
import 'package:hanashi/data/remote/link_previews.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

final _png = img.encodePng(img.Image(width: 1200, height: 600));

http.Response _html(String body, {String charset = 'utf-8'}) =>
    http.Response(body, 200, headers: {'content-type': 'text/html; charset=$charset'});

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_link_media_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a page: its title, description, site and picture, which also goes as it is', () async {
    final requests = <String>[];
    final agents = <String?>{};
    final fetcher = LinkPreviewFetcher(
      mediaDir: dir,
      client: MockClient((request) async {
        requests.add('${request.url}');
        agents.add(request.headers['user-agent']);
        return switch (request.url.path) {
          '/old' => http.Response('', 301, headers: {'location': '/article'}),
          '/article' => _html('''
<html><head>
<title>Ignored when og:title is there</title>
<meta property="og:title" content="  Cats &amp;
  dogs  ">
<meta property="og:description" content="All about pets.">
<meta property="og:site_name" content="Pet News">
<meta property="og:image" content="/img/cover.png">
</head><body><meta property="og:title" content="Not this one"></body></html>'''),
          '/img/cover.png' => http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'}),
          _ => http.Response('', 404),
        };
      }),
    );
    final draft = (await fetcher.fetch('https://news.example/old'))!;
    expect(requests, [
      'https://news.example/old',
      'https://news.example/article',
      'https://news.example/img/cover.png',
    ]);
    expect(
      (draft.url, draft.kind, draft.title, draft.description, draft.site),
      ('https://news.example/old', LinkKind.page, 'Cats & dogs', 'All about pets.', 'Pet News'),
    );
    // Some sites give their videos only to the crawlers of chat apps they know.
    expect(agents, {'Mozilla/5.0 (compatible; Hanashi link preview; like TelegramBot)'});
    // Small enough to stay as large as it is.
    expect((draft.picture!.width, draft.picture!.height, draft.picture!.mime), (1200, 600, 'image/jpeg'));
    expect(img.decodeJpg(draft.picture!.bytes)!.width, 1200);
    // For the viewer: the picture as the site has it.
    final media = draft.media!;
    expect(
      (media.mime, media.size, media.width, media.height, media.durationMs),
      ('image/png', _png.length, 1200, 600, null),
    );
    expect(File(media.path).readAsBytesSync(), _png);
    expect(draft.toPreview().kind, LinkKind.page);
  });

  test("an icon goes as the preview's picture only", () async {
    final icon = img.encodePng(img.Image(width: 192, height: 192));
    final fetcher = LinkPreviewFetcher(
      mediaDir: dir,
      client: MockClient(
        (request) async => request.url.path == '/icon.png'
            ? http.Response.bytes(icon, 200, headers: {'content-type': 'image/png'})
            : _html(
                '<head><meta property="og:title" content="r/cats"><meta property="og:image" content="/icon.png"></head>',
              ),
      ),
    );
    final draft = (await fetcher.fetch('https://forum.example/r/cats'))!;
    expect((draft.kind, draft.picture!.width, draft.media), (LinkKind.page, 192, null));
    expect(dir.listSync(), isEmpty);
  });

  test('without Open Graph: the title; in the character set the page names', () async {
    final fetcher = LinkPreviewFetcher(
      client: MockClient(
        (_) async => _html(
          '<head><title>Hämeenlinna</title><meta name="description" content="Kaupunki"></head>',
          charset: 'iso-8859-1',
        ),
      ),
    );
    final draft = (await fetcher.fetch('https://fi.example/'))!;
    expect((draft.title, draft.description, draft.site, draft.picture), ('Hämeenlinna', 'Kaupunki', null, null));
    // Nothing to show: no preview.
    final empty = LinkPreviewFetcher(client: MockClient((_) async => _html('<p>Hi</p>')));
    expect(await empty.fetch('https://empty.example/'), isNull);
  });

  test('the head of a page, however long, and nothing after it', () async {
    var cancelled = false;
    final fetcher = LinkPreviewFetcher(
      mediaDir: dir,
      client: MockClient.streaming((request, _) async {
        final body = StreamController<List<int>>(onCancel: () => cancelled = true)
          ..add(utf8.encode('<html><head><script>${'x' * (700 << 10)}</script>'))
          ..add(utf8.encode('<meta property="og:title" content="Far down"></HE'))
          ..add(utf8.encode('AD><body>'))
          ..add(List.filled(1 << 20, 0x20));
        return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'text/html'});
      }),
    );
    expect((await fetcher.fetch('https://video.example/watch'))!.title, 'Far down');
    await pumpEventQueue();
    expect(cancelled, isTrue, reason: 'nothing after the head is needed');
  });

  test('a page showing a video that plays on the site: its picture, which opens the site', () async {
    final requests = <String>[];
    final fetcher = LinkPreviewFetcher(
      mediaDir: dir,
      client: MockClient((request) async {
        requests.add(request.url.path);
        return switch (request.url.path) {
          '/watch' => _html('''
<head>
<meta property="og:site_name" content="YouTube">
<meta property="og:title" content="Never Gonna">
<meta property="og:type" content="video.other">
<meta property="og:image" content="https://i.ytimg.com/vi/abc/maxresdefault.jpg">
<meta property="og:video:url" content="https://www.youtube.com/embed/abc">
<meta property="og:video:type" content="text/html">
</head>'''),
          '/vi/abc/maxresdefault.jpg' => http.Response.bytes(_png, 200, headers: {'content-type': 'image/jpeg'}),
          _ => http.Response('', 404),
        };
      }),
    );
    final draft = (await fetcher.fetch('https://www.youtube.com/watch?v=abc'))!;
    expect(
      (draft.kind, draft.title, draft.site, draft.picture!.width, draft.media),
      (LinkKind.video, 'Never Gonna', 'YouTube', 1200, null),
    );
    // A player page is not a video file.
    expect(requests, ['/watch', '/vi/abc/maxresdefault.jpg']);
  });

  test('a link to an image or another file: its name, type and size', () async {
    var cancelled = false;
    final fetcher = LinkPreviewFetcher(
      mediaDir: dir,
      client: MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('.png')) {
          return http.StreamedResponse(Stream.value(_png), 200, headers: {'content-type': 'image/png'});
        }
        final body = StreamController<List<int>>(onCancel: () => cancelled = true)..add(List.filled(1024, 0));
        return http.StreamedResponse(
          body.stream,
          200,
          contentLength: 2400000,
          headers: {
            'content-type': 'application/pdf',
            'content-disposition': "attachment; filename*=UTF-8''Lasku%20%C3%A4.pdf",
          },
        );
      }),
    );
    final image = (await fetcher.fetch('https://cdn.example/photos/cat%20pic.png'))!;
    expect(
      (image.kind, image.title, image.mime, image.size),
      (LinkKind.image, 'cat pic.png', 'image/png', _png.length),
    );
    expect(image.picture!.width, 1200);
    // The image itself, for the viewer.
    expect(image.media!.mime, 'image/png');
    expect(File(image.media!.path).readAsBytesSync(), _png);

    final pdf = (await fetcher.fetch('https://files.example/download?id=1'))!;
    expect(
      (pdf.kind, pdf.title, pdf.mime, pdf.size, pdf.picture),
      (LinkKind.file, 'Lasku ä.pdf', 'application/pdf', 2400000, null),
    );
    await pumpEventQueue();
    expect(cancelled, isTrue, reason: 'only the headers of a file are needed');
  });

  group('videos and GIFs', () {
    final mp4 = List.filled(5000, 7);
    final animated = img.encodeGif(img.Image(width: 40, height: 20)..addFrame(img.Image(width: 40, height: 20)));

    LinkPreviewFetcher fetcher(List<Uri> requests, {VideoProbe? probe}) => LinkPreviewFetcher(
      probeVideo: probe,
      mediaDir: dir,
      client: MockClient.streaming((request, _) async {
        requests.add(request.url);
        http.StreamedResponse page(String video, {String type = 'video/mp4'}) => http.StreamedResponse(
          Stream.value(
            utf8.encode('''
<head>
<meta property="og:title" content="Kumiko (@kumiko)">
<meta property="og:site_name" content="FxTwitter">
<meta property="theme-color" content="#63F">
<meta property="og:image" content="/thumb.png">
<meta property="og:video" content="$video">
<meta property="og:video:secure_url" content="$video">
<meta property="og:video:type" content="$type">
<meta property="og:video:width" content="1280">
<meta property="og:video:height" content="720">
</head>'''),
          ),
          200,
          headers: {'content-type': 'text/html'},
        );
        return switch (request.url.path) {
          '/kumiko/status/1' => page('https://video.example/v.mp4'),
          '/kumiko/status/2' => page('https://video.example/huge.mp4'),
          '/kumiko/status/3' => page('https://player.example/embed/1', type: 'text/html'),
          '/v.mp4' ||
          '/direct.mp4' => http.StreamedResponse(Stream.value(mp4), 200, headers: {'content-type': 'video/mp4'}),
          '/huge.mp4' => http.StreamedResponse(
            Stream.value(mp4),
            200,
            contentLength: LinkPreviewFetcher.maxMediaBytes + 1,
            headers: {'content-type': 'video/mp4'},
          ),
          '/dance.gif' => http.StreamedResponse(Stream.value(animated), 200, headers: {'content-type': 'image/gif'}),
          '/still.gif' => http.StreamedResponse(
            Stream.value(img.encodeGif(img.Image(width: 40, height: 20))),
            200,
            headers: {'content-type': 'image/gif'},
          ),
          '/thumb.png' => http.StreamedResponse(Stream.value(_png), 200, headers: {'content-type': 'image/png'}),
          _ => http.StreamedResponse(const Stream.empty(), 404),
        };
      }),
    );

    test('the video a page shows goes with its preview; one without sound plays like a GIF', () async {
      final requests = <Uri>[];
      final video = (await fetcher(requests).fetch('https://fxtwitter.example/kumiko/status/1'))!;
      expect(
        (video.kind, video.title, video.site, video.color, video.picture!.width),
        (LinkKind.video, 'Kumiko (@kumiko)', 'FxTwitter', '#6633ff', 1200),
      );
      final media = video.media!;
      expect((media.mime, media.size, media.width, media.height), ('video/mp4', 5000, 1280, 720));
      expect(File(media.path).readAsBytesSync(), mp4);
      expect(File(media.path).parent.path, dir.path);
      expect(video.toPreview().color, '#6633ff');
      // Where it is, for when the file does not reach someone.
      expect((video.source!.url, video.source!.mime), ('https://video.example/v.mp4', 'video/mp4'));

      // What the player tells about it wins over what the page says.
      final silent = (await fetcher(
        requests,
        probe: (_) async => const VideoInfo(width: 640, height: 360, duration: Duration(seconds: 3), hasAudio: false),
      ).fetch('https://fxtwitter.example/kumiko/status/1'))!;
      expect((silent.kind, silent.media!.width, silent.media!.durationMs), (LinkKind.gif, 640, 3000));
      final sound = (await fetcher(
        requests,
        probe: (_) async => const VideoInfo(width: 640, height: 360, hasAudio: true),
      ).fetch('https://fxtwitter.example/kumiko/status/1'))!;
      expect(sound.kind, LinkKind.video);

      // Nothing the player can show: only the page, and its picture.
      final none = (await fetcher(
        requests,
        probe: (_) async => null,
      ).fetch('https://fxtwitter.example/kumiko/status/1'))!;
      expect((none.kind, none.media?.mime, none.picture?.width), (LinkKind.page, 'image/png', 1200));
    });

    test('too large, or a player page: the preview goes without it', () async {
      final requests = <Uri>[];
      // Still a video, which those who choose to can load from the site.
      final huge = (await fetcher(requests).fetch('https://fxtwitter.example/kumiko/status/2'))!;
      expect((huge.kind, huge.media, huge.title), (LinkKind.video, null, 'Kumiko (@kumiko)'));
      final source = huge.source!;
      expect(
        (source.url, source.mime, source.width, source.height),
        ('https://video.example/huge.mp4', 'video/mp4', 1280, 720),
      );
      expect(huge.toPreview().source!.url, source.url);
      final player = (await fetcher(requests).fetch('https://fxtwitter.example/kumiko/status/3'))!;
      expect(player.media?.mime, 'image/png');
      expect(requests.map((u) => u.host), isNot(contains('player.example')));
      expect(
        dir.listSync().map((file) => (file as File).readAsBytesSync()),
        everyElement(_png),
        reason: 'what was too large is not kept',
      );
    });

    test('a link straight to a video or an animated GIF brings the file itself', () async {
      final requests = <Uri>[];
      final links = fetcher(requests);
      final video = (await links.fetch('https://cdn.example/direct.mp4'))!;
      expect(
        (video.kind, video.title, video.mime, video.size, video.media!.size),
        (LinkKind.video, 'direct.mp4', 'video/mp4', 5000, 5000),
      );
      expect(video.source!.url, 'https://cdn.example/direct.mp4');
      final dance = (await links.fetch('https://cdn.example/dance.gif'))!;
      expect((dance.kind, dance.mime, dance.media!.width, dance.media!.height), (LinkKind.gif, 'image/gif', 40, 20));
      expect((dance.source!.url, dance.source!.mime), ('https://cdn.example/dance.gif', 'image/gif'));
      expect(File(dance.media!.path).readAsBytesSync(), animated);
      // One that does not move is a picture, for the viewer.
      final still = (await links.fetch('https://cdn.example/still.gif'))!;
      expect(
        (still.kind, still.media!.mime, still.media!.width, still.source),
        (LinkKind.image, 'image/gif', 40, null),
      );
    });

    test('what was never sent is cleared out after a day', () async {
      final old = File('${dir.path}/old')..writeAsBytesSync([1]);
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      final recent = File('${dir.path}/recent')..writeAsBytesSync([1]);
      await fetcher([]).fetch('https://cdn.example/direct.mp4');
      expect((old.existsSync(), recent.existsSync()), (false, true));
    });
  });

  group('loading from the site, for those who choose to', () {
    final video = List.generate(100000, (i) => i % 251);
    late List<(String, String?)> asked;
    // Downloads from the site that were stopped.
    late int cancelled;
    var turnsAway = false;

    /// A site whose video answers range requests, as video hosts do.
    LinkPreviewFetcher site() {
      asked = [];
      cancelled = 0;
      turnsAway = false;
      return LinkPreviewFetcher(
        mediaDir: dir,
        client: MockClient.streaming((request, _) async {
          final range = request.headers['range'];
          asked.add((request.url.path, range));
          switch (request.url.path) {
            case '/go':
              return http.StreamedResponse(
                const Stream.empty(),
                302,
                headers: {'location': 'https://video.example/v.mp4'},
              );
            case '/to-lan':
              return http.StreamedResponse(
                const Stream.empty(),
                302,
                headers: {'location': 'https://192.168.1.1/v.mp4'},
              );
            case '/v.mp4' when turnsAway:
              return http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'https://10.0.0.1/v.mp4'});
            case '/v.mp4':
              final match = range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
              final start = match == null ? 0 : int.parse(match[1]!);
              final end = match == null || match[2]!.isEmpty ? video.length - 1 : int.parse(match[2]!);
              return http.StreamedResponse(
                Stream.value(video.sublist(start, end + 1)),
                match == null ? 200 : 206,
                contentLength: end + 1 - start,
                headers: {
                  'content-type': 'video/mp4',
                  'accept-ranges': 'bytes',
                  if (match != null) 'content-range': 'bytes $start-$end/${video.length}',
                },
              );
            case '/endless.mp4':
              var stopped = false;
              final body = StreamController<List<int>>(
                onCancel: () {
                  stopped = true;
                  cancelled++;
                },
              );
              Timer.periodic(const Duration(milliseconds: 5), (timer) {
                if (stopped) return timer.cancel();
                body.add(List.filled(64 << 10, 1));
              });
              return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'video/mp4'});
            case '/page':
              return http.StreamedResponse(
                Stream.value(utf8.encode('<p>Hi')),
                200,
                headers: {'content-type': 'text/html'},
              );
            case '/cat.png':
              return http.StreamedResponse(
                Stream.value(_png),
                200,
                contentLength: _png.length,
                headers: {'content-type': 'image/png'},
              );
            case '/huge.png':
              return http.StreamedResponse(
                const Stream.empty(),
                200,
                contentLength: LinkPreviewFetcher.maxSourceBytes + 1,
                headers: {'content-type': 'image/png'},
              );
            default:
              return http.StreamedResponse(const Stream.empty(), 404);
          }
        }),
      );
    }

    late HttpClient player;
    setUp(() => player = HttpClient());
    tearDown(() => player.close(force: true));

    Future<(int, String?, List<int>)> play(Uri url, {String? range}) async {
      final request = await player.getUrl(url);
      if (range != null) request.headers.set('range', range);
      final response = await request.close();
      final body = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      return (response.statusCode, response.headers.value('content-range'), body);
    }

    test('a video streams through this device, in the parts the player asks for', () async {
      final fetcher = site();
      final stream = await fetcher.stream('https://site.example/go');
      addTearDown(stream.close);
      // Only this device can reach it.
      expect(stream.address.host, '127.0.0.1');

      final (status, range, part) = await play(stream.address, range: 'bytes=1000-1999');
      expect((status, range), (206, 'bytes 1000-1999/100000'));
      expect(part, video.sublist(1000, 2000));
      final whole = await play(stream.address);
      expect((whole.$1, whole.$3.length), (200, video.length));
      expect((await play(stream.address.replace(path: '/something-else'))).$1, 404);
      // Asked at the address it redirected to, with the player's ranges.
      expect(asked, [('/go', 'bytes=0-0'), ('/v.mp4', 'bytes=0-0'), ('/v.mp4', 'bytes=1000-1999'), ('/v.mp4', null)]);

      // Redirects later on go by the same rules.
      turnsAway = true;
      expect((await play(stream.address)).$1, 502);
      await stream.close();
      await expectLater(play(stream.address), throwsA(isA<IOException>()));
    });

    test('not a video, or not an address by the rules: nothing streams', () async {
      final fetcher = site();
      for (final address in [
        'https://site.example/page',
        'https://site.example/to-lan',
        'https://site.example/missing',
        'http://site.example/v.mp4',
        'https://192.168.1.1/v.mp4',
      ]) {
        await expectLater(fetcher.stream(address), throwsA(isA<AttachmentException>()), reason: address);
      }
      expect(asked.map((a) => a.$1), isNot(contains('/v.mp4')));
    });

    test('when the player goes away, so does the download from the site', () async {
      final stream = await site().stream('https://site.example/endless.mp4');
      addTearDown(stream.close);
      // Only the first byte was needed to see that it is a video.
      expect(cancelled, 1);
      final response = await (await player.getUrl(stream.address)).close();
      await response.first;
      player.close(force: true);
      for (var i = 0; i < 200 && cancelled < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cancelled, 2);
    });

    test('a picture or GIF downloads, up to 100 MB', () async {
      final fetcher = site();
      final progress = <double>[];
      final file = await fetcher.loadSource(
        const LinkSource(url: 'https://site.example/cat.png', mime: 'image/png'),
        onProgress: progress.add,
      );
      expect(file.readAsBytesSync(), _png);
      expect(file.parent.path, dir.path);
      expect(progress.last, 1.0);
      for (final path in ['/huge.png', '/page', '/v.mp4']) {
        await expectLater(
          fetcher.loadSource(LinkSource(url: 'https://site.example$path', mime: 'image/png')),
          throwsA(isA<AttachmentException>()),
          reason: path,
        );
      }
    });
  });

  test('only HTTPS addresses of public hosts, also after redirects', () async {
    final requests = <Uri>[];
    final fetcher = LinkPreviewFetcher(
      client: MockClient((request) async {
        requests.add(request.url);
        return switch (request.url.path) {
          '/to-lan' => http.Response('', 302, headers: {'location': 'https://192.168.1.1/admin'}),
          '/to-http' => http.Response('', 302, headers: {'location': 'http://plain.example/'}),
          '/loop' => http.Response('', 302, headers: {'location': '/loop'}),
          _ => http.Response('', 500),
        };
      }),
    );
    for (final address in [
      'http://plain.example/',
      'https://localhost/',
      'https://printer.local/',
      'https://router/',
      'https://10.0.0.1/',
      'https://127.0.0.1:8080/',
      'https://[::1]/',
      'https://[fd00::1]/',
      'https://user:pass@site.example/',
    ]) {
      expect(LinkPreviewFetcher.canPreview(Uri.parse(address)), isFalse, reason: address);
      expect(await fetcher.fetch(address), isNull, reason: address);
    }
    expect(requests, isEmpty);
    expect(LinkPreviewFetcher.canPreview(Uri.parse('https://93.184.215.14/')), isTrue);

    for (final path in ['/to-lan', '/to-http', '/loop', '/error']) {
      expect(await fetcher.fetch('https://site.example$path'), isNull, reason: path);
    }
    expect(requests.map((u) => u.host).toSet(), {'site.example'});
    expect(requests.where((u) => u.path == '/loop'), hasLength(6), reason: 'five redirects at most');
  });

  test('a linked file downloads under a safe name, up to a size', () async {
    final dir = Directory.systemTemp.createTempSync('hanashi_links_');
    addTearDown(() => dir.delete(recursive: true));
    final fetcher = LinkPreviewFetcher(
      client: MockClient.streaming((request, _) async {
        final size = int.parse(request.url.queryParameters['size'] ?? '0');
        return http.StreamedResponse(
          Stream.fromIterable([List.filled(size ~/ 2, 1), List.filled(size - size ~/ 2, 2)]),
          200,
          // Some servers do not say how much is coming.
          contentLength: request.url.queryParameters['say'] == null ? null : size,
        );
      }),
    );
    Future<File> download(String query, {String name = 'a.bin'}) =>
        fetcher.download('https://files.example/f?$query', dir, name: name, maxBytes: 1000);

    final file = await download('size=1000', name: '../../.bashrc');
    expect(file.parent.path, dir.path);
    expect((file.uri.pathSegments.last, file.lengthSync()), ('_.._.bashrc', 1000));
    expect((await download('size=10', name: 'C:\\x\\y:z?.txt')).uri.pathSegments.last, 'C__x_y_z_.txt');
    expect((await download('size=10', name: '...')).uri.pathSegments.last, 'file');

    for (final query in ['size=1001&say=1', 'size=1001']) {
      await expectLater(
        download(query),
        throwsA(isA<AttachmentException>().having((e) => e.message, 'message', 'The file is larger than 0 MB')),
      );
    }
    await expectLater(
      fetcher.download('http://files.example/f', dir, name: 'a', maxBytes: 1000),
      throwsA(isA<AttachmentException>()),
    );
  });
}
