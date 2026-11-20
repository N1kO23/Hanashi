import 'package:material_ui/material_ui.dart';

import '../../ui/theme/hanashi_theme.dart';
import 'app_theme.dart';

/// The theme a device starts with, and shows if the one chosen is gone.
const defaultThemeId = 'default';

/// The app's own look: teal over slate (`HanashiPalette.light` and `.dark`, which
/// the other built-in themes and themes' files change parts of). The title
/// bar writes the app's name, the tray shows the app's icon, and new messages
/// make the system's sound.
const defaultTheme = AppTheme(
  id: defaultThemeId,
  title: 'Default',
  light: HanashiPalette.light,
  dark: HanashiPalette.dark,
  assets: ThemeAssets(appIcon: AssetSource('assets/branding/icon_default.png'), ringtone: _ringtone),
  origin: ThemeOrigin.builtIn,
);

const _ringtone = AssetSource('assets/sounds/ringtone.wav');

/// A built-in theme of Default's colours with [light]'s and [dark]'s over
/// them, as a theme's file has it, and an icon of its own colour (drawn by
/// `tool/make_default_icon.dart`).
AppTheme _builtIn(String id, String title, {required _Look light, required _Look dark}) => AppTheme(
  id: id,
  title: title,
  light: HanashiPalette.light.copyWith(colors: light.colors),
  dark: HanashiPalette.dark.copyWith(colors: dark.colors),
  assets: ThemeAssets(appIcon: AssetSource('assets/branding/icon_$id.png'), ringtone: _ringtone),
  origin: ThemeOrigin.builtIn,
);

/// What sets a built-in theme apart, in one brightness: its header, its
/// slate (the rail, and others' bubbles), its own bubbles and its accent.
typedef _Look = ({
  int header,
  int rail,
  int railSelected,
  int railIcon,
  int listSelected,
  int outgoing,
  int replyPanel,
  int accent,
  int? incoming,
});

extension on _Look {
  Map<PaletteSlot, Color> get colors => {
    PaletteSlot.header: Color(header),
    PaletteSlot.rail: Color(rail),
    PaletteSlot.railSelected: Color(railSelected),
    PaletteSlot.railIcon: Color(railIcon),
    PaletteSlot.listSelected: Color(listSelected),
    PaletteSlot.incomingBubble: Color(incoming ?? rail),
    PaletteSlot.outgoingBubble: Color(outgoing),
    PaletteSlot.replyPanel: Color(replyPanel),
    PaletteSlot.replyAccent: Color(accent),
  };
}

