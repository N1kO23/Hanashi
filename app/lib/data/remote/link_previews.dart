import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../attachments.dart';

/// What the sender's app found at a link: shown above the composer, and sent
/// with the message as a [LinkPreview].
class LinkPreviewDraft {
  const LinkPreviewDraft({
    required this.url,
    required this.kind,
    this.title,
    this.description,
    this.site,
    this.mime,
    this.size,
    this.color,
    this.picture,
    this.media,
    this.source,
  });

  final String url;
  final LinkKind kind;
  final String? title;
  final String? description;
  final String? site;
  final String? mime;
  final int? size;
  final String? color;

  /// Uploaded as the preview's thumbnail.
  final LinkPicture? picture;

  /// The video or GIF that plays in the chat, or the picture as the site has
  /// it for the viewer, uploaded with the message.
  final LinkMediaFile? media;

  /// Where the site has its video or GIF, also when [media] is not it.
  final LinkSource? source;

  /// The preview to send, with [thumb] and [media] once [picture] and the
  /// file of [media] are uploaded.
  LinkPreview toPreview({MediaRef? thumb, MediaRef? media}) => LinkPreview(
    url: url,
    kind: kind,
    title: title,
    description: description,
    site: site,
    thumb: thumb,
    media: media,
    source: source,
    color: color,
    mime: mime,
    size: size,
  );
}

/// A link's video, GIF or picture, downloaded by the sender's app.
class LinkMediaFile {
  const LinkMediaFile({
    required this.path,
    required this.mime,
    required this.size,
    this.width,
    this.height,
    this.durationMs,
  });

  final String path;
  final String mime;
  final int size;
  final int? width;
  final int? height;
  final int? durationMs;
}

/// The page, image or file is not there, or not one to preview.
class _NoPreview implements Exception {
  const _NoPreview();
}

/// Makes link previews on the sender's device. Only HTTPS addresses of public
/// hosts are fetched (also after redirects), with a time limit, and only as
/// much as a preview needs: the start of a page, an image up to a size, a
/// video or GIF up to [maxMediaBytes], the headers of any other file.
class LinkPreviewFetcher {
  LinkPreviewFetcher({http.Client? client, this.probeVideo, Directory? mediaDir})
    : _client = client ?? http.Client(),
      _mediaDir = mediaDir ?? Directory('${Directory.systemTemp.path}/hanashi-link-media');

  final http.Client _client;

  /// Tells a video's size, length and first frame, and whether it has sound
  /// (one without plays like a GIF). Without it, videos go as they are.
  final VideoProbe? probeVideo;

  /// Where videos, GIFs and pictures wait to be sent. Those that never are go
  /// after a day.
  final Directory _mediaDir;

  /// The most of a page read: reading stops at the end of its head, which
  /// is all a preview needs, but some sites put a lot in it.
  static const _pageBytes = 2 << 20;

  /// The largest image made into a thumbnail.
  static const _imageBytes = 10 << 20;

  /// The largest video or GIF that goes with a preview: larger ones show
  /// their picture, and play on the site.
  static const maxMediaBytes = 25 << 20;

  /// Some sites give their videos only to the link crawlers of chat apps they
  /// know, so this one says which it is like, as Telegram's says it is "like
  /// TwitterBot".
  static const _userAgent = 'Mozilla/5.0 (compatible; Hanashi link preview; like TelegramBot)';

  /// Whether [url] may be fetched for a preview: HTTPS, and not this device
  /// or the local network, whose pages are not for others to see.
  static bool canPreview(Uri url) {
    if (url.scheme != 'https' || url.userInfo.isNotEmpty) return false;
    final host = url.host.toLowerCase();
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return _isPublic(ip);
    return host.contains('.') &&
        !host.endsWith('.localhost') &&
        !host.endsWith('.local') &&
        !host.endsWith('.internal') &&
        !host.endsWith('.lan') &&
        !host.endsWith('.home.arpa');
  }

