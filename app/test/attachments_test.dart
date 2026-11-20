import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hanashi/data/attachments.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

/// How a WebM/Matroska file starts (an EBML header).
const _ebml = [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81];

/// How an MP4 file starts (an ftyp box).
const _mp4 = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_attach_'));
  tearDown(() => dir.delete(recursive: true));

  test("containers that do not say audio or video go by the file's name", () {
    expect(mimeOf('clip.webm', _ebml), 'video/webm');
    expect(mimeOf('clip.mkv', _ebml), 'video/x-matroska');
    expect(mimeOf('voice.weba', _ebml), 'audio/webm');
    expect(mimeOf('song.m4a', _mp4), 'audio/mp4');
    expect(mimeOf('clip.mov', _mp4), 'video/quicktime');
    // A name that says nothing: the header still does.
    expect(mimeOf('download', _mp4), 'video/mp4');
    expect(mimeOf('song.mp3', const [0x49, 0x44, 0x33, 0x04]), 'audio/mpeg');
  });

  Future<PreparedAttachment> prepare(String name, List<int> bytes, {VideoInfo? probed}) {
    final file = File('${dir.path}/$name')..writeAsBytesSync([...bytes, ...List.filled(64, 0)]);
    return prepareAttachment(
      path: file.path,
      name: name,
      tempDir: Directory('${dir.path}/tmp'),
      probeVideo: (_) async => probed,
    );
  }

  test('a WebM video goes as a video; audio, also in a video container, as a file with its length', () async {
    final video = await prepare(
      'clip.webm',
      _ebml,
      probed: const VideoInfo(width: 640, height: 360, duration: Duration(seconds: 5)),
    );
    expect((video.type, video.media.mime, video.media.width), (MessageType.video, 'video/webm', 640));

    // The player finds no picture.
    final voice = await prepare('voice.webm', _ebml, probed: const VideoInfo(duration: Duration(seconds: 7)));
    expect((voice.type, voice.media.mime, voice.media.durationMs), (MessageType.file, 'audio/webm', 7000));

    final song = await prepare('song.mp3', const [0x49, 0x44, 0x33, 0x04], probed: const VideoInfo(duration: Duration(minutes: 3)));
    expect((song.type, song.media.mime, song.media.durationMs), (MessageType.file, 'audio/mpeg', 180000));

    // Without a player to ask, a video stays a video.
    final unknown = await prepare('clip.webm', _ebml);
    expect((unknown.type, unknown.media.mime), (MessageType.video, 'video/webm'));
  });

  group('pictures made smaller', () {
    // One-pixel black and white stripes. Made half as wide, each pixel the
    // average of two, they are grey; picking one of the two (the image
    // package's default) would leave them black or white.
    img.Image stripes(int width, int height) {
      final image = img.Image(width: width, height: height);
      for (final pixel in image) {
        final v = pixel.x.isEven ? 0 : 255;
        pixel.setRgb(v, v, v);
      }
      return image;
    }

    Matcher grey = inInclusiveRange(118, 138);

    test('a photo: at most 1280 px, each pixel the average of those it stands for', () async {
      final photo = await prepare('stripes.png', img.encodePng(stripes(2560, 100)));
      expect((photo.type, photo.media.width, photo.media.height), (MessageType.image, 2560, 100));
      final thumb = img.decodeJpg(File(photo.thumbnailPath!).readAsBytesSync())!;
      expect((thumb.width, thumb.height, photo.media.thumb!.mime), (1280, 50, 'image/jpeg'));
      expect(thumb.getPixel(100, 25).r, grey);
      // Smaller ones stay as they are.
      final small = await prepare('small.png', img.encodePng(stripes(300, 200)));
      expect(img.decodeJpg(File(small.thumbnailPath!).readAsBytesSync())!.width, 300);
    });

    test("a link's picture, also from a GIF's colour palette", () async {
      for (final bytes in [img.encodePng(stripes(2560, 100)), img.encodeGif(stripes(2560, 100))]) {
        final image = (await linkImage(bytes))!;
        expect((image.width, image.height, image.animated), (2560, 100, false));
        expect((image.picture.width, image.picture.height, image.picture.mime), (1280, 50, 'image/jpeg'));
        expect(img.decodeJpg(image.picture.bytes)!.getPixel(100, 25).r, grey);
      }
      // What every app shows as it is.
      expect((await linkImage(img.encodePng(stripes(4, 4))))!.mime, 'image/png');
      expect((await linkImage(img.encodeGif(stripes(4, 4))))!.mime, 'image/gif');
      expect((await linkImage(img.encodeBmp(stripes(4, 4))))!.mime, isNull);
    });

    test('see-through pictures stay see-through: PNG, not JPEG', () async {
      final clear = img.encodePng(img.Image(width: 40, height: 20, numChannels: 4));
      final sticker = await prepare('sticker.png', clear);
      expect((sticker.thumbnailPath!.endsWith('.png'), sticker.media.thumb!.mime), (true, 'image/png'));
      expect(img.decodePng(File(sticker.thumbnailPath!).readAsBytesSync())!.getPixel(5, 5).a, 0);
      final picture = (await linkImage(clear))!.picture;
      expect(picture.mime, 'image/png');
      expect(img.decodePng(picture.bytes)!.getPixel(5, 5).a, 0);
    });

    test('a profile picture', () async {
      final path = '${dir.path}/me.png';
      File(path).writeAsBytesSync(img.encodePng(stripes(512, 600)));
      final avatar = img.decodeJpg((await prepareAvatar(path, Directory('${dir.path}/tmp'))).readAsBytesSync())!;
      expect((avatar.width, avatar.height), (avatarSize, avatarSize));
      expect(avatar.getPixel(100, 100).r, grey);
    });
  });

  test('a sticker made from an image: fitted into 512 px, see-through where it is, never enlarged', () async {
    final clear = File('${dir.path}/clear.png')
      ..writeAsBytesSync(
        img.encodePng(img.Image(width: 1024, height: 768, numChannels: 4)..clear(img.ColorRgba8(240, 150, 170, 0))),
      );
    final big = await prepareSticker(clear.path, dir);
    expect((big.width, big.height, big.mime), (512, 384, 'image/png'));
    final read = img.decodePng(big.file.readAsBytesSync())!;
    expect((read.width, read.getPixel(10, 10).a), (512, 0), reason: 'what was see-through stays so');

    final photo = File('${dir.path}/photo.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 100, height: 60)..clear(img.ColorRgb8(30, 60, 90))));
    final small = await prepareSticker(photo.path, dir);
    expect((small.width, small.height, small.mime), (100, 60, 'image/jpeg'));

    final text = File('${dir.path}/notes.txt')..writeAsStringSync('not an image');
    await expectLater(prepareSticker(text.path, dir), throwsA(isA<AttachmentException>()));
  });
}
