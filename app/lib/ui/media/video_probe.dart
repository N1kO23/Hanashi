import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/attachments.dart';

/// Reads a video's size, duration and first frame with the platform player
/// (libmpv); of a file without a picture (audio), only the duration. Returns
/// null if the file cannot be played.
Future<VideoInfo?> probeVideoWithPlayer(String path) async {
  final player = Player();
  // Software decoding: hardware-decoded frames can stay in GPU memory (e.g.
  // CUDA), where mpv cannot convert them into a screenshot.
  final controller = VideoController(player, configuration: const VideoControllerConfiguration(hwdec: 'no'));
  try {
    await player.setVolume(0);
    await player.open(Media(path), play: false);
    // Loaded once its tracks are known ("auto" and "no" are mpv's choices).
    bool real(String id) => id != 'auto' && id != 'no';
    bool loaded(Tracks t) => t.video.any((v) => real(v.id)) || t.audio.any((a) => real(a.id));
    final tracks = loaded(player.state.tracks)
        ? player.state.tracks
        : await player.stream.tracks.firstWhere(loaded).timeout(const Duration(seconds: 8));
    // Not every file says how long it is (e.g. WebM recorded in a browser).
    var duration = player.state.duration;
    if (duration == Duration.zero) {
      duration = await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3), onTimeout: () => Duration.zero);
    }
    final known = duration == Duration.zero ? null : duration;
    // Audio: no picture (an album cover is none).
    if (!tracks.video.any((t) => real(t.id) && t.albumart != true)) return VideoInfo(duration: known);
    final width =
        player.state.width ??
        await player.stream.width.firstWhere((w) => (w ?? 0) > 0).timeout(const Duration(seconds: 8));
    final height = player.state.height ?? await player.stream.height.firstWhere((h) => (h ?? 0) > 0);
    Uint8List? frame;
    try {
      await controller.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 5));
      frame = await _captureFrame(player);
    } catch (_) {
      // No thumbnail; the bubble shows a placeholder instead.
    }
    return VideoInfo(
      width: width,
      height: height,
      duration: known,
      frameJpeg: frame,
      hasAudio: tracks.audio.any((a) => real(a.id)),
    );
  } catch (_) {
    return null;
  } finally {
    await player.dispose();
  }
}

/// Has mpv write the current frame to a JPEG file and reads it back.
///
/// Used instead of `Player.screenshot()`, which in media_kit 1.2.6 sizes its
/// mpv argument array by string length rather than by pointer count;
/// `command()` builds a properly null-terminated array.
Future<Uint8List?> _captureFrame(Player player) async {
  final native = player.platform;
  if (native is! NativePlayer) return null;
  final dir = await Directory.systemTemp.createTemp('hanashi-frame-');
  try {
    final file = File('${dir.path}/frame.jpg');
    await native.command(['screenshot-to-file', file.path, 'video']);
    return file.existsSync() ? await file.readAsBytes() : null;
  } finally {
    await dir.delete(recursive: true);
  }
}
