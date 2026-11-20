/// Draws the app's own icon, a white speech bubble on a theme's header colour,
/// in each form the app and its builds take:
///
/// - `assets/branding/icon_<theme>.png`: each built-in theme's, in the tray,
///   on Linux notifications, in the taskbar and on a phone's home screen,
///   512 px, rounded (see `lib/data/themes/builtin_themes.dart`);
/// - `branding/app_icon.png`: what `flutter_launcher_icons` makes the
///   launcher, `.exe` and app bundle icons of, in Default's colour, 1024 px,
///   square to its edges and opaque (iOS and Android round it themselves);
/// - `branding/app_icon_foreground.png`: the bubble alone, for Android's
///   adaptive icon, whose background is Default's colour (pubspec.yaml);
/// - `../packaging/linux/app.nullpointr.hanashi.png`: the Linux packages',
///   in Default's colour, 256 px, rounded.
///
/// Run from `app/`, then `dart run flutter_launcher_icons`:
/// `dart run tool/make_default_icon.dart`
library;

import 'dart:io';

import 'package:image/image.dart' as img;

/// The built-in themes' light headers, by theme (test/theme_tool_test.dart
/// keeps them the same as the themes').
const builtInHeaders = {
  'default': 0xFF2AA198,
  'sakura': 0xFFFB94A7,
  'ocean': 0xFF3B82C4,
  'forest': 0xFF4F9D69,
  'lavender': 0xFF9B7FD4,
  'ember': 0xFFE07A4F,
  'graphite': 0xFF4B5563,
};

const _white = (0xFF, 0xFF, 0xFF);

/// Samples per pixel along each axis: edges come out smooth.
const _samples = 4;

void main() {
  for (final MapEntry(key: theme, value: colour) in builtInHeaders.entries) {
    _write('assets/branding/icon_$theme.png', 512, colour);
  }
  final ours = builtInHeaders['default']!;
  _write('branding/app_icon.png', 1024, ours, rounded: false, opaque: true);
  // As large as the art of the icon it replaces: Android insets it, and
  // masks the rest.
  _write('branding/app_icon_foreground.png', 1024, ours, ground: false, scale: 0.68);
  _write('../packaging/linux/app.nullpointr.hanashi.png', 256, ours);
}

/// The icon at [size]: on its [colour]ed [ground], [rounded] or square to
/// its edges, or the bubble alone; the bubble [scale]d about the middle.
void _write(
  String path,
  int size,
  int colour, {
  bool ground = true,
  bool rounded = true,
  bool opaque = false,
  double scale = 1,
}) {
  final pink = ((colour >> 16) & 0xFF, (colour >> 8) & 0xFF, colour & 0xFF);
  final icon = img.Image(width: size, height: size, numChannels: opaque ? 3 : 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var under = 0;
      var bubble = 0;
      for (var sy = 0; sy < _samples; sy++) {
        for (var sx = 0; sx < _samples; sx++) {
          final u = (x + (sx + 0.5) / _samples) / size;
          final v = (y + (sy + 0.5) / _samples) / size;
          final inBubble = scale == 1 ? _inBubble(u, v) : _inBubble(0.5 + (u - 0.5) / scale, 0.5 + (v - 0.5) / scale);
          if (ground) {
            if (rounded && !_roundedRect(u, v, 0, 0, 1, 1, 0.225)) continue;
            under++;
          }
          if (inBubble) bubble++;
        }
      }
      final all = _samples * _samples;
      if (!ground) {
        icon.setPixelRgba(x, y, _white.$1, _white.$2, _white.$3, (255 * bubble / all).round());
        continue;
      }
      final white = bubble / all;
      int mix(int a, int b) => (a + (b - a) * white).round();
      final (r, g, b) = (mix(pink.$1, _white.$1), mix(pink.$2, _white.$2), mix(pink.$3, _white.$3));
      if (opaque) {
        icon.setPixelRgb(x, y, r, g, b);
      } else {
        icon.setPixelRgba(x, y, r, g, b, (255 * under / all).round());
      }
    }
  }
  final file = File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(icon, level: 9));
  stdout.writeln('Wrote ${file.path} ($size×$size, ${file.lengthSync()} bytes)');
}

/// The bubble, its tail at the lower left, and three dots in it.
bool _inBubble(double u, double v) {
  final body = _roundedRect(u, v, 0.20, 0.24, 0.80, 0.68, 0.13);
  final tail = _triangle(u, v, (0.30, 0.60), (0.47, 0.66), (0.24, 0.80));
  if (!body && !tail) return false;
  for (final dot in const [0.35, 0.50, 0.65]) {
    if (_circle(u, v, dot, 0.46, 0.05)) return false;
  }
  return true;
}

bool _roundedRect(double u, double v, double left, double top, double right, double bottom, double radius) {
  if (u < left || u > right || v < top || v > bottom) return false;
  final dx = u < left + radius ? left + radius - u : (u > right - radius ? u - (right - radius) : 0.0);
  final dy = v < top + radius ? top + radius - v : (v > bottom - radius ? v - (bottom - radius) : 0.0);
  return dx * dx + dy * dy <= radius * radius;
}

bool _circle(double u, double v, double cx, double cy, double radius) =>
    (u - cx) * (u - cx) + (v - cy) * (v - cy) <= radius * radius;

bool _triangle(double u, double v, (double, double) a, (double, double) b, (double, double) c) {
  double side((double, double) p, (double, double) q) => (q.$1 - p.$1) * (v - p.$2) - (q.$2 - p.$2) * (u - p.$1);
  final (ab, bc, ca) = (side(a, b), side(b, c), side(c, a));
  return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0);
}
