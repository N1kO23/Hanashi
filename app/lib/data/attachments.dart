import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'media_cache.dart';

/// Size and first-frame image of a video, produced by the platform player.
class VideoInfo {
  const VideoInfo({this.width, this.height, this.duration, this.frameJpeg, this.hasAudio});

  final int? width;
  final int? height;
  final Duration? duration;
  final Uint8List? frameJpeg;

  /// Whether it has sound; null if the player could not tell.
  final bool? hasAudio;
}

typedef VideoProbe = Future<VideoInfo?> Function(String path);

/// A file ready to send: its message metadata plus local files to upload.
class PreparedAttachment {
  const PreparedAttachment({required this.type, required this.media, required this.path, this.thumbnailPath});

  final MessageType type;
  final MediaRef media;
  final String path;
  final String? thumbnailPath;
}

class AttachmentException implements Exception {
  const AttachmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The long side, in pixels, of the pictures shown in the chat: photos' and
/// videos' thumbnails and link previews' pictures. They are shown about 300
/// points wide, about 900 pixels on a phone.
const previewSize = 1280;

/// Formats the `image` package can decode for thumbnails. Others (e.g. HEIC)
/// are sent as plain files.
const _decodableImages = {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp'};

/// The MIME type of a file called [name] that starts with [header]. The
/// header decides, except where it cannot tell audio from video: the mime
/// package calls every WebM/Matroska file audio/weba and every MP4 video/mp4.
/// There the name decides (and for video, later, whether the player finds a
/// picture).
String? mimeOf(String name, List<int> header) {
  final sniffed = lookupMimeType(name, headerBytes: header);
  final named = lookupMimeType(name);
  final ambiguous = sniffed == 'audio/weba' || sniffed == 'video/mp4';
  if (ambiguous && named != null && (named.startsWith('audio/') || named.startsWith('video/'))) return named;
  return sniffed ?? named;
}

/// Hashes [path] and, for images and videos, measures it and renders a JPEG
/// thumbnail into [tempDir] (for audio, the duration). Everything is computed on this device so the
/// same metadata works once media is end-to-end encrypted.
Future<PreparedAttachment> prepareAttachment({
  required String path,
  required String name,
  required Directory tempDir,
  VideoProbe? probeVideo,
}) async {
  final file = File(path);
  if (!file.existsSync()) throw AttachmentException('Cannot read "$name"');
  final size = await file.length();
  final header = await file.openRead(0, 32).fold<List<int>>([], (a, b) => a..addAll(b));
  final mime = mimeOf(name, header) ?? lookupMimeType(path) ?? 'application/octet-stream';
  final hash = await hashFile(path);
  await tempDir.create(recursive: true);
  final thumbBase = '${tempDir.path}/${hash.substring(7, 23)}-thumb';

  if (_decodableImages.contains(mime)) {
    final made = await Isolate.run(() => _imageThumbnail(path, thumbBase));
    if (made != null) {
      return PreparedAttachment(
        type: MessageType.image,
        path: path,
        thumbnailPath: made.thumb.path,
        media: MediaRef(
          hash: hash,
          size: size,
          mime: mime,
          name: name,
          width: made.width,
          height: made.height,
          thumb: await _thumbRef(made.thumb),
        ),
      );
    }
  }

  final video = mime.startsWith('video/');
  if (video || mime.startsWith('audio/')) {
    // The probe drives a real player; never let it hold up sending.
    final info = await probeVideo
        ?.call(path)
        .timeout(const Duration(seconds: 15), onTimeout: () => null)
        .catchError((Object _) => null);
    // A file the player finds no picture in is audio, whatever its container
    // (MP4 audio, WebM audio), and goes as a file, which plays in the app.
    if (!video || (info != null && info.width == null)) {
      return PreparedAttachment(
        type: MessageType.file,
        path: path,
        media: MediaRef(
          hash: hash,
          size: size,
          mime: video ? 'audio/${mime.substring('video/'.length)}' : mime,
          name: name,
          durationMs: info?.duration?.inMilliseconds,
        ),
      );
    }
    final frame = info?.frameJpeg;
    final thumb = frame == null ? null : await Isolate.run(() => _frameThumbnail(frame, thumbBase));
    return PreparedAttachment(
      type: MessageType.video,
      path: path,
      thumbnailPath: thumb?.path,
      media: MediaRef(
        hash: hash,
        size: size,
        mime: mime,
        name: name,
        width: info?.width,
        height: info?.height,
        durationMs: info?.duration?.inMilliseconds,
        thumb: thumb == null ? null : await _thumbRef(thumb),
      ),
    );
  }

  return PreparedAttachment(
    type: MessageType.file,
    path: path,
    media: MediaRef(hash: hash, size: size, mime: mime, name: name),
  );
}

Future<MediaRef> _thumbRef(_Thumbnail thumb) async =>
    MediaRef(hash: await hashFile(thumb.path), size: await File(thumb.path).length(), mime: thumb.mime);

/// A thumbnail written to a file.
typedef _Thumbnail = ({String path, String mime});

/// Writes a thumbnail at [base] (plus its extension) and returns it with the
/// upright image size, or null if the image cannot be decoded.
({_Thumbnail thumb, int width, int height})? _imageThumbnail(String path, String base) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) return null;
  final image = img.bakeOrientation(decoded.frames.first);
  return (thumb: _writeThumb(image, base), width: image.width, height: image.height);
}

