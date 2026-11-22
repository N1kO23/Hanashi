import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/media/media_viewer.dart';
import 'package:hanashi/ui/window/window_controls.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'support/test_app.dart';

void main() {
  testWidgets('Escape or Backspace closes the viewer, on letting go', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();

    for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.backspace]) {
      await tester.tap(find.byIcon(Icons.image_outlined).first);
      // The page transition; the spinner itself never settles (the demo has
      // no files).
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MediaViewerScreen), findsOneWidget);

      // Held down, it repeats; closed only when let go.
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyRepeatEvent(key);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MediaViewerScreen), findsOneWidget, reason: key.keyLabel);
      await tester.sendKeyUpEvent(key);
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsNothing, reason: key.keyLabel);
    }
    // Back in the chat.
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
  });

  testWidgets('a picture shown larger than it is keeps its pixels sharp; one shown smaller is smoothed', (
    tester,
  ) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final dir = Directory.systemTemp.createTempSync('hanashi_viewer_');
    addTearDown(() => dir.delete(recursive: true));
    final image = find.byKey(const Key('viewer-image'));
    FilterQuality quality() => tester.widget<Image>(image).filterQuality;

    Future<void> show(int width, int height, {LinkPreview Function(MediaRef picture)? link}) async {
      final file = File('${dir.path}/$width.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: width, height: height)));
      final picture = MediaRef(
        hash: 'sha256:${'$width'.padLeft(64, '0')}',
        size: 1,
        mime: 'image/png',
        width: width,
        height: height,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(_Files(file))],
          child: MaterialApp(
            key: UniqueKey(),
            home: link != null
                ? MediaViewerScreen.link(link: link(picture))
                : MediaViewerScreen(
                    envelope: Envelope.media(
                      conv: 'c',
                      from: 'kumiko@localhost',
                      type: MessageType.image,
                      media: picture,
                    ),
                  ),
          ),
        ),
      );
      // Read and decoded outside the test's fake clock.
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    await show(16, 8);
    expect(quality(), FilterQuality.none);
    await show(2400, 1600);
    expect(quality(), FilterQuality.medium);
    // Zoomed in until it is larger than it is: sharp again.
    final zoom = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;
    zoom.value = Matrix4.diagonal3Values(4, 4, 1);
    await tester.pump();
    expect(quality(), FilterQuality.none);

    // A link's picture as the site has it is the real thing too.
    await show(
      16,
      8,
      link: (picture) => LinkPreview(url: 'https://site.example/', thumb: picture, media: picture),
    );
    expect(quality(), FilterQuality.none);
    // Without it, the picture made small for the chat only stands in for it.
    await show(
      16,
      8,
      link: (picture) => LinkPreview(url: 'https://site.example/', thumb: picture),
    );
    expect(quality(), FilterQuality.medium);
  });
  group('to see the picture alone', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_viewer_'));
    tearDown(() => dir.delete(recursive: true));

    final photo = Envelope.media(
      conv: 'c',
      from: 'kumiko@localhost',
      type: MessageType.image,
      caption: 'At the beach',
      media: MediaRef(hash: 'sha256:${'1' * 64}', size: 1, mime: 'image/png', width: 64, height: 32),
    );

    /// A chat with a button that opens [envelope] in the viewer.
    Future<void> openViewer(
      WidgetTester tester,
      Envelope envelope, {
      MockChatRepository? repo,
      WindowControls? window,
    }) async {
      final file = File('${dir.path}/photo.png')..writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 32)));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(repo ?? _Files(file)),
            windowControlsProvider.overrideWithValue(window),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) =>
                    TextButton(onPressed: () => MediaViewerScreen.open(context, envelope), child: const Text('Open')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    bool shown(WidgetTester tester, String key) => !tester
        .widget<IgnorePointer>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(IgnorePointer)).first)
        .ignoring;

    testWidgets("a tap hides the bar and the caption, and on phones the system's bars; another brings them back", (
      tester,
    ) async {
      await setSurfaceSize(tester, const Size(400, 800));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final system = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) system.add('${call.method} ${call.arguments}');
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      try {
        await openViewer(tester, photo);
        expect((shown(tester, 'viewer-bar'), shown(tester, 'viewer-caption')), (true, true));
        expect(find.text('At the beach'), findsOneWidget);

        await tester.tapAt(const Offset(200, 400));
        await tester.pump(const Duration(milliseconds: 300));
        expect((shown(tester, 'viewer-bar'), shown(tester, 'viewer-caption')), (false, false));
        expect(system, ['SystemChrome.setEnabledSystemUIMode SystemUiMode.immersiveSticky']);

        await tester.tapAt(const Offset(200, 400));
        await tester.pump(const Duration(milliseconds: 300));
        expect((shown(tester, 'viewer-bar'), shown(tester, 'viewer-caption')), (true, true));
        expect(system.last, startsWith('SystemChrome.setEnabledSystemUIOverlays'));

        // Closed while bare: the system's bars come back.
        await tester.tapAt(const Offset(200, 400));
        await tester.pump(const Duration(milliseconds: 300));
        system.clear();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewerScreen), findsNothing);
        expect(system, [startsWith('SystemChrome.setEnabledSystemUIOverlays')]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on desktops, F11 makes the window full screen; Escape leaves that before it closes', (tester) async {
      await setSurfaceSize(tester, const Size(1200, 800));
      final window = FakeWindowControls();
      await openViewer(tester, photo, window: window);

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();
      expect(window.calls, ['fullScreen']);
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(window.calls, ['fullScreen', 'leaveFullScreen']);
      expect(find.byType(MediaViewerScreen), findsOneWidget);

      // The button too; closing leaves full screen.
      await tester.tap(find.byKey(const Key('viewer-full-screen')));
      await tester.pump();
      expect(window.calls.last, 'fullScreen');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsNothing);
      expect(window.calls, ['fullScreen', 'leaveFullScreen', 'fullScreen', 'leaveFullScreen']);
    });

    testWidgets("a video's bar goes with the player's controls, which have their own full screen", (tester) async {
      await setSurfaceSize(tester, const Size(1200, 800));
      final video = Envelope.media(
        conv: 'c',
        from: 'kumiko@localhost',
        type: MessageType.video,
        media: MediaRef(hash: 'sha256:${'2' * 64}', size: 1, mime: 'video/mp4', name: 'clip.mp4'),
      );
      // No player in tests: it does not get as far as playing.
      await openViewer(tester, video, repo: _Nothing(), window: FakeWindowControls());
      expect(find.textContaining('Could not load the video'), findsOneWidget);
      expect(find.byKey(const Key('viewer-bar')), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.byKey(const Key('viewer-full-screen')), findsNothing);
    });

    testWidgets("a video's caption stays put as the system's bars come and go with the controls", (tester) async {
      await setSurfaceSize(tester, const Size(400, 800));
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
      final video = Envelope.media(
        conv: 'c',
        from: 'kumiko@localhost',
        type: MessageType.video,
        caption: 'At the beach',
        media: MediaRef(hash: 'sha256:${'2' * 64}', size: 1, mime: 'video/mp4', name: 'clip.mp4'),
      );
      await openViewer(tester, video, repo: _Nothing());
      final caption = find.text('At the beach');
      expect(tester.getBottomLeft(caption).dy, 800 - 48 - 16);

      // The bars hidden.
      tester.view.padding = FakeViewPadding.zero;
      await tester.pump();
      expect(tester.getBottomLeft(caption).dy, 800 - 48 - 16);

      // Turned: the bars are elsewhere.
      await setSurfaceSize(tester, const Size(800, 400));
      await tester.pump();
      expect(tester.getBottomLeft(caption).dy, 400 - 16);
    });
  });
}

/// Has no file at all.
class _Nothing extends MockChatRepository {
  _Nothing() : super(latency: Duration.zero, autoReply: false, now: testNow);

  @override
  File? mediaFileOf(MediaRef media) => null;
}

/// Has [file] for every file asked for.
class _Files extends MockChatRepository {
  _Files(this.file) : super(latency: Duration.zero, autoReply: false, now: testNow);

  final File file;

  @override
  File? mediaFileOf(MediaRef media) => file;
}
