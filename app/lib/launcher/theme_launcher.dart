import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../data/themes/app_theme.dart';
import '../data/themes/builtin_themes.dart';
import '../diagnostics/app_log.dart';

const _log = Log('launcher');

/// The app on a phone's home screen as the theme shown names and draws it: a
/// shortcut the user pins once (Android 8 and later, where the launcher takes
/// pinned shortcuts), which follows the theme from then on. The launcher's
/// own entry for the app stays the build's: Android changes that for nothing
/// the app was not built with (see `ThemeShortcut.kt`).
class ThemeLauncher {
  const ThemeLauncher();

  static const _channel = MethodChannel('hanashi/shortcut');

  /// Whether this device can pin one.
  Future<bool> supported() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on PlatformException catch (e) {
      _log.info('No pinned shortcuts: $e');
      return false;
    }
  }

  /// Asks the launcher to pin a shortcut of [theme] (or updates the one
  /// pinned); the user confirms there. False if the launcher would not.
  Future<bool> pin(AppTheme theme) async => await _channel.invokeMethod<bool>('pin', await _arguments(theme)) ?? false;

  /// The pinned shortcut, if there is one, as [theme] has it.
  Future<void> follow(AppTheme theme) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('update', await _arguments(theme));
    } on Object catch (e) {
      _log.info('Could not update the home-screen shortcut: $e');
    }
  }

  static Future<Map<String, Object>> _arguments(AppTheme theme) async {
    final png = await _iconOf(theme);
    return {
      'label': theme.shownName,
      // Off the UI's isolate: a large icon takes a moment to scale.
      'icon': await Isolate.run(() => shortcutIcon(png)),
    };
  }

  static Future<Uint8List> _iconOf(AppTheme theme) async =>
      switch (theme.assets.appIcon ?? defaultTheme.assets.appIcon!) {
        AssetSource(:final asset) => (await rootBundle.load(asset)).buffer.asUint8List(),
        FileSource(:final path) => File(path).readAsBytes(),
      };
}

/// The side of [shortcutIcon]'s picture: an adaptive icon's 108 dp at 4×.
const shortcutIconSide = 432;

/// [png], an app icon, as an adaptive icon's full layer: drawn into the
/// middle 72 of its 108 dp, which launchers show (cutting it to their shape),
/// on the colour of the icon's edge, so that the shape is filled whatever its
/// size. Square icons and rounded ones (whose corners are clear) alike.
Uint8List shortcutIcon(Uint8List png) {
  final icon = img.decodeImage(png);
  if (icon == null) throw const FormatException('Not a picture');
  const side = shortcutIconSide;
  const inner = side * 72 ~/ 108;
  // The middle of its top edge: the ground, also on a rounded icon.
  final edge = icon.getPixel(icon.width ~/ 2, icon.height ~/ 64);
  final ground = edge.a == 0
      ? img.ColorRgba8(255, 255, 255, 255)
      : img.ColorRgba8(edge.r.toInt(), edge.g.toInt(), edge.b.toInt(), 255);
  final canvas = img.Image(width: side, height: side, numChannels: 4)..clear(ground);
  final fitted = img.copyResize(icon, width: inner, height: inner, interpolation: img.Interpolation.average);
  img.compositeImage(canvas, fitted, dstX: (side - inner) ~/ 2, dstY: (side - inner) ~/ 2);
  return img.encodePng(canvas);
}
