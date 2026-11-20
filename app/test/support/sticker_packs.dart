import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:hanashi/data/packs/content_package.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

const _colors = [
  (240, 130, 170),
  (77, 151, 180),
  (60, 179, 113),
  (242, 179, 61),
  (155, 120, 220),
  (229, 72, 77),
  (74, 143, 211),
  (255, 160, 90),
];

/// A picture to stand in for a sticker: a disc of a colour of its own on a
/// transparent ground, with [n] on it. Made here, so that no test needs
/// anyone's art.
img.Image syntheticPicture(int n, {int size = 128}) {
  final (r, g, b) = _colors[(n - 1) % _colors.length];
  final picture = img.Image(width: size, height: size, numChannels: 4);
  img.fillCircle(picture, x: size ~/ 2, y: size ~/ 2, radius: size * 2 ~/ 5, color: img.ColorRgba8(r, g, b, 255));
  img.drawString(
    picture,
    '$n',
    font: img.arial24,
    x: size ~/ 2 - (n > 9 ? 12 : 6),
    y: size ~/ 2 - 12,
    color: img.ColorRgba8(255, 255, 255, 255),
  );
  return picture;
}

/// [syntheticPicture] as a PNG.
Uint8List syntheticSticker(int n, {int size = 128}) => img.encodePng(syntheticPicture(n, size: size));

/// The file of a sticker pack of [count] [syntheticSticker]s, `01`, `02`...
Uint8List syntheticStickerPackBytes({
  String id = 'test-pack',
  String title = 'Test pack',
  int count = 8,
  int version = 1,
}) {
  final stickers = [for (var i = 1; i <= count; i++) '$i'.padLeft(2, '0')];
  final manifest = StickerPackManifest(
    id: id,
    title: title,
    author: 'Hanashi tests',
    cover: stickers.first,
    version: version,
    stickers: [for (final sticker in stickers) StickerPackItem(id: sticker, file: '$sticker.png')],
  );
  return writeContentPackage(manifest.toJson(), {
    for (final (place, sticker) in stickers.indexed) '$sticker.png': syntheticSticker(place + 1),
  });
}

/// [syntheticStickerPackBytes] as a file in [dir].
File syntheticStickerPack(
  Directory dir, {
  String id = 'test-pack',
  String title = 'Test pack',
  int count = 8,
  int version = 1,
}) =>
    File('${dir.path}/$id-$version.zip')
      ..writeAsBytesSync(syntheticStickerPackBytes(id: id, title: title, count: count, version: version));
