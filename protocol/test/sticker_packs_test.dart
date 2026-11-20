import 'dart:convert';

import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> _manifest({Object? stickers, Map<String, Object?> also = const {}}) => {
  'format': 1,
  'type': 'sticker-pack',
  'id': 'test-pack',
  'title': 'Test pack',
  'stickers':
      stickers ??
      [
        {'id': '01', 'file': '01.webp', 'emoji': '👋'},
        {'id': '02', 'file': '02.png'},
      ],
  ...also,
};

MediaRef _archive(int n, {String host = 'a.example'}) =>
    MediaRef(hash: 'sha256:${'$n'.padLeft(64, '0')}', size: 1000 + n, mime: 'application/zip', key: 'a2V5', host: host);

PackEntry _entry(String id, [int n = 1]) => PackEntry(id: id, title: 'Pack $id', archive: _archive(n));

void main() {
  group('manifest', () {
    test('a pack names itself and its stickers; the cover is the first unless it says', () {
      final pack = StickerPackManifest.fromJson(
        _manifest(
          also: {
            'author': '  Someone  ',
            'later': {'x': 1},
          },
        ),
      );
      expect(
        (pack.id, pack.title, pack.author, pack.cover, pack.version),
        ('test-pack', 'Test pack', 'Someone', '01', null),
      );
      expect(
        [for (final s in pack.stickers) (s.id, s.file, s.emoji)],
        [('01', '01.webp', '👋'), ('02', '02.png', null)],
      );
      expect(StickerPackManifest.fromJson(_manifest(also: {'cover': '02', 'version': 3})).cover, '02');
      expect(StickerPackManifest.fromJson(_manifest(also: {'cover': 'nope'})).cover, '01');
      // Optional fields that are wrong are left out, never the pack.
      final odd = StickerPackManifest.fromJson(
        _manifest(
          stickers: [
            {'id': '01', 'file': '01.gif', 'emoji': 'x' * 17},
          ],
          also: {'author': 7, 'version': -1},
        ),
      );
      expect((odd.author, odd.version, odd.stickers.single.emoji), (null, null, null));
      final again = StickerPackManifest.fromJson(jsonDecode(jsonEncode(pack.toJson())) as Map<String, Object?>);
      expect(jsonEncode(again.toJson()), jsonEncode(pack.toJson()));
    });

    test('anything else is refused with a reason fit to show', () {
      void refused(Map<String, Object?> json, String reason) => expect(
        () => StickerPackManifest.fromJson(json),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(reason))),
        reason: '$json',
      );
      refused({..._manifest(), 'type': 'theme'}, 'not a sticker pack');
      refused({..._manifest()}..remove('type'), 'not a sticker pack');
      refused({..._manifest(), 'format': 2}, 'newer version');
      refused({..._manifest(), 'format': '1'}, 'damaged');
      refused({..._manifest(), 'id': '../x'}, 'no valid ID');
      refused({..._manifest(), 'title': ' '}, 'no title');
      refused({..._manifest(), 'title': 'x' * 65}, 'no title');
      refused(_manifest(stickers: []), 'no stickers');
      refused(_manifest(stickers: 'all of them'), 'no stickers');
      refused(
        _manifest(
          stickers: [
            for (var i = 0; i < 101; i++) {'id': '$i', 'file': '$i.webp'},
          ],
        ),
        'more than 100',
      );
      refused(
        _manifest(
          stickers: [
            {'id': 'a', 'file': 'a.webp'},
            {'id': 'A', 'file': 'b.webp'},
          ],
        ),
        '"A" twice',
      );
      refused(_manifest(stickers: ['01.webp']), 'damaged');
      refused(
        _manifest(
          stickers: [
            {'file': '01.webp'},
          ],
        ),
        'no valid ID',
      );
      for (final file in ['../x.webp', '/x.webp', r'a\b.webp', 'd/x.webp', 'x.jpg', '.x.webp', 'x.webp.exe', '', 7]) {
        refused(
          _manifest(
            stickers: [
              {'id': '01', 'file': file},
            ],
          ),
          'no valid file',
        );
      }
    });
  });

  group('the packs a user keeps', () {
    test('what this version does not know stays as it was, through every change', () {
      final stored = <String, Object?>{
        'packs': [
          {..._entry('b', 2).toJson(), 'later': 'kept'},
          {
            'id': 'from-later',
            'title': 'x',
            'archive': {'kind': 'new'},
          },
          'not an entry',
          _entry('c', 3).toJson(),
        ],
        'later': {'also': 'kept'},
      };
      final list = PackList.fromJson(jsonDecode(jsonEncode(stored)) as Map<String, Object?>);
      expect([for (final e in list.entries) e.id], ['b', 'c']);
      expect((list['b']!.title, list['b']!.archive.host, list['x']), ('Pack b', 'a.example', null));

      final changed = list.withAdded(_entry('a')).withRemoved('c');
      final json = jsonDecode(jsonEncode(changed.toJson())) as Map<String, Object?>;
      expect(json['later'], {'also': 'kept'});
      expect(json['packs'], [
        _entry('a').toJson(),
        {..._entry('b', 2).toJson(), 'later': 'kept'},
        {
          'id': 'from-later',
          'title': 'x',
          'archive': {'kind': 'new'},
        },
        'not an entry',
      ]);
    });

    test('a pack added again takes its own place; new ones go first; the first of an ID counts', () {
      var list = PackList.empty.withAdded(_entry('a')).withAdded(_entry('b')).withAdded(_entry('c'));
      expect([for (final e in list.entries) e.id], ['c', 'b', 'a']);
      list = list.withAdded(_entry('b', 7));
      expect([for (final e in list.entries) (e.id, e.archive.size)], [('c', 1001), ('b', 1007), ('a', 1001)]);

      final twice = PackList.fromJson({
        'packs': [_entry('a', 1).toJson(), _entry('a', 2).toJson()],
      });
      expect(twice.entries.single.archive.size, 1001);
      expect(twice.withAdded(_entry('a', 3)).toJson()['packs'], [_entry('a', 3).toJson()]);
      expect(twice.withRemoved('a').entries, isEmpty);
    });

    test('there is a most a user keeps', () {
      var list = PackList.empty;
      for (var i = 0; i < PackList.maxPacks; i++) {
        list = list.withAdded(_entry('p$i'));
      }
      expect(() => list.withAdded(_entry('one-more')), throwsA(isA<TooManyStickerPacks>()));
      expect(list.withAdded(_entry('p5', 9))['p5']!.archive.size, 1009, reason: 'a new copy of one kept fits');
    });
  });
}
