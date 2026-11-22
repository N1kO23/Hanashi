import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hanashi/data/packs/content_package.dart';
import 'package:hanashi/data/packs/sticker_pack_file.dart';
import 'package:hanashi/data/packs/sticker_pack_store.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/sticker_packs.dart';

Map<String, Object?> _manifest(List<String> files, {String id = 'test-pack'}) => {
  'format': 1,
  'type': 'sticker-pack',
  'id': id,
  'title': 'Test pack',
  'stickers': [
    for (final (place, file) in files.indexed) {'id': '${place + 1}', 'file': file},
  ],
};

/// A zip of [entries] in order, each deflated unless [stored].
Uint8List _zip(Map<String, List<int>> entries, {bool stored = false}) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in entries.entries) {
    archive.add(stored ? ArchiveFile.noCompress(key, value.length, value) : ArchiveFile.bytes(key, value));
  }
  return ZipEncoder().encodeBytes(archive);
}

List<int> _json(Object? value) => utf8.encode(jsonEncode(value));

/// Where the zip's central directory has [name]'s entry, and its local header.
({int central, int local}) _headersOf(Uint8List zip, String name) {
  final wanted = utf8.encode(name);
  int find(List<int> signature, int nameAt) {
    for (var i = 0; i + nameAt + wanted.length <= zip.length; i++) {
      if (zip[i] != signature[0] ||
          zip[i + 1] != signature[1] ||
          zip[i + 2] != signature[2] ||
          zip[i + 3] != signature[3]) {
        continue;
      }
      var same = true;
      for (var j = 0; j < wanted.length && same; j++) {
        same = zip[i + nameAt + j] == wanted[j];
      }
      if (same) return i;
    }
    throw StateError('No $name in the zip');
  }

  return (central: find([0x50, 0x4b, 0x01, 0x02], 46), local: find([0x50, 0x4b, 0x03, 0x04], 30));
}

void _set16(Uint8List zip, int at, int value) => ByteData.sublistView(zip).setUint16(at, value, Endian.little);
void _set32(Uint8List zip, int at, int value) => ByteData.sublistView(zip).setUint32(at, value, Endian.little);

Matcher _refused(String reason) =>
    throwsA(isA<PackageException>().having((e) => e.message, 'message', contains(reason)));

