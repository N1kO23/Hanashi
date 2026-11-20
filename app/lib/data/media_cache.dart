import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hashlib/hashlib.dart';

import '../e2ee/file_cipher.dart';
import 'remote/api_client.dart';

/// Local, decrypted copies of media blobs, by the hash of the encrypted blob.
/// A blob never changes, so a cached file is valid forever; downloads are
/// verified against their hash before they are decrypted.
class MediaCache {
  MediaCache(this.root, this.api);

  final Directory root;
  final ApiClient api;
  final _inFlight = <String, Future<File>>{};

  File fileFor(String hash) {
    final hex = hash.substring('sha256:'.length);
    return File('${root.path}/${hex.substring(0, 2)}/$hex');
  }

  File? cached(String hash) {
    final file = fileFor(hash);
    return file.existsSync() ? file : null;
  }

  /// The local (decrypted) file for [hash], downloading it first if needed:
  /// from [host]'s server if that is not this user's (see [MediaRef.host]).
  /// [key] decrypts it; the download is checked against [hash] first.
  /// [onProgress] receives 0..1 when the size is known. With [maxBytes], a
  /// download that turns out larger (whatever its message claimed) stops.
  Future<File> get(
    String hash, {
    Uint8List? key,
    String? host,
    int? maxBytes,
    void Function(double progress)? onProgress,
  }) {
    final file = cached(hash);
    if (file != null) return Future.value(file);
    // Block body on purpose: `remove` returns this very future, and
    // whenComplete would wait for it, i.e. for itself, forever.
    return _inFlight.putIfAbsent(
      hash,
      () => _download(hash, key, host, maxBytes, onProgress).whenComplete(() {
        _inFlight.remove(hash);
      }),
    );
  }

  Future<File> _download(
    String hash,
    Uint8List? key,
    String? host,
    int? maxBytes,
    void Function(double)? onProgress,
  ) async {
    final target = fileFor(hash);
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    final response = await api.openMedia(hash, host: host);
    final total = response.contentLength;
    const tooLarge = ApiException(0, 'too_large', 'The file is larger than it may be');
    if (maxBytes != null && total != null && total > maxBytes) {
      unawaited(response.stream.listen(null).cancel());
      throw tooLarge;
    }
    final sink = part.openWrite();
    final hasher = sha256.createSink();
    var received = 0;
    try {
      // One that stops moving fails, rather than holding up whatever waits for it.
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (maxBytes != null && received > maxBytes) throw tooLarge;
        hasher.add(chunk);
        sink.add(chunk);
        if (total != null && total > 0) onProgress?.call(received / total);
      }
      await sink.close();
    } catch (e) {
      await sink.close().catchError((_) {});
      if (part.existsSync()) await part.delete();
      if (identical(e, tooLarge)) rethrow;
      throw const ApiException(0, 'network', 'The download was interrupted');
    }
    if ('sha256:${hasher.digest().hex()}' != hash) {
      await part.delete();
      throw const ApiException(0, 'corrupt', 'The downloaded file was damaged');
    }
    if (key == null) return part.rename(target.path);
    final plain = File('${target.path}.plain');
    try {
      await FileCipher.decrypt(part.path, plain.path, key);
    } finally {
      await part.delete();
    }
    return plain.rename(target.path);
  }

  /// Forgets the local copy of [hash] (its message was deleted).
  Future<void> remove(String hash) async {
    try {
      await cached(hash)?.delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  /// Adds a local file (e.g. one the user is sending) under its known [hash].
  Future<File> put(String hash, File source) async {
    final target = fileFor(hash);
    if (target.existsSync()) return target;
    await target.parent.create(recursive: true);
    final part = await source.copy('${target.path}.part');
    return part.rename(target.path);
  }
}

/// SHA-256 of a file as `sha256:<hex>`, computed off the UI isolate.
Future<String> hashFile(String path) => Isolate.run(() async {
  final sink = sha256.createSink();
  await for (final chunk in File(path).openRead()) {
    sink.add(chunk);
  }
  return 'sha256:${sink.digest().hex()}';
});
