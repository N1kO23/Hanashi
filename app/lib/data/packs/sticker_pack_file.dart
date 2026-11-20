import 'dart:isolate';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'content_package.dart';
import 'pictures.dart';

/// How large a sticker pack's file, and what it holds, can be.
const stickerPackLimits = PackageLimits(
  maxBytes: 8 * 1024 * 1024,
  maxEntries: 128,
  maxManifestBytes: 64 * 1024,
  maxFileBytes: 512 * 1024,
  maxTotalBytes: 16 * 1024 * 1024,
);

/// The longest side of a sticker, in pixels; an animated one's is
/// [maxAnimatedStickerSide].
const maxStickerSide = 1024;
const maxAnimatedStickerSide = 512;
const maxStickerFrames = 150;

/// A sticker of a pack's file, checked: what its picture is, and its bytes.
class PackStickerFile {
  const PackStickerFile({
    required this.item,
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.frames,
  });

  final StickerPackItem item;
  final Uint8List bytes;

  /// `image/webp`, `image/png` or `image/gif`, as its bytes say.
  final String mime;
  final int width;
  final int height;
  final int frames;

  String get extension => mime.substring('image/'.length);
}

/// A sticker pack's file, read and checked (see [readStickerPack]).
class StickerPackFile {
  const StickerPackFile(this.manifest, this.stickers);

  final StickerPackManifest manifest;

  /// In the manifest's order.
  final List<PackStickerFile> stickers;
}

/// Reads and checks [zip], a sticker pack's file, off the UI isolate. Throws
/// a [PackageException] saying what is wrong with it.
Future<StickerPackFile> readStickerPack(Uint8List zip) => Isolate.run(() => readStickerPackNow(zip));

/// [readStickerPack] on this isolate.
StickerPackFile readStickerPackNow(Uint8List zip) {
  final read = readContentPackage(
    zip,
    limits: stickerPackLimits,
    manifest: StickerPackManifest.fromJson,
    files: (manifest) => {for (final sticker in manifest.stickers) sticker.file},
    what: 'sticker pack',
  );
  return StickerPackFile(read.manifest, [
    for (final item in read.manifest.stickers) _checked(item, read.files[item.file]!),
  ]);
}

/// [bytes] as a sticker's picture: of the type its file's name says, and no
/// larger than a sticker can be. Only headers are read, never a whole image.
PackStickerFile _checked(StickerPackItem item, Uint8List bytes) {
  final picture = checkPicture(
    bytes,
    file: item.file,
    what: 'Sticker "${item.id}" of this pack',
    maxSide: maxStickerSide,
    maxAnimatedSide: maxAnimatedStickerSide,
    maxFrames: maxStickerFrames,
  );
  return PackStickerFile(
    item: item,
    bytes: bytes,
    mime: picture.mime,
    width: picture.width,
    height: picture.height,
    frames: picture.frames,
  );
}
