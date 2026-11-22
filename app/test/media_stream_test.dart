import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/media_cache.dart';
import 'package:hanashi/data/media_stream.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi/e2ee/file_cipher.dart';
import 'package:hanashi/e2ee/primitives.dart';

/// What a player gets from [uri]: the status, the headers it looks at, and
/// the body.
Future<(int, Map<String, String?>, List<int>)> _fetch(Uri uri, {String? range, String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = await response.fold<List<int>>([], (all, part) => all..addAll(part));
    return (
      response.statusCode,
      {
        for (final name in ['content-length', 'content-range', 'content-type', 'accept-ranges'])
          name: response.headers.value(name),
      },
      body,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_stream_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(Uint8List, String, Uint8List)> sealed(int size) async {
    final data = randomBytes(size), key = randomBytes(32);
    File('${dir.path}/plain').writeAsBytesSync(data);
    await FileCipher.encrypt('${dir.path}/plain', '${dir.path}/sealed', key);
    return (data, '${dir.path}/sealed', key);
  }

  test('streams an encrypted file decrypted, in the parts a player asks for', () async {
    final (data, path, key) = await sealed(FileCipher.chunkSize * 2 + 1234);
    final length = data.length;
    final stream = await EncryptedMediaStream.start(path, key: key, mime: 'video/mp4');
    addTearDown(stream.close);
    expect(stream.address.host, '127.0.0.1');
    // At a path nobody can guess.
    expect(stream.address.path.length, greaterThan(30));

    final (status, headers, body) = await _fetch(stream.address);
    expect(
      (status, headers['content-length'], headers['content-type'], headers['accept-ranges']),
      (200, '$length', 'video/mp4', 'bytes'),
    );
    expect(body, data);

    for (final (range, start, end) in [
      ('bytes=100-199', 100, 200),
      ('bytes=70000-', 70000, length),
      ('bytes=-10', length - 10, length),
      ('bytes=0-999999999', 0, length),
    ]) {
      final (status, headers, body) = await _fetch(stream.address, range: range);
      expect((status, headers['content-range']), (206, 'bytes $start-${end - 1}/$length'), reason: range);
      expect(body, data.sublist(start, end), reason: range);
    }

    final (outside, outsideHeaders, _) = await _fetch(stream.address, range: 'bytes=$length-');
    expect((outside, outsideHeaders['content-range']), (416, 'bytes */$length'));
    final (headStatus, headHeaders, headBody) = await _fetch(stream.address, method: 'HEAD');
    expect((headStatus, headHeaders['content-length']), (200, '$length'));
    expect(headBody, isEmpty);
    final (elsewhere, _, _) = await _fetch(stream.address.replace(path: '/somewhere-else'));
    expect(elsewhere, 404);

    await stream.close();
    await expectLater(_fetch(stream.address), throwsA(isA<SocketException>()));
  });

  test('a file that does not decrypt is refused before anything plays', () async {
    final (_, path, _) = await sealed(1000);
    await expectLater(
      EncryptedMediaStream.start(path, key: randomBytes(32), mime: 'video/mp4'),
      throwsA(isA<DecryptionFailed>()),
    );
  });

  test('one sent without a key goes as it is', () async {
    final data = randomBytes(5000);
    File('${dir.path}/plain').writeAsBytesSync(data);
    final stream = await EncryptedMediaStream.start('${dir.path}/plain', mime: 'audio/ogg');
    addTearDown(stream.close);
    final (status, _, body) = await _fetch(stream.address, range: 'bytes=10-19');
    expect(status, 206);
    expect(body, data.sublist(10, 20));
  });

  group('the media cache', () {
    late ApiClient api;
    setUp(() => api = ApiClient('http://127.0.0.1:1'));
    tearDown(() => api.close());

    test('keeps what it is given encrypted, and decrypts it only into memory', () async {
      final (data, path, key) = await sealed(3000);
      final cache = MediaCache(Directory('${dir.path}/media'), api);
      final hash = 'sha256:${'ab' * 32}';
      await cache.put(hash, File(path));
      expect(cache.cached(hash)!.readAsBytesSync(), File(path).readAsBytesSync());
      expect(await cache.bytes(hash, key: key), data);
      await cache.decryptTo(hash, '${dir.path}/saved', key: key);
      expect(File('${dir.path}/saved').readAsBytesSync(), data);
    });

    test('keeps what it decrypted lately, as the same bytes, within its limit', () async {
      final cache = MediaCache(Directory('${dir.path}/media'), api, keptBytes: 2000);
      final keys = <String, Uint8List>{};
      Future<String> blobOf(int size) async {
        final (_, path, key) = await sealed(size);
        final hash = 'sha256:${(keys.length + 10).toRadixString(16).padLeft(64, '0')}';
        await cache.put(hash, File(path));
        keys[hash] = key;
        return hash;
      }

      final first = await blobOf(500);
      final shown = await cache.bytes(first, key: keys[first]);
      expect(identical(await cache.bytes(first, key: keys[first]), shown), isTrue, reason: 'shown again');
      // Three more fill it; one more leaves out the one shown longest ago.
      for (final hash in [await blobOf(500), await blobOf(500), await blobOf(500)]) {
        await cache.bytes(hash, key: keys[hash]);
      }
      expect(identical(await cache.bytes(first, key: keys[first]), shown), isTrue, reason: 'still within the limit');
      final fifth = await blobOf(500);
      await cache.bytes(fifth, key: keys[fifth]);
      final second = keys.keys.elementAt(1);
      final again = await cache.bytes(second, key: keys[second]);
      expect(identical(await cache.bytes(second, key: keys[second]), again), isTrue);
      // One too large for it is not kept (asked for again once the first is done).
      final large = await blobOf(600);
      final once = await cache.bytes(large, key: keys[large]);
      await Future<void>.delayed(Duration.zero);
      expect(identical(await cache.bytes(large, key: keys[large]), once), isFalse);
      // Removed: neither the blob nor what was decrypted of it stays.
      await cache.remove(first);
      await expectLater(cache.bytes(first, key: keys[first]), throwsA(isA<ApiException>()));
    });

    test('forgets what versions before kept decrypted, but not what is still to be sent', () async {
      final media = Directory('${dir.path}/media');
      final decrypted = File('${media.path}/ab/${'ab' * 32}')
        ..createSync(recursive: true)
        ..writeAsStringSync('a photo, decrypted');
      final half = File('${media.path}/cd/${'cd' * 32}.plain')..createSync(recursive: true);
      final waiting = File('${media.path}/outgoing/${'ef' * 32}')..createSync(recursive: true);
      final blob = File('${media.path}/blobs/12/${'12' * 32}')..createSync(recursive: true);
      MediaCache(media, api);
      // It does so by itself, as it starts.
      for (var i = 0; i < 100 && decrypted.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((decrypted.existsSync(), half.existsSync()), (false, false));
      expect((waiting.existsSync(), blob.existsSync()), (true, true));
      expect(media.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toSet(), {
        'outgoing',
        'blobs',
      });
    });
  });
}
