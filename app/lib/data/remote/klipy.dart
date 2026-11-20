import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hanashi_protocol/hanashi_protocol.dart';

/// A GIF among search results: a small version for the grid, and the one a
/// message carries.
class GifResult {
  const GifResult({required this.preview, required this.full});

  final RemoteMedia preview;
  final RemoteMedia full;
}

class GifPage {
  const GifPage(this.items, {required this.hasNext});

  final List<GifResult> items;
  final bool hasNext;
}

/// Where the GIF tab finds GIFs.
abstract interface class GifSearch {
  Future<GifPage> trending({int page = 1});

  Future<GifPage> search(String query, {int page = 1});
}

/// GIF search failed; [message] is for the user.
class GifSearchException implements Exception {
  const GifSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// KLIPY's GIF API, called from this device: KLIPY does not allow calls
/// through a server. No user ID goes with them, so KLIPY sees this device's
/// IP address and what it searches for, but not who the user is.
class KlipyGifSearch implements GifSearch {
  KlipyGifSearch(this.apiKey, {this.locale, http.Client? client}) : _client = client ?? http.Client();

  final String apiKey;

  /// The user's country (ISO 3166 alpha-2), for local trending GIFs.
  final String? locale;
  final http.Client _client;

  static final _api = Uri.parse('https://api.klipy.com/api/v1/');
  static const perPage = 24;

  @override
  Future<GifPage> trending({int page = 1}) => _get('trending', {'page': '$page'});

  @override
  Future<GifPage> search(String query, {int page = 1}) => _get('search', {'q': query, 'page': '$page'});

  Future<GifPage> _get(String endpoint, Map<String, String> query) async {
    final uri = _api
        .resolve('${Uri.encodeComponent(apiKey)}/gifs/$endpoint')
        .replace(queryParameters: {...query, 'per_page': '$perPage', 'locale': ?locale});
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(const Duration(seconds: 15));
    } on Exception {
      throw const GifSearchException('Cannot reach KLIPY');
    }
    if (response.statusCode != 200) throw GifSearchException('KLIPY answered with an error (${response.statusCode})');
    try {
      return parse(jsonDecode(utf8.decode(response.bodyBytes)));
    } on Object {
      throw const GifSearchException('KLIPY sent something unexpected');
    }
  }

  /// A search or trending response:
  /// `{"result": true, "data": {"data": [item...], "has_next": bool}}`, each
  /// item `{"slug", "title", "type", "file": {size: {format: {url, width,
  /// height, size}}}}` with sizes hd, md, sm and xs.
  static GifPage parse(Object? json) {
    final data = ((json! as Map)['data'] as Map?) ?? const {};
    final items = <GifResult>[];
    for (final item in (data['data'] as List?) ?? const []) {
      if (item is! Map) continue;
      // Ads (only with ads turned on for the key) need KLIPY's ad views.
      if (item['type'] == 'ad') continue;
      final slug = item['slug'], file = item['file'];
      if (slug is! String || file is! Map) continue;
      final title = switch (item['title']) {
        final String t when t.length > RemoteMedia.maxTitle => t.substring(0, RemoteMedia.maxTitle),
        final String t when t.isNotEmpty => t,
        _ => null,
      };
      RemoteMedia? pick(List<String> sizes) {
        for (final size in sizes) {
          for (final format in ['webp', 'gif']) {
            final formats = file[size];
            if (formats is! Map) continue;
            if (formats[format] case {'url': final String url, 'width': final int w, 'height': final int h}
                when w > 0 && h > 0 && RemoteMedia.isAllowed(RemoteMedia.klipy, Uri.parse(url))) {
              return RemoteMedia(
                provider: RemoteMedia.klipy,
                id: slug,
                url: url,
                mime: 'image/$format',
                width: w,
                height: h,
                title: title,
              );
            }
          }
        }
        return null;
      }

      final preview = pick(['sm', 'xs', 'md', 'hd']), full = pick(['md', 'sm', 'hd']);
      if (preview != null && full != null) items.add(GifResult(preview: preview, full: full));
    }
    return GifPage(items, hasNext: data['has_next'] == true);
  }

  void close() => _client.close();
}
