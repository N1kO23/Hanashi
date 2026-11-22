import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hashlib/hashlib.dart';

import '../e2ee/file_cipher.dart';
import 'decrypted_cache.dart';
import 'media_stream.dart';
import 'remote/api_client.dart';

/// Media blobs as the server has them, by their hash: encrypted, each with a
/// key that only the messages naming it hold, in the encrypted database. So
/// the cache is no more readable than the server's copy, and nothing here is
/// ever decrypted to the disk: [bytes] decrypts into memory, [stream] for a
/// player as it plays, and [decryptTo] only where the user saves a file. A
/// blob never changes, so a cached one is valid forever; downloads are
/// verified against their hash.
class MediaCache {
  /// Under [dir], which holds nothing else. [keptBytes] is how much of what
  /// it decrypted it keeps in memory (see [bytes]).
  MediaCache(Directory dir, this.api, {this.keptBytes = 48 << 20})
    : root = Directory('${dir.path}/blobs'),
      outgoing = Directory('${dir.path}/outgoing') {
    unawaited(_forgetDecrypted(dir));
  }

  /// At most this much decrypted media stays in memory; a file larger than a
  /// quarter of it is not kept.
  final int keptBytes;

  /// What [bytes] decrypted lately, by hash and key.
  late final _decrypted = DecryptedCache(maxBytes: keptBytes);

  final Directory root;

  /// Encrypted files the outbox has yet to upload.
  final Directory outgoing;
  final ApiClient api;
  final _inFlight = <String, Future<File>>{};

  File fileFor(String hash) {
    final hex = hash.substring('sha256:'.length);
    return File('${root.path}/${hex.substring(0, 2)}/$hex');
  }

  /// The blob of [hash], if it is here.
  File? cached(String hash) {
    final file = fileFor(hash);
    return file.existsSync() ? file : null;
  }

  /// The blob of [hash], downloading it first if needed: from [host]'s server
  /// if that is not this user's (see [MediaRef.host]). [onProgress] receives
  /// 0..1 when the size is known. With [maxBytes], a download that turns out
  /// larger (whatever its message claimed) stops.
  Future<File> blob(String hash, {String? host, int? maxBytes, void Function(double progress)? onProgress}) {
    final file = cached(hash);
    if (file != null) return Future.value(file);
    // Block body on purpose: `remove` returns this very future, and
    // whenComplete would wait for it, i.e. for itself, forever.
    return _inFlight.putIfAbsent(
      hash,
      () => _download(hash, host, maxBytes, onProgress).whenComplete(() {
        _inFlight.remove(hash);
      }),
    );
  }

  /// The blob of [hash] decrypted with [key] into memory (as it is without
  /// one), downloading it first if needed (see [blob]). Throws
  /// [DecryptionFailed] if [key] does not open it.
  ///
  /// What it decrypted lately it keeps (see [keptBytes]), and hands out again
  /// as the very same bytes: a picture shown again, scrolling back up a chat,
  /// is not decrypted again, nor decoded again (Flutter's image cache knows
  /// one by its bytes).
  Future<Uint8List> bytes(
    String hash, {
    Uint8List? key,
    String? host,
    int? maxBytes,
    void Function(double progress)? onProgress,
  }) {
    final id = key == null ? hash : '$hash ${base64.encode(key)}';
    return _decrypted.get(id, () async {
      final file = await blob(hash, host: host, maxBytes: maxBytes, onProgress: onProgress);
      return key == null ? file.readAsBytes() : FileCipher.decryptBytes(file.path, key);
    });
  }

  /// The blob of [hash] decrypted with [key] into [path], as [bytes] does.
  Future<void> decryptTo(
    String hash,
    String path, {
    Uint8List? key,
    String? host,
    void Function(double progress)? onProgress,
  }) async {
    final file = await blob(hash, host: host, onProgress: onProgress);
    if (key == null) {
      await file.copy(path);
    } else {
      await FileCipher.decrypt(file.path, path, key);
    }
  }

  /// The blob of [hash] streamed to a player as [mime] (see
  /// [EncryptedMediaStream]), downloading it first if needed.
  Future<EncryptedMediaStream> stream(
    String hash, {
    Uint8List? key,
    required String mime,
    String? host,
    void Function(double progress)? onProgress,
  }) async {
    final file = await blob(hash, host: host, onProgress: onProgress);
    return EncryptedMediaStream.start(file.path, key: key, mime: mime);
  }

  Future<File> _download(String hash, String? host, int? maxBytes, void Function(double)? onProgress) async {
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
    return part.rename(target.path);
  }

  /// Forgets the blob of [hash] (its message was deleted).
  Future<void> remove(String hash) async {
    _decrypted.forget((id) => id.startsWith(hash));
    try {
      await cached(hash)?.delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  /// Adds [encrypted], a blob this device uploaded (or is about to), under
  /// its [hash]: shown from here without downloading it.
  Future<File> put(String hash, File encrypted) async {
    final target = fileFor(hash);
    if (target.existsSync()) return target;
    await target.parent.create(recursive: true);
    final part = await encrypted.copy('${target.path}.part');
    return part.rename(target.path);
  }

  /// Deletes what versions before 1.0.3 kept in [dir]: media decrypted, beside
  /// [root] and [outgoing]. Anything still on the server is downloaded again
  /// when needed.
  Future<void> _forgetDecrypted(Directory dir) async {
    try {
      if (!dir.existsSync()) return;
      await for (final entry in dir.list()) {
        if (entry.path == root.path || entry.path == outgoing.path) continue;
        await entry.delete(recursive: true).catchError((Object _) => entry);
      }
    } on FileSystemException {
      // Another engine (the push engine, say) is at it too.
    }
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
