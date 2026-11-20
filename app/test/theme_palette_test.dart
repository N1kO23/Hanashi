import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';

void main() {
  test("a theme's colours go over those of its brightness, the rest stay", () {
    final palette = HanashiPalette.fromJson({
      'header': '#112233',
      'outgoingBubble': '#80445566',
      // A later version's colour.
      'sparkle': '#123456',
    }, base: HanashiPalette.dark);
    expect(palette.brightness, Brightness.dark);
    expect(palette.header, const Color(0xFF112233));
    expect(palette.outgoingBubble, const Color(0x80445566));
    expect(palette.chatBackground, HanashiPalette.dark.chatBackground);
    expect(palette.avatarColors, HanashiPalette.dark.avatarColors);
    expect(
      HanashiPalette.fromJson({
        'avatarColors': ['#ABCDEF'],
      }, base: HanashiPalette.light).avatarColors,
      [const Color(0xFFABCDEF)],
    );
  });

  test('refuses colours it cannot read, saying which', () {
    for (final wrong in ['red', '#12345', '#1234567', 'FB94A7', '#GGGGGG', 0xFFFFFFFF, true]) {
      expect(
        () => HanashiPalette.fromJson({'header': wrong}, base: HanashiPalette.light),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('"header"'))),
        reason: '$wrong',
      );
    }
    for (final wrong in [<Object?>[], '#FFFFFF']) {
      expect(() => HanashiPalette.fromJson({'avatarColors': wrong}, base: HanashiPalette.light), throwsFormatException);
    }
    expect(
      () => HanashiPalette.fromJson({
        'avatarColors': ['#FFFFFF', 'pink'],
      }, base: HanashiPalette.light),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('avatarColors[1]'))),
    );
  });

  test('writes every colour, and reads them back the same', () {
    for (final palette in [HanashiPalette.light, HanashiPalette.dark]) {
      final json = palette.toJson();
      expect(json.keys, containsAll([for (final slot in PaletteSlot.values) slot.name]));
      // Over the other brightness's colours: none of those stays.
      final other = palette.brightness == Brightness.light ? HanashiPalette.dark : HanashiPalette.light;
      final back = HanashiPalette.fromJson(json, base: other);
      expect(back.copyWith(brightness: palette.brightness), palette);
      expect(back.copyWith(brightness: palette.brightness).hashCode, palette.hashCode);
    }
    expect(HanashiPalette.formatColor(const Color(0xFFFB94A7)), '#FB94A7');
    expect(HanashiPalette.formatColor(const Color(0x1F000000)), '#1F000000');
    expect(HanashiPalette.parseColor('#fb94a7', 'header'), const Color(0xFFFB94A7));
  });

  test('every colour of a palette, by its slot', () {
    final palette = HanashiPalette.light.copyWith(colors: {PaletteSlot.header: const Color(0xFF000001)});
    expect(palette.header, const Color(0xFF000001));
    expect(palette[PaletteSlot.header], const Color(0xFF000001));
    expect(palette[PaletteSlot.textPrimary], HanashiPalette.light.textPrimary);
    expect(HanashiPalette.of(Brightness.dark), HanashiPalette.dark);
    expect(HanashiPalette.light == HanashiPalette.dark, isFalse);
  });

  test('changes colour by colour between two palettes', () {
    final halfway = HanashiPalette.light.lerp(HanashiPalette.dark, 0.5);
    expect(halfway.header, Color.lerp(HanashiPalette.light.header, HanashiPalette.dark.header, 0.5));
    expect(HanashiPalette.light.lerp(HanashiPalette.dark, 1), HanashiPalette.dark);
  });

  test("Default's scheme: Material's tones from its header, its accent the palette's", () {
    expect(
      buildHanashiTheme().colorScheme,
      ColorScheme.fromSeed(
        seedColor: HanashiPalette.light.header,
        primary: HanashiPalette.light.replyAccent,
        surface: HanashiPalette.light.chatBackground,
      ),
    );
    final dark = buildHanashiTheme(HanashiPalette.dark);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.extension<HanashiPalette>(), HanashiPalette.dark);
    expect(dark.extension<HanashiBranding>(), HanashiBranding.none);
    expect(HanashiBranding.none.appName, appTitle);
  });
}