void main() {
  final png = syntheticSticker(1);

  group('a package', () {
    test('is its manifest and the files it names, stored or deflated', () {
      for (final stored in [true, false]) {
        final zip = _zip({
          'pack.json': _json(_manifest(['a.png', 'b.png'])),
          'a.png': png,
          'b.png': syntheticSticker(2),
          'LICENSE': utf8.encode('Not read: the manifest does not name it.'),
        }, stored: stored);
        final pack = readStickerPackNow(zip);
        expect(
          [for (final s in pack.stickers) (s.item.id, s.mime, s.width, s.height, s.frames)],
          [('1', 'image/png', 128, 128, 1), ('2', 'image/png', 128, 128, 1)],
        );
        expect(pack.stickers.first.bytes, png);
      }
    });

    test('the same contents make the same file', () {
      final manifest = _manifest(['a.png']);
      expect(writeContentPackage(manifest, {'a.png': png}), writeContentPackage(manifest, {'a.png': png}));
      final read = readStickerPackNow(writeContentPackage(manifest, {'a.png': png}));
      expect(read.manifest.stickers.single.file, 'a.png');
    });

    test('refuses what is not one, saying why', () {
      expect(() => readStickerPackNow(Uint8List.fromList(utf8.encode('not a zip'))), _refused('has no pack.json'));
      expect(() => readStickerPackNow(_zip({'a.png': png})), _refused('has no pack.json'));
      expect(
        () => readStickerPackNow(
          _zip({
            'pack/pack.json': _json(_manifest(['a.png'])),
          }),
        ),
        _refused('has no pack.json'),
      );
      expect(() => readStickerPackNow(_zip({'pack.json': utf8.encode('{"type":')})), _refused('damaged'));
      expect(
        () => readStickerPackNow(
          _zip({
            'pack.json': _json(['a list']),
          }),
        ),
        _refused('damaged'),
      );
      expect(
        () => readStickerPackNow(
          _zip({
            'pack.json': _json({
              ..._manifest(['a.png']),
              'filler': 'x' * 70000,
            }),
          }),
        ),
        _refused('pack.json" in this sticker pack is larger than 64 KB'),
      );
      expect(
        () => readStickerPackNow(
          _zip({
            'pack.json': _json({
              ..._manifest(['a.png']),
              'type': 'theme',
            }),
          }),
        ),
        _refused('not a sticker pack'),
      );
      expect(
        () => readStickerPackNow(
          _zip({
            'pack.json': _json(_manifest(['a.png'])),
          }),
        ),
        _refused('has no "a.png"'),
      );
      // Names that would lead out of a folder, or into one, are never read.
      for (final name in ['../a.png', '/a.png', r'a\b.png', 'd/a.png']) {
        expect(
          () => readStickerPackNow(
            _zip({
              'pack.json': _json(_manifest([name])),
              name: png,
            }),
          ),
          _refused('no valid file'),
          reason: name,
        );
      }
    });

    test('a zip bomb is refused by what its directory says, before anything is inflated', () {
      final zip = _zip({
        'pack.json': _json(_manifest(['a.png'])),
        'a.png': png,
        'zeros': Uint8List(17 * 1024 * 1024),
      });
      expect(zip.length, lessThan(100 * 1024));
      final watch = Stopwatch()..start();
      expect(() => readStickerPackNow(zip), _refused('larger than 16 MB unpacked'));
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    test('an entry larger than its directory says is damaged; nothing past that size is inflated', () {
      final random = Random(1);
      final noise = Uint8List.fromList(List.generate(300000, (_) => random.nextInt(256)));
      final zip = _zip({
        'pack.json': _json(_manifest(['a.png'])),
        'a.png': noise,
      });
      final at = _headersOf(zip, 'a.png');
      _set32(zip, at.central + 24, 1000);
      _set32(zip, at.local + 22, 1000);
      expect(() => readStickerPackNow(zip), _refused('damaged'));
    });

    test('refuses too many entries, two of a name, encrypted ones, links and other compression', () {
      expect(
        () => readStickerPackNow(
          _zip({
            'pack.json': _json(_manifest(['a.png'])),
            'a.png': png,
            for (var i = 0; i < 127; i++) 'filler-$i': const [0],
          }),
        ),
        _refused('too many files'),
      );

      Uint8List patched(void Function(Uint8List zip, ({int central, int local}) at) patch) {
        final zip = _zip({
          'pack.json': _json(_manifest(['a.png'])),
          'a.png': png,
          'b.png': png,
        });
        patch(zip, _headersOf(zip, 'b.png'));
        return zip;
      }

      expect(
        () => readStickerPackNow(
          patched((zip, at) {
            zip[at.central + 46] = 'a'.codeUnitAt(0);
            zip[at.local + 30] = 'a'.codeUnitAt(0);
          }),
        ),
        _refused('damaged'),
      );
      expect(() => readStickerPackNow(patched((zip, at) => _set16(zip, at.central + 8, 1))), _refused('encrypted'));
      expect(
        () => readStickerPackNow(
          patched((zip, at) {
            _set16(zip, at.central + 4, 3 << 8 | 20);
            _set32(zip, at.central + 38, 0xA1FF << 16);
          }),
        ),
        _refused('holds a link'),
      );
      expect(
        () => readStickerPackNow(patched((zip, at) => _set16(zip, at.central + 10, 12))),
        _refused('compressed in a way'),
      );
    });

    test('a file larger than a pack may be is not even opened', () {
      expect(() => readStickerPackNow(Uint8List(8 * 1024 * 1024 + 1)), _refused('larger than 8 MB'));
    });
  });

  group("a sticker's picture", () {
    Uint8List pack(String file, List<int> bytes) => _zip({
      'pack.json': _json(_manifest([file])),
      file: bytes,
    });

    test('is what its name says it is', () {
      expect(() => readStickerPackNow(pack('a.webp', png)), _refused('not the picture its file says'));
      expect(() => readStickerPackNow(pack('a.png', utf8.encode('not a picture'))), _refused('not the picture'));
      expect(() => readStickerPackNow(pack('a.png', img.encodeJpg(syntheticPicture(1)))), _refused('not the picture'));
      final gif = img.encodeGif(syntheticPicture(1));
      expect(readStickerPackNow(pack('a.gif', gif)).stickers.single.mime, 'image/gif');
    });

    test('is no larger than a sticker can be; an animated one, smaller and of fewer frames', () {
      expect(
        () => readStickerPackNow(pack('a.png', img.encodePng(img.Image(width: 1100, height: 10, numChannels: 4)))),
        _refused('larger than 1024×1024'),
      );
      img.Image animation(int side, int frames) {
        final first = img.Image(width: side, height: side, numChannels: 4);
        for (var i = 1; i < frames; i++) {
          first.addFrame(img.Image(width: side, height: side, numChannels: 4));
        }
        return first;
      }

      final moving = readStickerPackNow(pack('a.gif', img.encodeGif(animation(64, 3)))).stickers.single;
      expect((moving.frames, moving.width), (3, 64));
      expect(
        () => readStickerPackNow(pack('a.gif', img.encodeGif(animation(600, 2)))),
        _refused('larger than 512×512'),
      );
      expect(
        () => readStickerPackNow(pack('a.gif', img.encodeGif(animation(4, 151)))),
        _refused('more than 150 frames'),
      );
    });
  });

  test('the pack tool makes files this version reads', () {
    final pack = readStickerPackNow(File('test/fixtures/sticker_pack_v1.zip').readAsBytesSync());
    expect(
      (pack.manifest.id, pack.manifest.title, pack.manifest.author),
      ('fixture-pack', 'Fixture pack', 'Hanashi tests'),
    );
    expect([for (final s in pack.stickers) s.item.id], ['01', '02', '03']);
  });

  group('the packs on this device', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_store_'));
    tearDown(() => dir.delete(recursive: true));

    // Packs' files on the server, with the keys only account data holds.
    final one = MediaRef(
      hash: 'sha256:${'1' * 64}',
      size: 1,
      mime: 'application/zip',
      key: base64.encode(List.filled(32, 1)),
    );
    final two = MediaRef(
      hash: 'sha256:${'2' * 64}',
      size: 1,
      mime: 'application/zip',
      key: base64.encode(List.filled(32, 2)),
    );
    String folderOf(MediaRef archive) => '${dir.path}/packs/${StickerPackStore.folderName(archive.hash)}';

    StickerPackFile packOf(List<String> ids) => readStickerPackNow(
      writeContentPackage(
        StickerPackManifest(
          id: 'test-pack',
          title: 'Test pack',
          cover: ids.first,
          stickers: [for (final id in ids) StickerPackItem(id: id, file: '$id.png')],
        ).toJson(),
        {for (final (place, id) in ids.indexed) '$id.png': syntheticSticker(place + 1)},
      ),
    );

    test('are kept in a folder of their file, named by place; a store opened again finds them', () async {
      final store = StickerPackStore(Directory('${dir.path}/packs'));
      // Never by what the pack calls them.
      final kept = await store.install(packOf(['con', 'b.c', 'z']), one);
      expect(
        [for (final s in kept.stickers) (s.id, s.path!.split('/').last)],
        [('con', '000.png'), ('b.c', '001.png'), ('z', '002.png')],
      );
      expect(await packPicture(kept.stickers[1]), syntheticSticker(2));
      expect(Directory(folderOf(one)).existsSync(), isTrue);

      final again = await StickerPackStore(Directory('${dir.path}/packs')).load(one);
      expect((again!.id, again.title, again.stickers.length), ('test-pack', 'Test pack', 3));
      expect(await store.load(two), isNull);
    });

    test('what is no longer kept goes; a damaged one is fetched again', () async {
      final store = StickerPackStore(Directory('${dir.path}/packs'));
      await store.install(packOf(['a']), one);
      await store.install(packOf(['b']), two);
      Directory('${dir.path}/packs/.incoming-left-behind').createSync();
      await store.gc({two.hash});
      expect(await store.load(one), isNull);
      expect(await store.load(two), isNotNull);
      expect(Directory('${dir.path}/packs').listSync().map((e) => e.path.split('/').last), [
        StickerPackStore.folderName(two.hash),
      ]);

      File('${folderOf(two)}/index.sealed').writeAsStringSync('{');
      expect(await StickerPackStore(Directory('${dir.path}/packs')).load(two), isNull);
      final reinstalled = await StickerPackStore(Directory('${dir.path}/packs')).install(packOf(['c']), two);
      expect(reinstalled.stickers.single.id, 'c');

      await store.clear();
      expect(Directory('${dir.path}/packs').existsSync(), isFalse);
    });

    test('are kept encrypted, readable only with their key', () async {
      final store = StickerPackStore(Directory('${dir.path}/packs'));
      final kept = await store.install(packOf(['a', 'b']), one);
      final files = Directory(folderOf(one)).listSync().whereType<File>().toList();
      expect(files.map((f) => f.uri.pathSegments.last).toSet(), {'index.sealed', '000.png', '001.png'});
      for (final file in files) {
        final bytes = file.readAsBytesSync();
        expect(utf8.decode(bytes.sublist(0, 4)), 'MTF2', reason: file.path);
        expect(bytes, isNot(syntheticSticker(1)));
        expect(latin1.decode(bytes), isNot(contains('Test pack')), reason: file.path);
      }
      expect(await packPicture(kept.stickers.first), syntheticSticker(1));
      // Not with another key, which another account's file of it would have.
      final elsewhere = MediaRef(hash: one.hash, size: 1, mime: 'application/zip', key: two.key);
      expect(await StickerPackStore(Directory('${dir.path}/packs')).load(elsewhere), isNull);
    });

    test('one kept decrypted, as before 1.0.5, is fetched again and kept encrypted', () async {
      final old = Directory(folderOf(one))..createSync(recursive: true);
      File('${old.path}/index.json').writeAsStringSync(jsonEncode({'archive': one.hash, 'id': 'test-pack'}));
      File('${old.path}/000.png').writeAsBytesSync(syntheticSticker(1));
      final store = StickerPackStore(Directory('${dir.path}/packs'));
      expect(await store.load(one), isNull);
      await store.install(packOf(['a']), one);
      expect(File('${old.path}/index.json').existsSync(), isFalse);
      expect(File('${old.path}/000.png').readAsBytesSync(), isNot(syntheticSticker(1)));
    });
  });
}