/// A thumbnail of a video's first frame, [jpeg] from the player.
_Thumbnail? _frameThumbnail(Uint8List jpeg, String base) {
  final image = img.decodeImage(jpeg);
  return image == null ? null : _writeThumb(image, base);
}

_Thumbnail _writeThumb(img.Image image, String base) {
  final (bytes, mime) = _encodePicture(_shrink(image, previewSize));
  final path = '$base.${mime == 'image/png' ? 'png' : 'jpg'}';
  File(path).writeAsBytesSync(bytes);
  return (path: path, mime: mime);
}

/// [image] made at most [size] pixels on its long side, each pixel the
/// average of those it stands for. (Picking one of them, the default, makes
/// edges jagged and loses thin lines.)
img.Image _shrink(img.Image image, int size) {
  // Colours from a palette are never mixed, so they become plain colours.
  if (image.hasPalette || image.format != img.Format.uint8) {
    image = image.convert(format: img.Format.uint8, numChannels: image.numChannels);
  }
  if (image.width <= size && image.height <= size) return image;
  return image.width >= image.height
      ? img.copyResize(image, width: size, interpolation: img.Interpolation.average)
      : img.copyResize(image, height: size, interpolation: img.Interpolation.average);
}

/// The longest side of a sticker the user makes from an image.
const stickerSize = 512;

/// A picture made from an image, for a sticker or a custom emoji: its file,
/// size and type.
typedef PreparedPicture = ({File file, int width, int height, String mime});

/// Makes the image at [path] a sticker: upright, fitted into [stickerSize]
/// (never enlarged), and see-through where it is (a PNG; otherwise, as for a
/// photo, a JPEG). Only the first frame of an animated one.
Future<PreparedPicture> prepareSticker(String path, Directory tempDir) =>
    _preparePicture(path, tempDir, size: stickerSize, refused: 'This image cannot be made into a sticker');

/// Makes the image at [path] a custom emoji's picture, as [prepareSticker]
/// makes a sticker, but fitted into [CustomEmoji.size].
Future<PreparedPicture> prepareEmoji(String path, Directory tempDir) =>
    _preparePicture(path, tempDir, size: CustomEmoji.size, refused: 'This image cannot be made into an emoji');

Future<PreparedPicture> _preparePicture(
  String path,
  Directory tempDir, {
  required int size,
  required String refused,
}) async {
  final made = await Isolate.run(() => _fitPicture(path, size));
  if (made == null) throw AttachmentException(refused);
  await tempDir.create(recursive: true);
  final file = File('${tempDir.path}/picture-${newUlid()}.${made.mime == 'image/png' ? 'png' : 'jpg'}');
  await file.writeAsBytes(made.bytes);
  return (file: file, width: made.width, height: made.height, mime: made.mime);
}

