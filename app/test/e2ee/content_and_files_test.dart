import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/content.dart';
import 'package:hanashi/e2ee/file_cipher.dart';
import 'package:hanashi/e2ee/padding.dart';
import 'package:hanashi/e2ee/primitives.dart';

void main() {
  group('content', () {
    final aad = Uint8List.fromList(utf8.encode('hanashi-msg-v2|id|conv|a@b|dev'));

    test('round-trips through the key that travels in MLS', () async {
      final sealed = await sealContent({
        'type': 'text',
        'body': {'text': 'hi'},
      }, aad);
      final received = ContentKey.fromBytes(sealed.contentKey.toBytes());
      expect(await openContent(received, sealed.ct, aad), {
        'type': 'text',
        'body': {'text': 'hi'},
      });
    });

    test('rejects swapped ciphertext, wrong header or wrong key', () async {
      final one = await sealContent({
        'type': 'text',
        'body': {'text': 'one'},
      }, aad);
      final two = await sealContent({
        'type': 'text',
        'body': {'text': 'two'},
      }, aad);
      await expectLater(openContent(one.contentKey, two.ct, aad), throwsA(isA<DecryptionFailed>()));
      await expectLater(
        openContent(one.contentKey, one.ct, Uint8List.fromList(utf8.encode('other header'))),
        throwsA(isA<DecryptionFailed>()),
      );
      final forged = ContentKey(key: randomBytes(32), ctHash: one.contentKey.ctHash);
      await expectLater(openContent(forged, one.ct, aad), throwsA(isA<DecryptionFailed>()));
    });

    test('is padded: the server sees only roughly how long a message is', () async {
      Future<int> sealed(String text) async => (await sealContent({
        'type': 'text',
        'body': {'text': text},
      }, aad)).ct.length;
      // Nonce and tag around 256, 512 and 8 KiB of padded JSON.
      expect([await sealed('ok'), await sealed('a' * 200)], [256 + 28, 256 + 28]);
      expect(await sealed('a' * 300), 512 + 28);
      expect(await sealed('a' * 5000), 8192 + 28);
      // Not so far that it would no longer fit in an envelope.
      expect(await sealed('a' * 46000), maxPaddedContent + 28);
      expect(await sealed('a' * 48500), 48500 + 34 + 28); // The JSON around the text is 34 bytes.
      final long = await sealContent({
        'type': 'text',
        'body': {'text': 'ä' * 3000},
      }, aad);
      expect(await openContent(long.contentKey, long.ct, aad), {
        'type': 'text',
        'body': {'text': 'ä' * 3000},
      });
    });

    test('the keys of a shared history round-trip; anything else is refused', () async {
      final sealed = await sealContent({
        'type': 'text',
        'body': {'text': 'before you came'},
      }, aad);
      const id = '01JB2Y8Q3M7W2V6T0Q9X4C5D6E';
      final keys = decodeHistoryKeys(encodeHistoryKeys({id: sealed.contentKey}));
      expect(await openContent(keys[id]!, sealed.ct, aad), {
        'type': 'text',
        'body': {'text': 'before you came'},
      });
      final k = base64.encode(randomBytes(32));
      for (final bad in [
        <String, Object?>{},
        {'keys': []},
        {
          'keys': {
            'not-an-id': {'k': k, 'h': k},
          },
        },
        {
          'keys': {
            id: {'k': k},
          },
        },
        {
          'keys': {
            id: {'k': base64.encode(randomBytes(16)), 'h': k},
          },
        },
      ]) {
        expect(() => decodeHistoryKeys(utf8.encode(jsonEncode(bad))), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('file cipher', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_files_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<Uint8List> roundTrip(Uint8List data, {Uint8List? key}) async {
      key ??= randomBytes(32);
      final plain = File('${dir.path}/plain')..writeAsBytesSync(data);
      await FileCipher.encrypt(plain.path, '${dir.path}/enc', key);
      await FileCipher.decrypt('${dir.path}/enc', '${dir.path}/dec', key);
      return File('${dir.path}/dec').readAsBytesSync();
    }

    test('round-trips empty, small, exact-chunk and multi-chunk files', () async {
      for (final size in [0, 1, 1000, FileCipher.chunkSize - 1, FileCipher.chunkSize, FileCipher.chunkSize * 2 + 17]) {
        final data = randomBytes(size);
        expect(await roundTrip(data), data, reason: 'size $size');
      }
      // Ends that look like padding stay.
      for (final data in [
        Uint8List.fromList([1, 0x80]),
        Uint8List.fromList([0x80, 0, 0]),
        Uint8List(FileCipher.chunkSize),
      ]) {
        expect(await roundTrip(data), data);
      }
    });

    test('is padded: the server sees only roughly how large a file is', () async {
      expect(padme(1000), 1024);
      expect(padme(18000), 18432);
      for (var length = 2; length < 1 << 24; length = length * 3 ~/ 2 + 1) {
        final padded = padme(length);
        expect(padded, inInclusiveRange(length, length * 1.12), reason: '$length');
      }
      final key = randomBytes(32);
      for (final size in [1000, 70000]) {
        File('${dir.path}/plain').writeAsBytesSync(randomBytes(size));
        await FileCipher.encrypt('${dir.path}/plain', '${dir.path}/enc', key);
        final padded = FileCipher.paddedLength(size);
        expect(File('${dir.path}/enc').lengthSync(), FileCipher.encryptedSize(padded));
        expect(padded, padme(size + 1));
      }
      // Never more than the server takes because of the padding.
      File('${dir.path}/plain').writeAsBytesSync(randomBytes(200000));
      await FileCipher.encrypt('${dir.path}/plain', '${dir.path}/enc', key, maxSize: 200100);
      expect(File('${dir.path}/enc').lengthSync(), lessThanOrEqualTo(200100));
      await FileCipher.decrypt('${dir.path}/enc', '${dir.path}/dec', key);
      expect(File('${dir.path}/dec').lengthSync(), 200000);
    });

    Future<void> expectBroken(void Function(List<int> bytes) damage, {Uint8List? key}) async {
      final k = randomBytes(32);
      File('${dir.path}/plain').writeAsBytesSync(randomBytes(FileCipher.chunkSize * 3));
      await FileCipher.encrypt('${dir.path}/plain', '${dir.path}/enc', k);
      final bytes = File('${dir.path}/enc').readAsBytesSync().toList();
      damage(bytes);
      File('${dir.path}/enc').writeAsBytesSync(bytes);
      await expectLater(
        FileCipher.decrypt('${dir.path}/enc', '${dir.path}/dec', key ?? k),
        throwsA(isA<DecryptionFailed>()),
      );
    }

    const chunk = FileCipher.chunkSize + 16;
    const header = 11;

    test('detects tampering, truncation, reordering, extension and wrong keys', () async {
      await expectBroken((b) => b[header + 5] ^= 1); // Flipped bit.
      await expectBroken((b) => b.removeRange(header + chunk * 2, b.length)); // Cut at a chunk boundary.
      await expectBroken((b) {
        final first = b.sublist(header, header + chunk);
        final second = b.sublist(header + chunk, header + chunk * 2);
        b.setRange(header, header + chunk, second);
        b.setRange(header + chunk, header + chunk * 2, first);
      }); // Swapped chunks.
      await expectBroken((b) => b.addAll(b.sublist(header, header + chunk))); // Extra chunk.
      await expectBroken((_) {}, key: randomBytes(32));
    });

    test('decrypts into memory, and in parts, as it does to a file', () async {
      final key = randomBytes(32);
      const size = FileCipher.chunkSize;
      for (final data in [
        Uint8List(0),
        randomBytes(1),
        Uint8List.fromList([1, 0x80]),
        Uint8List(size), // Zeros, as the padding is.
        randomBytes(size),
        randomBytes(size * 3 + 17),
      ]) {
        final reason = '${data.length} bytes';
        File('${dir.path}/plain').writeAsBytesSync(data);
        await FileCipher.encrypt('${dir.path}/plain', '${dir.path}/enc', key);
        expect(await FileCipher.decryptBytes('${dir.path}/enc', key), data, reason: reason);
        final reader = await FileCipherReader.open('${dir.path}/enc', key);
        try {
          expect(reader.length, data.length, reason: reason);
          Future<List<int>> read(int start, int end) async => [
            for (final part in await reader.read(start, end).toList()) ...part,
          ];
          expect(await read(0, data.length), data, reason: reason);
          final ranges = [(0, 1), (1, 7), (size - 3, size + 5), (size, size * 2), (data.length - 2, data.length + 9)];
          for (final (start, end) in ranges) {
            final from = start.clamp(0, data.length), to = end.clamp(from, data.length);
            expect(await read(start, end), data.sublist(from, to), reason: '$start-$end of $reason');
          }
        } finally {
          reader.close();
        }
      }
    });

    test('encrypts from memory as it does from a file', () async {
      final key = randomBytes(32);
      for (final data in [Uint8List(0), randomBytes(1), randomBytes(FileCipher.chunkSize * 2 + 3)]) {
        await FileCipher.encryptBytes(data, '${dir.path}/enc', key);
        expect(await FileCipher.decryptBytes('${dir.path}/enc', key), data, reason: '${data.length} bytes');
        expect(
          File('${dir.path}/enc').lengthSync(),
          FileCipher.encryptedSize(FileCipher.paddedLength(data.length)),
          reason: 'padded as a file is',
        );
      }
    });

    test('decrypting in parts detects tampering and wrong keys too', () async {
      final key = randomBytes(32);
      File('${dir.path}/plain').writeAsBytesSync(randomBytes(FileCipher.chunkSize * 3));
      await FileCipher.encrypt('${dir.path}/plain', '${dir.path}/enc', key);
      await expectLater(FileCipherReader.open('${dir.path}/enc', randomBytes(32)), throwsA(isA<DecryptionFailed>()));
      final bytes = File('${dir.path}/enc').readAsBytesSync();
      bytes[header + chunk + 5] ^= 1; // In the second chunk.
      File('${dir.path}/enc').writeAsBytesSync(bytes);
      final reader = await FileCipherReader.open('${dir.path}/enc', key);
      try {
        expect(await reader.read(0, 10).length, 1); // The first is fine.
        await expectLater(
          reader.read(FileCipher.chunkSize, FileCipher.chunkSize + 10).toList(),
          throwsA(isA<DecryptionFailed>()),
        );
      } finally {
        reader.close();
      }
    });
  });
}