/// The themes that come with the app, in the order Settings lists them:
/// Default first.
final builtInThemes = [
  defaultTheme,
  // Pink over slate: the colours the app had before 0.9.
  _builtIn(
    'sakura',
    'Sakura',
    light: (
      header: 0xFFFB94A7,
      rail: 0xFF4C5B70,
      railSelected: 0xFF67788C,
      railIcon: 0xFF8D97A5,
      listSelected: 0xFFDAE5E9,
      incoming: null,
      outgoing: 0xFF4A8FD3,
      replyPanel: 0xFFE1ECF0,
      accent: 0xFF4D97B4,
    ),
    dark: (
      header: 0xFFB8566C,
      rail: 0xFF252B35,
      railSelected: 0xFF343C49,
      railIcon: 0xFF7D8898,
      listSelected: 0xFF222A35,
      incoming: 0xFF3A4658,
      outgoing: 0xFF2F6DAA,
      replyPanel: 0xFF1A2530,
      accent: 0xFF5AAED0,
    ),
  ),
  _builtIn(
    'ocean',
    'Ocean',
    light: (
      header: 0xFF3B82C4,
      rail: 0xFF34465F,
      railSelected: 0xFF4B6080,
      railIcon: 0xFF8796AD,
      listSelected: 0xFFD6E3F1,
      incoming: null,
      outgoing: 0xFF3B82C4,
      replyPanel: 0xFFDDE8F4,
      accent: 0xFF3577B5,
    ),
    dark: (
      header: 0xFF2A5C8C,
      rail: 0xFF1E2735,
      railSelected: 0xFF2C3950,
      railIcon: 0xFF7887A0,
      listSelected: 0xFF1E2838,
      incoming: 0xFF33445E,
      outgoing: 0xFF2A62A0,
      replyPanel: 0xFF18222F,
      accent: 0xFF5A9FDB,
    ),
  ),
  _builtIn(
    'forest',
    'Forest',
    light: (
      header: 0xFF4F9D69,
      rail: 0xFF3E5247,
      railSelected: 0xFF566D60,
      railIcon: 0xFF8FA197,
      listSelected: 0xFFD9E9DE,
      incoming: null,
      outgoing: 0xFF4F8F6A,
      replyPanel: 0xFFE0EEE4,
      accent: 0xFF3F8A5A,
    ),
    dark: (
      header: 0xFF386E4B,
      rail: 0xFF1E2A23,
      railSelected: 0xFF2C3C32,
      railIcon: 0xFF7B9083,
      listSelected: 0xFF1E2C24,
      incoming: 0xFF34483C,
      outgoing: 0xFF33704C,
      replyPanel: 0xFF17241C,
      accent: 0xFF6CC28C,
    ),
  ),
  _builtIn(
    'lavender',
    'Lavender',
    light: (
      header: 0xFF9B7FD4,
      rail: 0xFF4D4763,
      railSelected: 0xFF665E80,
      railIcon: 0xFF9A93AD,
      listSelected: 0xFFE4DEF2,
      incoming: null,
      outgoing: 0xFF7E6BC4,
      replyPanel: 0xFFE8E3F4,
      accent: 0xFF7A64C0,
    ),
    dark: (
      header: 0xFF6B579A,
      rail: 0xFF26222F,
      railSelected: 0xFF363044,
      railIcon: 0xFF8A839C,
      listSelected: 0xFF282336,
      incoming: 0xFF403A54,
      outgoing: 0xFF5E4D9C,
      replyPanel: 0xFF1E1A28,
      accent: 0xFFA691E6,
    ),
  ),
  _builtIn(
    'ember',
    'Ember',
    light: (
      header: 0xFFE07A4F,
      rail: 0xFF57463F,
      railSelected: 0xFF725D54,
      railIcon: 0xFFA7958C,
      listSelected: 0xFFF2E1D8,
      incoming: null,
      outgoing: 0xFFD0693F,
      replyPanel: 0xFFF5E6DE,
      accent: 0xFFC4602F,
    ),
    dark: (
      header: 0xFFA3543A,
      rail: 0xFF2D2420,
      railSelected: 0xFF3F332D,
      railIcon: 0xFF9A8A82,
      listSelected: 0xFF31261F,
      incoming: 0xFF4A3B35,
      outgoing: 0xFFA8522F,
      replyPanel: 0xFF251C18,
      accent: 0xFFF08C5E,
    ),
  ),
  _builtIn(
    'graphite',
    'Graphite',
    light: (
      header: 0xFF4B5563,
      rail: 0xFF2F3640,
      railSelected: 0xFF4A525E,
      railIcon: 0xFF8A929C,
      listSelected: 0xFFDEE2E7,
      incoming: 0xFF4B5563,
      outgoing: 0xFF5B6B7F,
      replyPanel: 0xFFE4E7EB,
      accent: 0xFF5B7FA6,
    ),
    dark: (
      header: 0xFF353C46,
      rail: 0xFF1C2026,
      railSelected: 0xFF2C323A,
      railIcon: 0xFF7D858F,
      listSelected: 0xFF23282F,
      incoming: 0xFF3A414B,
      outgoing: 0xFF4A5668,
      replyPanel: 0xFF1A1E23,
      accent: 0xFF8FB0D6,
    ),
  ),
];
