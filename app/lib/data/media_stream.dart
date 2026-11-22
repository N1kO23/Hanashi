import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../e2ee/file_cipher.dart';
import '../e2ee/primitives.dart';

/// A video or audio file in the media cache, streamed to the player and
/// decrypted as it plays, so that no decrypted copy is ever written. The
/// player only contacts [address]: a server on this device's loopback, at a
/// path nobody can guess, which answers the parts it asks for (so it can
/// seek), decrypting just the chunks they need. It runs in an isolate of its
/// own: a player reads ahead as fast as it can, which would hold up the UI.
class EncryptedMediaStream {
  EncryptedMediaStream._(this._isolate, this._control, this.address);

  final Isolate _isolate;
  final SendPort _control;

  /// For the player.
  final Uri address;

  /// Streams [path], a blob from the media cache, as [mime]: encrypted with
  /// [key] (see [FileCipher]), or as it is without one. Throws
  /// [DecryptionFailed] if it does not decrypt, before anything plays.
  static Future<EncryptedMediaStream> start(String path, {Uint8List? key, required String mime}) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, (ready.sendPort, path, key, mime), debugName: 'media stream');
    final answer = await ready.first;
    ready.close();
    switch (answer) {
      case (final SendPort control, final int port, final String secret):
        return EncryptedMediaStream._(isolate, control, Uri.http('127.0.0.1:$port', '/$secret'));
      case final String failure:
        isolate.kill();
        throw DecryptionFailed(failure);
      default:
        isolate.kill();
        throw StateError('The media stream did not start');
    }
  }

  /// Stops it, also what the player is still loading.
  Future<void> close() async {
    final done = ReceivePort();
    _control.send(done.sendPort);
    await done.first.timeout(const Duration(seconds: 2), onTimeout: () => _isolate.kill());
    done.close();
  }
}

/// What a stream reads from: a [FileCipherReader], or a plain file.
abstract interface class _Source {
  int get length;
  Stream<List<int>> read(int start, int end);
  void close();
}

class _Decrypted implements _Source {
  _Decrypted(this._reader);

  final FileCipherReader _reader;

  @override
  int get length => _reader.length;

  @override
  Stream<List<int>> read(int start, int end) => _reader.read(start, end);

  @override
  void close() => _reader.close();
}

class _Plain implements _Source {
  _Plain(this._file) : length = _file.lengthSync();

  final RandomAccessFile _file;

  @override
  final int length;

  @override
  Stream<List<int>> read(int start, int end) async* {
    const step = 64 * 1024;
    for (var at = start; at < end; at += step) {
      // Read at once: another request may move the position in between.
      _file.setPositionSync(at);
      yield _file.readSync(min(step, end - at));
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  void close() => _file.closeSync();
}

Future<void> _serve((SendPort, String, Uint8List?, String) setup) async {
  final (ready, path, key, mime) = setup;
  final _Source source;
  try {
    source = key == null ? _Plain(File(path).openSync()) : _Decrypted(await FileCipherReader.open(path, key));
  } on DecryptionFailed catch (e) {
    return ready.send(e.message);
  } on FileSystemException catch (e) {
    return ready.send('The file is not here: ${e.message}');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final secret = base64Url.encode(randomBytes(24));
  final control = ReceivePort();
  control.listen((message) async {
    control.close();
    await server.close(force: true);
    source.close();
    if (message is SendPort) message.send(null);
  });
  server.listen((request) => unawaited(_answer(request, '/$secret', source, mime)));
  ready.send((control.sendPort, server.port, secret));
}

/// Answers the player's [request] for [path]: all of it, or the one range it
/// asks for.
Future<void> _answer(HttpRequest request, String path, _Source source, String mime) async {
  final response = request.response;
  try {
    if (request.uri.path != path || (request.method != 'GET' && request.method != 'HEAD')) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final length = source.length;
    response.headers
      ..contentType = ContentType.parse(mime)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    var (start, end) = (0, length);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final asked = _range(range, length);
      if (asked == null) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return;
      }
      (start, end) = asked;
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$length');
    }
    response.contentLength = end - start;
    if (request.method == 'GET') await response.addStream(source.read(start, end));
  } on Exception {
    // The player went away (it seeks with a new request, or closed).
  } on Error {
    // The stream closed while answering.
  } finally {
    await response.close().then((_) {}, onError: (Object _) {});
  }
}

/// The part `bytes=first-last`, `bytes=first-` or `bytes=-suffix` asks for, as
/// start and end (exclusive); null if it is none of [length]'s.
(int, int)? _range(String header, int length) {
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) return null;
  final first = int.tryParse(match[1]!), last = int.tryParse(match[2]!);
  if (first == null) {
    if (last == null || last == 0) return null;
    return (max(0, length - last), length);
  }
  if (first >= length || (last != null && last < first)) return null;
  return (first, last == null ? length : min(last + 1, length));
}
