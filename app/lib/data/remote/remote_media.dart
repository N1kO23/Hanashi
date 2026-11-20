import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hanashi_protocol/hanashi_protocol.dart';

class RemoteMediaException implements Exception {
  const RemoteMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Loads [RemoteMedia] from its provider and keeps it in memory only:
/// providers do not allow keeping copies. Only the provider's own hosts are
/// contacted, also when a response redirects elsewhere.
class RemoteMediaLoader {
  RemoteMediaLoader({http.Client? client, this.maxBytes = 15 << 20, this.cacheBytes = 64 << 20})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// The largest file loaded.
  final int maxBytes;

  /// How much stays in memory; the least recently used goes first.
  final int cacheBytes;

  /// Oldest first (map literals keep their order).
  final _cache = <String, Uint8List>{};
  var _cached = 0;
  final _inFlight = <String, Future<Uint8List>>{};

  /// What is in memory already; never loads.
  Uint8List? cached(RemoteMedia media) {
    final bytes = _cache.remove(media.url);
    if (bytes != null) _cache[media.url] = bytes;
    return bytes;
  }

  Future<Uint8List> load(RemoteMedia media) {
    final bytes = cached(media);
    if (bytes != null) return Future.value(bytes);
    // Block body on purpose: `remove` returns this very future.
    return _inFlight.putIfAbsent(
      media.url,
      () => _fetch(media).whenComplete(() {
        _inFlight.remove(media.url);
      }),
    );
  }

  Future<Uint8List> _fetch(RemoteMedia media) async {
    var url = Uri.parse(media.url);
    for (var hops = 0; hops < 5; hops++) {
      if (!RemoteMedia.isAllowed(media.provider, url)) {
        throw RemoteMediaException('Not an address of ${media.provider}: ${url.host}');
      }
      final http.StreamedResponse response;
      try {
        response = await _client.send(http.Request('GET', url)..followRedirects = false).timeout(
          const Duration(seconds: 20),
        );
      } on Exception {
        throw RemoteMediaException('Cannot reach ${media.provider}');
      }
      final location = response.headers['location'];
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode) && location != null) {
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        url = url.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        throw RemoteMediaException('${media.provider} answered with an error (${response.statusCode})');
      }
      return _remember(media.url, await _read(response));
    }
    throw const RemoteMediaException('Too many redirects');
  }

  Future<Uint8List> _read(http.StreamedResponse response) async {
    if ((response.contentLength ?? 0) > maxBytes) throw const RemoteMediaException('The file is too large');
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) throw const RemoteMediaException('The file is too large');
      }
    } on RemoteMediaException {
      rethrow;
    } on Exception {
      throw const RemoteMediaException('The download was interrupted');
    }
    return bytes.takeBytes();
  }

  Uint8List _remember(String url, Uint8List bytes) {
    _cache[url] = bytes;
    _cached += bytes.length;
    while (_cached > cacheBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _cached -= _cache.remove(oldest)!.length;
    }
    return bytes;
  }

  void close() => _client.close();
}
