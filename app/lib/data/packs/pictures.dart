import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'content_package.dart';

/// What a picture in a package is, as its header says (see [checkPicture]).
typedef PictureInfo = ({String mime, int width, int height, int frames});

/// [bytes], the picture of a package's [file], checked by its header only,
/// never decoded whole: one of [types] (`webp`, `png`, `gif`) and the one
/// [file]'s extension says, no wider or taller than [maxSide]
/// ([maxAnimatedSide] if it moves), and of at most [maxFrames] frames.
/// [what] names it in the [PackageException] it throws otherwise.
PictureInfo checkPicture(
  Uint8List bytes, {
  required String file,
  required String what,
  required int maxSide,
  int? maxAnimatedSide,
  int maxFrames = 1,
  Set<String> types = const {'webp', 'png', 'gif'},
}) {
  final img.Decoder? decoder;
  final img.DecodeInfo? info;
  try {
    decoder = img.findDecoderForData(bytes);
    info = decoder?.startDecode(bytes);
  } on Object {
    throw PackageException('$what is damaged');
  }
  final type = switch (decoder) {
    img.WebPDecoder() => 'webp',
    img.PngDecoder() => 'png',
    img.GifDecoder() => 'gif',
    _ => null,
  };
  if (type == null || !types.contains(type) || !file.endsWith('.$type')) {
    throw PackageException('$what is not the picture its file says');
  }
  if (info == null || info.width < 1 || info.height < 1) throw PackageException('$what is damaged');
  final frames = max(1, info.numFrames);
  if (frames > maxFrames) {
    throw PackageException(maxFrames == 1 ? '$what must be a still picture' : '$what has more than $maxFrames frames');
  }
  final side = frames > 1 ? maxAnimatedSide ?? maxSide : maxSide;
  if (info.width > side || info.height > side) throw PackageException('$what is larger than $side×$side');
  return (mime: 'image/$type', width: info.width, height: info.height, frames: frames);
}
