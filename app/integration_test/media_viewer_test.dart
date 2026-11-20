// Sends photos, videos and audio as the desktop app does (measured with the
// real player, libmpv) and opens them in the viewer.
//   flutter test integration_test/media_viewer_test.dart -d linux
// Videos and audio are made with ffmpeg (and vpxenc for WebM where ffmpeg has
// no VP9 encoder); without them, only the photo.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:hanashi/data/attachments.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/media/media_viewer.dart';
import 'package:hanashi/ui/media/video_probe.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

/// Hands out local files for media, as a repository does once they are
/// downloaded and decrypted.
class _Files extends MockChatRepository {
  _Files(this.files);

  final Map<String, File> files;

  @override
  Future<File?> mediaFile(MediaRef media, {void Function(double progress)? onProgress}) async => files[media.hash];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // As in the app: the player's video output waits for frames.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  MediaKit.ensureInitialized();

  testWidgets('photos, videos and audio are measured, then open and play in the viewer', (tester) async {
    final dir = Directory.systemTemp.createTempSync('hanashi_viewer_');
    addTearDown(() => dir.delete(recursive: true));

    /// Runs [command] in a shell; the file it should make, if it did.
    Future<File?> make(String name, String command) async {
      final file = File('${dir.path}/$name');
      await tester.runAsync(() => Process.run('bash', ['-c', command], workingDirectory: dir.path));
      return file.existsSync() && file.lengthSync() > 0 ? file : null;
    }

    const ffmpeg = 'ffmpeg -loglevel error -y';
    const picture = '-f lavfi -i testsrc=duration=3:size=320x240:rate=24 -pix_fmt yuv420p';
    const tone = '-f lavfi -i sine=duration=3';
    Future<File?> webm(String name, String codec) async =>
        await make(name, '$ffmpeg $picture $tone -c:v libvpx${codec == 'vp9' ? '-vp9' : ''} -c:a libvorbis -shortest $name') ??
        await make(
          name,
          '$ffmpeg $picture -f yuv4mpegpipe - | vpxenc --quiet --passes=1 --codec=$codec -o v-$name - && '
          '$ffmpeg -i v-$name $tone -c:v copy -c:a libvorbis -shortest $name',
        );

    final photo = File('${dir.path}/photo.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 400, height: 300)..clear(img.ColorRgb8(90, 160, 220))));
    // What each should go as: the type, and the MIME type.
    final files = <(File?, MessageType, String)>[
      (photo, MessageType.image, 'image/png'),
      (await make('clip.mp4', '$ffmpeg $picture clip.mp4'), MessageType.video, 'video/mp4'),
      (await webm('clip.webm', 'vp9'), MessageType.video, 'video/webm'),
      (await webm('vp8.webm', 'vp8'), MessageType.video, 'video/webm'),
      (await make('song.flac', '$ffmpeg $tone -c:a flac song.flac'), MessageType.file, 'audio/x-flac'),
      // Its cover is a picture track; still audio.
      (
        await make(
          'cover.flac',
          '$ffmpeg -f lavfi -i testsrc=size=300x300 -frames:v 1 cover.png && '
              '$ffmpeg $tone -i cover.png -map 0 -map 1 -c:a flac -c:v png -disposition:v attached_pic cover.flac',
        ),
        MessageType.file,
        'audio/x-flac',
      ),
      (await make('song.m4a', '$ffmpeg $tone -c:a aac song.m4a'), MessageType.file, 'audio/mp4'),
    ];

    final local = <String, File>{};
    final envelopes = <Envelope>[];
    for (final (file, type, mime) in files) {
      if (file == null) continue; // No encoder for it here.
      final name = file.uri.pathSegments.last;
      final prepared = (await tester.runAsync(
        () => prepareAttachment(
          path: file.path,
          name: name,
          tempDir: Directory('${dir.path}/tmp'),
          probeVideo: probeVideoWithPlayer,
        ),
      ))!;
      debugPrint('Sent $name as ${prepared.type.name} ${prepared.media.toJson()..remove('hash')}');
      expect((prepared.type, prepared.media.mime), (type, mime), reason: name);
      if (type == MessageType.video) expect(prepared.media.width, 320, reason: name);
      if (type != MessageType.image) expect(prepared.media.durationMs, inInclusiveRange(2800, 3200), reason: name);
      local[prepared.media.hash] = file;
      envelopes.add(Envelope.media(conv: 'c', from: 'kumiko@localhost', type: prepared.type, media: prepared.media));
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(_Files(local))],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ListView(
                children: [
                  for (final e in envelopes)
                    TextButton(onPressed: () => MediaViewerScreen.open(context, e), child: Text(e.media!.name!)),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    for (final (i, envelope) in envelopes.indexed) {
      final name = envelope.media!.name!;
      debugPrint('Viewer: $name');
      await tester.tap(find.text(name));
      // Plays for a while.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(MediaViewerScreen), findsOneWidget);
      expect(find.textContaining('Could not load'), findsNothing, reason: name);
      // Closed with the back button, Escape (which the video controls also
      // take, for leaving full screen) or Backspace.
      switch (i % 3) {
        case 0:
          // A video's bar fades with its controls while it plays; moving the
          // pointer brings them back.
          final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: tester.getCenter(find.byType(MediaViewerScreen)));
          await mouse.moveBy(const Offset(4, 4));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byType(BackButton));
          await mouse.removePointer();
        case 1:
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case _:
          await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(MediaViewerScreen), findsNothing);
    }
  });

  testWidgets("on phones, the system's bars hide and show with a playing video's controls", (tester) async {
    final dir = Directory.systemTemp.createTempSync('hanashi_viewer_');
    addTearDown(() => dir.delete(recursive: true));
    final clip = File('${dir.path}/clip.mp4');
    await tester.runAsync(
      () => Process.run('ffmpeg', [
        ...['-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=duration=10:size=320x240:rate=24'],
        ...['-f', 'lavfi', '-i', 'sine=duration=10', '-pix_fmt', 'yuv420p', '-shortest', clip.path],
      ]),
    );
    if (!clip.existsSync()) return debugPrint('No ffmpeg to make a video with; skipped');
    final video = Envelope.media(
      conv: 'c',
      from: 'kumiko@localhost',
      type: MessageType.video,
      media: MediaRef(hash: 'sha256:${'2' * 64}', size: 1, mime: 'video/mp4', name: 'clip.mp4'),
    );

    // The phone's controls, on this desktop's player.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final system = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) system.add(call.method);
      return null;
    });
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(_Files({video.media!.hash: clip})),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(onPressed: () => MediaViewerScreen.open(context, video), child: const Text('Open')),
              ),
            ),
          ),
        ),
      );
      Future<void> wait(int tenths) async {
        for (var i = 0; i < tenths; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.text('Open'));
      await wait(10);
      expect(find.textContaining('Could not load'), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      expect(system, isEmpty);

      // The controls hide by themselves after a while, and the bars with them.
      await wait(40);
      expect(find.byType(BackButton), findsNothing);
      const hide = 'SystemChrome.setEnabledSystemUIMode', show = 'SystemChrome.setEnabledSystemUIOverlays';
      expect(system, [hide]);

      // A tap brings them all back.
      await tester.tapAt(tester.getCenter(find.byType(MediaViewerScreen)));
      await wait(5);
      expect(find.byType(BackButton), findsOneWidget);
      expect(system, [hide, show]);

      // Closed while they are hidden, they come back.
      await wait(40);
      expect(system, [hide, show, hide]);
      await tester.binding.handlePopRoute();
      await wait(10);
      expect(find.byType(MediaViewerScreen), findsNothing);
      expect(system, [hide, show, hide, show]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
}