({Uint8List bytes, String mime, int width, int height})? _fitPicture(String path, int size) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) return null;
  final image = _shrink(img.bakeOrientation(decoded.frames.first), size);
  final (bytes, mime) = _encodePicture(image);
  return (bytes: bytes, mime: mime, width: image.width, height: image.height);
}

/// [image] as a JPEG, or as a PNG if any of it is see-through (a JPEG would
/// make that black); with its type.
(Uint8List, String) _encodePicture(img.Image image) => image.hasAlpha && image.any((p) => p.aNormalized < 1)
    ? (img.encodePng(image), 'image/png')
    : (img.encodeJpg(image, quality: 85, chroma: img.JpegChroma.yuv420), 'image/jpeg');

/// A link preview's picture: at most [previewSize] px on the long side, a
/// JPEG or (if any of it is see-through) a PNG.
typedef LinkPicture = ({Uint8List bytes, String mime, int width, int height});

/// An image from a web page: its [LinkPicture]; its upright size; its type if
/// every app can show it as it is (a JPEG, PNG, GIF or WebP); and whether it
/// is animated (a GIF or WebP of more than one frame).
typedef LinkImage = ({LinkPicture picture, int width, int height, String? mime, bool animated});

/// Larger images (in pixels) are not decoded: a small file can unpack into
/// more memory than a phone has.
const _maxLinkPixels = 40000000;

/// [bytes], an image from a web page, for a link preview; null if this device
/// cannot decode it.
Future<LinkImage?> linkImage(Uint8List bytes) => Isolate.run(() => _linkImage(bytes));

/// [bytes] (e.g. a video's first frame) made into a link preview's picture.
Future<LinkPicture?> linkThumbnail(Uint8List bytes) async => (await linkImage(bytes))?.picture;

LinkImage? _linkImage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width <= 0 || info.height <= 0 || info.width * info.height > _maxLinkPixels) return null;
  final animated = (decoder is img.GifDecoder || decoder is img.WebPDecoder) && info.numFrames > 1;
  final decoded = decoder!.decode(bytes, frame: 0);
  if (decoded == null) return null;
  final image = img.bakeOrientation(decoded);
  final picture = _shrink(image, previewSize);
  final (encoded, type) = _encodePicture(picture);
  return (
    picture: (bytes: encoded, mime: type, width: picture.width, height: picture.height),
    width: image.width,
    height: image.height,
    mime: switch (decoder) {
      img.JpegDecoder() => 'image/jpeg',
      img.PngDecoder() => 'image/png',
      img.GifDecoder() => 'image/gif',
      img.WebPDecoder() => 'image/webp',
      _ => null,
    },
    animated: animated,
  );
}

/// Side of a profile picture, in pixels.
const avatarSize = 256;

/// Crops the image at [path] to a centred square of [avatarSize] pixels and
/// writes it as a JPEG into [tempDir]. Throws an [AttachmentException] if it
/// is not an image this device can read.
Future<File> prepareAvatar(String path, Directory tempDir) async {
  await tempDir.create(recursive: true);
  final out = '${tempDir.path}/avatar-${newUlid()}.jpg';
  if (!await Isolate.run(() => _writeAvatar(path, out))) {
    throw const AttachmentException('This image cannot be used as a profile picture');
  }
  return File(out);
}

bool _writeAvatar(String path, String out) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) return false;
  final image = img.bakeOrientation(decoded.frames.first);
  final side = image.width < image.height ? image.width : image.height;
  final square = img.copyCrop(
    image,
    x: (image.width - side) ~/ 2,
    y: (image.height - side) ~/ 2,
    width: side,
    height: side,
  );
  // Smaller ones are made larger as they are, pixels and all.
  final sized = side > avatarSize
      ? _shrink(square, avatarSize)
      : img.copyResize(square, width: avatarSize, height: avatarSize);
  File(out).writeAsBytesSync(img.encodeJpg(sized, quality: 85));
  return true;
}
