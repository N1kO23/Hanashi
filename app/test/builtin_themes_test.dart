import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/themes/app_theme.dart';
import 'package:hanashi/data/themes/builtin_themes.dart';
import 'package:hanashi/data/themes/theme_manifest.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('Default first, then each built-in theme once, of an ID a file cannot take', () {
    expect(builtInThemes.first, defaultTheme);
    final ids = [for (final theme in builtInThemes) theme.id];
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, ['default', 'sakura', 'ocean', 'forest', 'lavender', 'ember', 'graphite']);
    for (final theme in builtInThemes) {
      expect(theme.origin, ThemeOrigin.builtIn);
      expect(ThemeManifest.idPattern.hasMatch(theme.id), isTrue, reason: theme.id);
      expect(theme.light.brightness, Brightness.light);
      expect(theme.dark.brightness, Brightness.dark);
      // Every one names the app as it is.
      expect(theme.shownName, appTitle);
    }
  });

  test("each has an icon of its own, among the app's assets, and Default's ringtone", () {
    for (final theme in builtInThemes) {
      final icon = theme.assets.appIcon! as AssetSource;
      expect(icon.asset, 'assets/branding/icon_${theme.id}.png');
      expect(File(icon.asset).existsSync(), isTrue, reason: icon.asset);
      expect(theme.assets.ringtone, defaultTheme.assets.ringtone);
      expect(theme.assets.messageSound, isNull);
    }
  });

  test('each looks like itself: its header, rail and bubbles its own', () {
    final looks = {
      for (final theme in builtInThemes) theme.id: (theme.light.header, theme.light.outgoingBubble, theme.dark.header),
    };
    expect(looks.values.toSet(), hasLength(builtInThemes.length));
  });

  test('Sakura: the colours the app had before 0.9', () {
    final sakura = builtInThemes.firstWhere((theme) => theme.id == 'sakura');
    const before = {
      PaletteSlot.header: (0xFFFB94A7, 0xFFB8566C),
      PaletteSlot.rail: (0xFF4C5B70, 0xFF252B35),
      PaletteSlot.railSelected: (0xFF67788C, 0xFF343C49),
      PaletteSlot.railIcon: (0xFF8D97A5, 0xFF7D8898),
      PaletteSlot.listSelected: (0xFFDAE5E9, 0xFF222A35),
      PaletteSlot.incomingBubble: (0xFF4C5B70, 0xFF3A4658),
      PaletteSlot.outgoingBubble: (0xFF4A8FD3, 0xFF2F6DAA),
      PaletteSlot.replyPanel: (0xFFE1ECF0, 0xFF1A2530),
      PaletteSlot.replyAccent: (0xFF4D97B4, 0xFF5AAED0),
    };
    for (final slot in PaletteSlot.values) {
      final (light, dark) =
          before[slot] ?? (HanashiPalette.light[slot].toARGB32(), HanashiPalette.dark[slot].toARGB32());
      expect(sakura.light[slot], Color(light), reason: '$slot');
      expect(sakura.dark[slot], Color(dark), reason: '$slot');
    }
    expect(
      buildHanashiTheme(sakura.light).colorScheme,
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFFB94A7),
        primary: const Color(0xFF4D97B4),
        surface: HanashiPalette.light.chatBackground,
      ),
    );
  });

  test("the icon tool draws each built-in theme's icon in its header's colour", () {
    final tool = File('tool/make_default_icon.dart').readAsStringSync();
    final listed = RegExp(r'const builtInHeaders = \{(.*?)\};', dotAll: true).firstMatch(tool)!.group(1)!;
    final headers = {
      for (final m in RegExp(r"'([a-z]+)': 0x([0-9A-F]{8})").allMatches(listed)) m[1]!: int.parse(m[2]!, radix: 16),
    };
    expect(headers, {for (final theme in builtInThemes) theme.id: theme.light.header.toARGB32()});
  });
}
