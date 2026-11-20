import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/launcher/theme_launcher.dart';
import 'package:image/image.dart' as img;

void main() {
  img.Image icon(String asset) => img.decodePng(shortcutIcon(File(asset).readAsBytesSync()))!;

  test("a rounded icon fills an adaptive icon's layer: its colour all round, itself in the middle", () {
    final layer = icon('assets/branding/icon_default.png');
    expect((layer.width, layer.height), (shortcutIconSide, shortcutIconSide));
    // Where launchers cut the shape, and the corners: the icon's teal.
    for (final (x, y) in [(2, 2), (shortcutIconSide - 3, 2), (2, shortcutIconSide - 3), (shortcutIconSide ~/ 2, 40)]) {
      final pixel = layer.getPixel(x, y);
      expect((pixel.r, pixel.g, pixel.b, pixel.a), (0x2A, 0xA1, 0x98, 255), reason: '($x, $y)');
    }
    // The bubble, white, in the middle 72 dp of 108.
    final middle = layer.getPixel(shortcutIconSide ~/ 2, shortcutIconSide * 40 ~/ 108);
    expect((middle.r, middle.g, middle.b), (255, 255, 255));
  });

  test('a square icon too, and anything but a picture is refused', () {
    final layer = icon('branding/app_icon.png');
    final corner = layer.getPixel(0, 0);
    expect((corner.r, corner.g, corner.b), (0x2A, 0xA1, 0x98));
    expect(() => shortcutIcon(File('assets/sounds/ringtone.wav').readAsBytesSync()), throwsFormatException);
  });
}