  static bool _isPublic(InternetAddress ip) {
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return false;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168));
    }
    return (b[0] & 0xfe) != 0xfc && b.any((x) => x != 0); // Not unique local, nor ::.
  }

  /// A preview of [address], a link from [findLinks]; null if it cannot be
  /// previewed or there is nothing to show.
  Future<LinkPreviewDraft?> fetch(String address) async {
    final url = Uri.tryParse(address);
    if (url == null || !canPreview(url)) return null;
    try {
      final (response, at) = await _get(url, accept: 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8');
      final type = (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (type == 'text/html' || type == 'application/xhtml+xml') return await _page(address, at, response);
      final name = _fileName(response, at);
      if (type.startsWith('image/')) {
        final bytes = await _read(response, _imageBytes, whole: true);
        final image = bytes == null ? null : await linkImage(bytes);
        if (image != null) {
          return LinkPreviewDraft(
            url: address,
            kind: image.animated ? LinkKind.gif : LinkKind.image,
            title: name,
            mime: type,
            size: bytes!.length,
            picture: image.picture,
            media: await _keep(bytes, image),
            source: image.animated ? _source(url, image.mime!, width: image.width, height: image.height) : null,
          );
        }
      } else if (type.startsWith('video/')) {
        final video = await _video(response, type);
        final media = video?.media;
        if (video != null && media != null) {
          return LinkPreviewDraft(
            url: address,
            kind: video.kind,
            title: name,
            mime: type,
            size: media.size,
            picture: video.frame,
            media: media,
            source: _source(url, type, width: media.width, height: media.height, durationMs: media.durationMs),
          );
        }
      } else {
        _drop(response);
      }
      return LinkPreviewDraft(
        url: address,
        kind: LinkKind.file,
        title: name,
        mime: type.isEmpty ? null : type,
        size: response.contentLength,
      );
    } on Exception {
      return null; // Offline, slow, or not what it claimed to be: no preview.
    }
  }

  Future<LinkPreviewDraft?> _page(String address, Uri at, http.StreamedResponse response) async {
    final page = _decode(await _readHead(response), response.headers['content-type']);
    final meta = await Isolate.run(() => _pageMeta(page));
    String? first(List<String> keys) => keys.map((k) => meta[k]).nonNulls.firstOrNull;
    final title = _clean(first(['og:title', 'twitter:title', 'title']), LinkPreview.maxTitle);
    final description = _clean(
      first(['og:description', 'twitter:description', 'description']),
      LinkPreview.maxDescription,
    );
    final image = first(['og:image:secure_url', 'og:image', 'og:image:url', 'twitter:image', 'twitter:image:src']);
    if (title == null && description == null && image == null) return null;
    final imageUrl = image == null ? null : Uri.tryParse(image.trim());
    // A video file the page embeds (not a player page, e.g. YouTube's).
    final videoAddress = first(['og:video:secure_url', 'og:video:url', 'og:video', 'twitter:player:stream']);
    final videoType = first(['og:video:type', 'twitter:player:stream:content_type'])?.toLowerCase();
    final videoUrl = videoAddress == null || (videoType != null && !videoType.startsWith('video/'))
        ? null
        : Uri.tryParse(videoAddress.trim());
    final video = videoUrl == null
        ? null
        : await _pageVideo(
            at.resolveUri(videoUrl),
            width: int.tryParse(meta['og:video:width'] ?? ''),
            height: int.tryParse(meta['og:video:height'] ?? ''),
          );
    final pictureUrl = imageUrl == null ? null : at.resolveUri(imageUrl);
    final picture = pictureUrl == null ? null : await _picture(pictureUrl);
    final kind =
        video?.kind ??
        (picture?.image.animated == true
            ? LinkKind.gif
            : meta['og:type']?.startsWith('video') == true
            ? LinkKind.video
            : LinkKind.page);
    // The picture goes along as the site has it too: a GIF to play in the
    // chat, or a still one for the viewer. Not an icon, nor the picture of a
    // video, which opens the video on the site.
    final keep =
        picture != null &&
        video == null &&
        (kind == LinkKind.gif ||
            (kind == LinkKind.page && max(picture.image.width, picture.image.height) >= LinkPreview.iconSize));
    return LinkPreviewDraft(
      url: address,
      kind: kind,
      title: title,
      description: description,
      site: _clean(meta['og:site_name'], LinkPreview.maxSite),
      color: _color(meta['theme-color']),
      picture: picture?.image.picture ?? video?.frame,
      media: video?.media ?? (keep ? await _keep(picture.bytes, picture.image) : null),
      source:
          video?.source ??
          (kind == LinkKind.gif && picture != null
              ? _source(pictureUrl!, picture.image.mime!, width: picture.image.width, height: picture.image.height)
              : null),
    );
  }

  /// The image at [url], with what it is; null if there is none to be had.
  Future<({Uint8List bytes, LinkImage image})?> _picture(Uri? url) async {
    if (url == null || !canPreview(url)) return null;
    try {
      final (response, _) = await _get(url, accept: 'image/*');
      final type = (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (!type.startsWith('image/')) {
        _drop(response);
        return null;
      }
      final bytes = await _read(response, _imageBytes, whole: true);
      final image = bytes == null ? null : await linkImage(bytes);
      return image == null ? null : (bytes: bytes!, image: image);
    } on Exception {
      return null;
    }
  }

  /// [bytes], the [image] as the site has it, saved to go with the message;
  /// null if not every app can show it as it is.
  Future<LinkMediaFile?> _keep(Uint8List bytes, LinkImage image) async {
    final mime = image.mime;
    if (mime == null) return null;
    final file = await _newMediaFile();
    await file.writeAsBytes(bytes);
    return LinkMediaFile(path: file.path, mime: mime, size: bytes.length, width: image.width, height: image.height);
  }

  /// The video file at [url] that a page embeds, if it is one: where it is,
  /// and the file itself unless it is too large to go with the message.
  Future<({LinkSource source, LinkMediaFile? media, LinkKind kind, LinkPicture? frame})?> _pageVideo(
    Uri url, {
    int? width,
    int? height,
  }) async {
    if (!canPreview(url)) return null;
    try {
      final (response, _) = await _get(url, accept: 'video/*');
      final type = (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (!type.startsWith('video/')) {
        _drop(response);
        return null;
      }
      final video = await _video(response, type, width: width, height: height);
      if (video == null) return null;
      final media = video.media;
      return (
        source: _source(
          url,
          type,
          width: media?.width ?? width,
          height: media?.height ?? height,
          durationMs: media?.durationMs,
        ),
        media: media,
        kind: video.kind,
        frame: video.frame,
      );
    } on Exception {
      return null;
    }
  }

  /// [url] (of a [mime] file [width] by [height]) as a [LinkSource].
  static LinkSource _source(Uri url, String mime, {int? width, int? height, int? durationMs}) =>
      LinkSource(url: '$url', mime: mime, width: width, height: height, durationMs: durationMs);

  /// The video [response] brings, saved to go with the message: without the
  /// file if it is larger than [maxMediaBytes] (or does not all come); null if
  /// the player finds no picture in it. One without sound plays like a GIF.
  Future<({LinkMediaFile? media, LinkKind kind, LinkPicture? frame})?> _video(
    http.StreamedResponse response,
    String mime, {
    int? width,
    int? height,
  }) async {
    const tooLarge = (media: null, kind: LinkKind.video, frame: null);
    if ((response.contentLength ?? 0) > maxMediaBytes) {
      _drop(response);
      return tooLarge;
    }
    final file = await _newMediaFile();
    final sink = file.openWrite();
    var size = 0;
    var whole = true;
    try {
      // Leaving the loop early cancels the download.
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        size += chunk.length;
        if (size > maxMediaBytes) {
          whole = false;
          break;
        }
        sink.add(chunk);
      }
    } on Exception {
      whole = false;
    } finally {
      await sink.close();
    }
    final probe = probeVideo;
    Future<VideoInfo?> probing(VideoProbe probe) async => probe(file.path);
    final info = !whole || probe == null
        ? null
        : await probing(probe)
              .timeout(const Duration(seconds: 15), onTimeout: () => null)
              .catchError((Object _) => null);
    if (!whole || (probe != null && info?.width == null)) {
      await file.delete();
      return whole ? null : tooLarge;
    }
    final frame = info?.frameJpeg;
    return (
      media: LinkMediaFile(
        path: file.path,
        mime: mime,
        size: size,
        width: info?.width ?? width,
        height: info?.height ?? height,
        durationMs: info?.duration?.inMilliseconds,
      ),
      kind: info?.hasAudio == false ? LinkKind.gif : LinkKind.video,
      frame: frame == null ? null : await linkThumbnail(frame),
    );
  }

  /// A new file in [_mediaDir], after clearing out those older than a day.
  Future<File> _newMediaFile() async {
    await _mediaDir.create(recursive: true);
    final old = DateTime.now().subtract(const Duration(days: 1));
    await for (final entry in _mediaDir.list()) {
      try {
        if (entry is File && entry.statSync().modified.isBefore(old)) await entry.delete();
      } on FileSystemException {
        // Someone else's to clear.
      }
    }
    return File('${_mediaDir.path}/${newUlid()}');
  }

  /// A page's `theme-color` as `#rrggbb`, if it is one.
  static String? _color(String? value) {
    var color = value?.trim().toLowerCase();
    if (color != null && RegExp(r'^#[0-9a-f]{3}$').hasMatch(color)) {
      color = '#${color[1] * 2}${color[2] * 2}${color[3] * 2}';
    }
    return color != null && LinkPreview.isLinkColor(color) ? color : null;
  }

  /// A successful response from [url], following up to five redirects as
  /// long as they stay previewable. Throws otherwise. With [range] (an HTTP
  /// `Range`), a part of it is success too.
  Future<(http.StreamedResponse, Uri)> _get(Uri url, {required String accept, String? range}) async {
    for (var hops = 0; hops <= 5; hops++) {
      if (!canPreview(url)) throw const _NoPreview();
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['user-agent'] = _userAgent
        ..headers['accept'] = accept;
      if (range != null) request.headers['range'] = range;
      final response = await _client.send(request).timeout(const Duration(seconds: 10));
      final location = response.headers['location'];
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode) && location != null) {
        _drop(response);
        url = url.resolve(location);
        continue;
      }
      if (response.statusCode != 200 && !(range != null && response.statusCode == 206)) {
        _drop(response);
        throw const _NoPreview();
      }
      return (response, url);
    }
    throw const _NoPreview();
  }

  /// Up to [max] bytes of [response]'s body; with [whole], null if it is
  /// longer.
  static Future<Uint8List?> _read(http.StreamedResponse response, int max, {bool whole = false}) async {
    if (whole && (response.contentLength ?? 0) > max) {
      _drop(response);
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    // Leaving the loop early cancels the download.
    await for (final chunk in response.stream.timeout(const Duration(seconds: 10))) {
      bytes.add(chunk);
      if (bytes.length > max) break;
    }
    if (bytes.length <= max) return bytes.takeBytes();
    return whole ? null : Uint8List.sublistView(bytes.takeBytes(), 0, max);
  }

  /// The start of [response]'s page, up to the end of its head or
  /// [_pageBytes].
  static Future<Uint8List> _readHead(http.StreamedResponse response) async {
    final bytes = BytesBuilder(copy: false);
    // The last bytes read, in case "</head" is split between two chunks.
    var tail = '';
    // Leaving the loop early cancels the download.
    await for (final chunk in response.stream.timeout(const Duration(seconds: 10))) {
      bytes.add(chunk);
      final text = tail + latin1.decode(chunk).toLowerCase();
      if (text.contains('</head') || bytes.length >= _pageBytes) break;
      tail = text.substring(max(0, text.length - 5));
    }
    final all = bytes.takeBytes();
    return all.length <= _pageBytes ? all : Uint8List.sublistView(all, 0, _pageBytes);
  }

  /// Downloads the file at [address] (a previewable link) into [dir] as
  /// [name], made safe as a file name. Throws an [AttachmentException] if it
  /// cannot, if the file is larger than [maxBytes], or if it is not of [type]
  /// (e.g. `image/`) when that is given.
  Future<File> download(
    String address,
    Directory dir, {
    required String name,
    required int maxBytes,
    String? type,
    void Function(double progress)? onProgress,
  }) async {
    final url = Uri.tryParse(address);
    if (url == null || !canPreview(url)) throw const AttachmentException('This link cannot be downloaded');
    final http.StreamedResponse response;
    try {
      (response, _) = await _get(url, accept: type == null ? '*/*' : '$type*');
    } on Exception {
      throw AttachmentException('Could not download from ${url.host}');
    }
    final sent = (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    if (type != null && !sent.startsWith(type)) {
      _drop(response);
      throw AttachmentException('${url.host} sent something else');
    }
    final tooLarge = AttachmentException('The file is larger than ${maxBytes ~/ (1024 * 1024)} MB');
    final total = response.contentLength;
    if ((total ?? 0) > maxBytes) {
      _drop(response);
      throw tooLarge;
    }
    await dir.create(recursive: true);
    final file = File('${dir.path}/${_safeName(name)}');
    final sink = file.openWrite();
    var length = 0;
    try {
      // Leaving the loop early cancels the download.
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        length += chunk.length;
        if (length > maxBytes) throw tooLarge;
        sink.add(chunk);
        if (total != null && total > 0) onProgress?.call(length / total);
      }
    } on AttachmentException {
      rethrow;
    } on Exception {
      throw AttachmentException('The download from ${url.host} was interrupted');
    } finally {
      await sink.close();
    }
    return file;
  }

  /// The largest picture or GIF loaded from its site for the viewer (see
  /// [loadSource]); videos stream instead.
  static const maxSourceBytes = 100 << 20;

  /// Downloads the picture or GIF of [source], which the user chose to load
  /// from its site, for the viewer. Throws an [AttachmentException] if it
  /// cannot.
  Future<File> loadSource(LinkSource source, {void Function(double progress)? onProgress}) async {
    final file = await _newMediaFile();
    return download(
      source.url,
      file.parent,
      name: file.uri.pathSegments.last,
      maxBytes: maxSourceBytes,
      type: 'image/',
      onProgress: onProgress,
    );
  }

  /// Starts streaming the video at [address], which the user chose to load
  /// from its site (see [LinkMediaStream]). Throws an [AttachmentException]
  /// if it is not a video this device can fetch.
  Future<LinkMediaStream> stream(String address) async {
    final url = Uri.tryParse(address);
    if (url == null || !canPreview(url)) throw const AttachmentException('This video cannot be loaded');
    // Where it is, after any redirects, and that it is a video at all.
    final Uri at;
    final String type;
    try {
      final (response, found) = await _get(url, accept: 'video/*', range: 'bytes=0-0');
      _drop(response);
      (at, type) = (found, (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase());
    } on Exception {
      throw AttachmentException('Could not load it from ${url.host}');
    }
    if (!type.startsWith('video/')) throw AttachmentException('${url.host} sent something else');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final path = '/${newUlid()}';
    server.listen((request) => unawaited(_relay(request, path, at)));
    return LinkMediaStream._(server, Uri.http('${server.address.address}:${server.port}', path));
  }

  /// Answers the player's [request] for [path] with what the site has at
  /// [url]: the part it asks for, so it can seek.
  Future<void> _relay(HttpRequest request, String path, Uri url) async {
    final response = request.response;
    try {
      if (request.uri.path != path || (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final http.StreamedResponse upstream;
      try {
        (upstream, _) = await _get(url, accept: 'video/*', range: request.headers.value(HttpHeaders.rangeHeader));
      } on Exception {
        response.statusCode = HttpStatus.badGateway;
        return;
      }
      response
        ..statusCode = upstream.statusCode
        ..contentLength = upstream.contentLength ?? -1;
      for (final name in const ['content-type', 'content-range', 'accept-ranges']) {
        final value = upstream.headers[name];
        if (value != null) response.headers.set(name, value);
      }
      if (request.method == 'HEAD') {
        _drop(upstream);
        return;
      }
      await response.addStream(upstream.stream);
    } on Exception {
      // The player went away (it seeks with a new request, or closed).
    } finally {
      await response.close().then((_) {}, onError: (Object _) {});
    }
  }

  /// [name] (from a website) as the name of a file in a folder of its own:
  /// no folders, nothing hidden.
  static String _safeName(String name) {
    var safe = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_');
    if (safe.length > 100) safe = safe.substring(safe.length - 100); // Keeps the extension.
    safe = safe.replaceFirst(RegExp(r'^[.\s]+'), '').trim();
    return safe.isEmpty ? 'file' : safe;
  }

  /// Stops downloading [response]'s body.
  static void _drop(http.StreamedResponse response) =>
      unawaited(response.stream.listen(null, onError: (Object _) {}).cancel());

  void close() => _client.close();
}

/// A link's video, streamed from its site for the player, which the user
/// chose to load from there. The player only ever contacts [address], a
/// server on this device that nothing else can reach; it fetches from the
/// site under the same rules as previews (HTTPS, public hosts, also after
/// redirects), passing on the player's range requests so it can seek.
class LinkMediaStream {
  LinkMediaStream._(this._server, this.address);

  final HttpServer _server;

  /// For the player.
  final Uri address;

  /// Stops it, also what the player is still loading.
  Future<void> close() => _server.close(force: true);
}

/// The name of the file in [response] from [at].
String? _fileName(http.StreamedResponse response, Uri at) {
  final disposition = response.headers['content-disposition'] ?? '';
  final encoded = RegExp(r"filename\*\s*=\s*UTF-8''([^;]+)", caseSensitive: false).firstMatch(disposition);
  final quoted = RegExp(
    r'filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;]+)',
    caseSensitive: false,
  ).firstMatch(disposition);
  String? decoded(String? s) {
    try {
      return s == null ? null : Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    }
  }

  final name =
      decoded(encoded?[1]) ??
      quoted?[1] ??
      quoted?[2] ??
      decoded(at.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => ''));
  return _clean(name, LinkPreview.maxTitle);
}

/// [bytes] of a page as text, in the character set it names (UTF-8 if none
/// or one this device does not know).
String _decode(Uint8List bytes, String? contentType) {
  final declared = RegExp(r'charset\s*=\s*"?([\w.:-]+)', caseSensitive: false);
  final start = latin1.decode(Uint8List.sublistView(bytes, 0, bytes.length < 2048 ? bytes.length : 2048));
  final charset = declared.firstMatch(contentType ?? '')?[1] ?? declared.firstMatch(start)?[1];
  final encoding = charset == null ? null : Encoding.getByName(charset.toLowerCase());
  if (encoding != null && encoding != utf8) {
    try {
      return encoding.decode(bytes);
    } on FormatException {
      // Not what it said it was.
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// The page's `<meta>` properties and names (the first of each), with its
/// `<title>` as `title`.
Map<String, String> _pageMeta(String page) {
  final head = page.toLowerCase().indexOf('</head');
  final document = html.parse(head < 0 ? page : page.substring(0, head));
  final meta = <String, String>{};
  for (final tag in document.querySelectorAll('meta')) {
    final key = (tag.attributes['property'] ?? tag.attributes['name'])?.toLowerCase();
    final content = tag.attributes['content'];
    if (key != null && content != null && content.trim().isNotEmpty) {
      meta.putIfAbsent(key, () => content);
    }
  }
  final title = document.querySelector('title')?.text;
  if (title != null) meta['title'] = title;
  return meta;
}

/// [value] on one line, at most [max] characters; null if there is nothing.
String? _clean(Object? value, int max) {
  if (value is! String) return null;
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  if (text.length <= max) return text;
  var end = max - 1;
  // Not between the two halves of a character outside the BMP.
  if (text.codeUnitAt(end - 1) & 0xFC00 == 0xD800) end--;
  return '${text.substring(0, end)}…';
}
