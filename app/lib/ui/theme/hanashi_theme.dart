import 'package:material_ui/material_ui.dart';

/// What a palette has a colour for: one name each, as theme files name them
/// (see `docs/themes.md`).
enum PaletteSlot {
  header,
  onHeader,
  rail,
  railSelected,
  railIcon,
  onRail,
  listBackground,
  listSelected,
  divider,
  panelDivider,
  chatBackground,
  surface,
  incomingBubble,
  outgoingBubble,
  onBubble,
  replyPanel,
  replyAccent,
  onAccent,
  fieldBorder,
  mediaCardBorder,
  textPrimary,
  textHeading,
  textSecondary,
  textMuted,
  unreadBadge,
  failed,
  success,
  online,
  idle,
  focus,
  offline,
  profileText,
  profilePill,
  birthday,
  birthdayText,
  warning,
  warningBackground,
  logWarning,
  shadow,
  callTile,
}

/// The colours the app is drawn with. Every widget takes its colours from the
/// palette of the current theme (`context.palette`), never from constants, so
/// that a theme can change any of them.
@immutable
class HanashiPalette extends ThemeExtension<HanashiPalette> {
  /// [colors] has a colour for every [PaletteSlot], and [avatarColors] at
  /// least one.
  const HanashiPalette({required this.brightness, required this._colors, required this.avatarColors});

  /// The Default theme's colours, which a theme's file gives only some of
  /// (see `HanashiPalette.fromJson`): teal over slate, bubbles of both.
  static const light = HanashiPalette(
    brightness: Brightness.light,
    colors: {
      PaletteSlot.header: Color(0xFF2AA198),
      PaletteSlot.onHeader: Color(0xFFFFFFFF),
      PaletteSlot.rail: Color(0xFF3E5560),
      PaletteSlot.railSelected: Color(0xFF557080),
      PaletteSlot.railIcon: Color(0xFF8FA3AB),
      PaletteSlot.onRail: Color(0xFFFFFFFF),
      PaletteSlot.listBackground: Color(0xFFF3F7F8),
      PaletteSlot.listSelected: Color(0xFFD5E8E6),
      PaletteSlot.divider: Color(0xFFE0E4E5),
      PaletteSlot.panelDivider: Color(0xFFE9E9E9),
      PaletteSlot.chatBackground: Color(0xFFFFFFFF),
      PaletteSlot.surface: Color(0xFFFFFFFF),
      PaletteSlot.incomingBubble: Color(0xFF3E5560),
      PaletteSlot.outgoingBubble: Color(0xFF2E8C9A),
      PaletteSlot.onBubble: Color(0xFFFFFFFF),
      PaletteSlot.replyPanel: Color(0xFFDCEEEC),
      PaletteSlot.replyAccent: Color(0xFF23968C),
      PaletteSlot.onAccent: Color(0xFFFFFFFF),
      PaletteSlot.fieldBorder: Color(0xFFCFDADF),
      PaletteSlot.mediaCardBorder: Color(0xFFE3E8EB),
      PaletteSlot.textPrimary: Color(0xFF232C31),
      PaletteSlot.textHeading: Color(0xFF1E2225),
      PaletteSlot.textSecondary: Color(0xFF5B6669),
      PaletteSlot.textMuted: Color(0xFF8E989C),
      PaletteSlot.unreadBadge: Color(0xFFFB4619),
      PaletteSlot.failed: Color(0xFFE5484D),
      PaletteSlot.success: Color(0xFF3CB371),
      PaletteSlot.online: Color(0xFF3CB371),
      PaletteSlot.idle: Color(0xFFF2B33D),
      PaletteSlot.focus: Color(0xFFF0607E),
      PaletteSlot.offline: Color(0xFFA9B3B8),
      PaletteSlot.profileText: Color(0xFF5E6E7E),
      PaletteSlot.profilePill: Color(0xFFE6EDF1),
      PaletteSlot.birthday: Color(0xFFFFD43B),
      PaletteSlot.birthdayText: Color(0xFF4A3B00),
      PaletteSlot.warning: Color(0xFFB4690E),
      PaletteSlot.warningBackground: Color(0xFFFFF4E0),
      PaletteSlot.logWarning: Color(0xFFB26A00),
      PaletteSlot.shadow: Color(0xFF000000),
      PaletteSlot.callTile: Color(0xFF2B3240),
    },
    avatarColors: [
      Color(0xFFF7A8B8),
      Color(0xFF8EC5FC),
      Color(0xFFB5A8F0),
      Color(0xFF8FD4B5),
      Color(0xFFFFC98B),
      Color(0xFF9CCFD8),
      Color(0xFFE3A6E0),
      Color(0xFFA9C7A0),
    ],
  );

  /// The same look at night: slate surfaces, the header a deeper teal.
  static const dark = HanashiPalette(
    brightness: Brightness.dark,
    colors: {
      PaletteSlot.header: Color(0xFF1F7A73),
      PaletteSlot.onHeader: Color(0xFFFFFFFF),
      PaletteSlot.rail: Color(0xFF1F2A2D),
      PaletteSlot.railSelected: Color(0xFF2E3D41),
      PaletteSlot.railIcon: Color(0xFF7A8E92),
      PaletteSlot.onRail: Color(0xFFFFFFFF),
      PaletteSlot.listBackground: Color(0xFF14181E),
      PaletteSlot.listSelected: Color(0xFF1E2C2E),
      PaletteSlot.divider: Color(0xFF262D37),
      PaletteSlot.panelDivider: Color(0xFF262D37),
      PaletteSlot.chatBackground: Color(0xFF0F1318),
      PaletteSlot.surface: Color(0xFF1B2028),
      PaletteSlot.incomingBubble: Color(0xFF344A4F),
      PaletteSlot.outgoingBubble: Color(0xFF22707A),
      PaletteSlot.onBubble: Color(0xFFFFFFFF),
      PaletteSlot.replyPanel: Color(0xFF172628),
      PaletteSlot.replyAccent: Color(0xFF4CC3B5),
      PaletteSlot.onAccent: Color(0xFFFFFFFF),
      PaletteSlot.fieldBorder: Color(0xFF364150),
      PaletteSlot.mediaCardBorder: Color(0xFF2A333F),
      PaletteSlot.textPrimary: Color(0xFFE6EAEF),
      PaletteSlot.textHeading: Color(0xFFF3F5F7),
      PaletteSlot.textSecondary: Color(0xFFA9B3BD),
      PaletteSlot.textMuted: Color(0xFF7A8592),
      PaletteSlot.unreadBadge: Color(0xFFFF5A2E),
      PaletteSlot.failed: Color(0xFFF0585D),
      PaletteSlot.success: Color(0xFF4CC285),
      PaletteSlot.online: Color(0xFF4CC285),
      PaletteSlot.idle: Color(0xFFF2B33D),
      PaletteSlot.focus: Color(0xFFF2708A),
      PaletteSlot.offline: Color(0xFF66717B),
      PaletteSlot.profileText: Color(0xFFA2AFBC),
      PaletteSlot.profilePill: Color(0xFF232B36),
      PaletteSlot.birthday: Color(0xFFFFD43B),
      PaletteSlot.birthdayText: Color(0xFF4A3B00),
      PaletteSlot.warning: Color(0xFFE8A247),
      PaletteSlot.warningBackground: Color(0xFF2E2414),
      PaletteSlot.logWarning: Color(0xFFE8A247),
      PaletteSlot.shadow: Color(0xFF000000),
      PaletteSlot.callTile: Color(0xFF2B3240),
    },
    avatarColors: [
      Color(0xFFF7A8B8),
      Color(0xFF8EC5FC),
      Color(0xFFB5A8F0),
      Color(0xFF8FD4B5),
      Color(0xFFFFC98B),
      Color(0xFF9CCFD8),
      Color(0xFFE3A6E0),
      Color(0xFFA9C7A0),
    ],
  );

  /// The built-in palette of [brightness]: what a theme's leaves out.
  static HanashiPalette of(Brightness brightness) => brightness == Brightness.dark ? dark : light;

  /// Whether this is a light or a dark palette: what the rest of the theme
  /// (dialogs, menus, the status bar) follows.
  final Brightness brightness;
  final Map<PaletteSlot, Color> _colors;

  /// The pictures of those without one: one of these, by their ID.
  final List<Color> avatarColors;

  Color operator [](PaletteSlot slot) => _colors[slot]!;

  /// The title bar.
  Color get header => this[PaletteSlot.header];

  /// Text and icons on the title bar.
  Color get onHeader => this[PaletteSlot.onHeader];

  /// Side rail and bottom tabs; the same slate as incoming bubbles.
  Color get rail => this[PaletteSlot.rail];

  /// The rail's selected tab.
  Color get railSelected => this[PaletteSlot.railSelected];

  /// The icons of the rail's other tabs.
  Color get railIcon => this[PaletteSlot.railIcon];

  /// The icon of the rail's selected tab, and text on the rail's slate.
  Color get onRail => this[PaletteSlot.onRail];

  /// Behind lists and panes.
  Color get listBackground => this[PaletteSlot.listBackground];

  /// The selected row of a list.
  Color get listSelected => this[PaletteSlot.listSelected];

  Color get divider => this[PaletteSlot.divider];
  Color get panelDivider => this[PaletteSlot.panelDivider];

  /// Behind a chat's messages.
  Color get chatBackground => this[PaletteSlot.chatBackground];

  /// Cards, panels, dialogs, menus and fields; also the ring that sets a badge
  /// apart from the picture under it.
  Color get surface => this[PaletteSlot.surface];

  Color get incomingBubble => this[PaletteSlot.incomingBubble];

  /// The user's own messages. Not in the reference screenshot; picked to sit
  /// beside the slate bubbles and the reply panel's blue accent.
  Color get outgoingBubble => this[PaletteSlot.outgoingBubble];

  /// Text and icons in a bubble, of either colour.
  Color get onBubble => this[PaletteSlot.onBubble];

  /// The "Reply" panel under a chat, used for the composer.
  Color get replyPanel => this[PaletteSlot.replyPanel];

  /// The accent: buttons, links, the selected tab's indicator.
  Color get replyAccent => this[PaletteSlot.replyAccent];

  /// Text and icons on accent fills: buttons, badges, avatars' initials.
  Color get onAccent => this[PaletteSlot.onAccent];

  Color get fieldBorder => this[PaletteSlot.fieldBorder];
  Color get mediaCardBorder => this[PaletteSlot.mediaCardBorder];
  Color get textPrimary => this[PaletteSlot.textPrimary];
  Color get textHeading => this[PaletteSlot.textHeading];
  Color get textSecondary => this[PaletteSlot.textSecondary];
  Color get textMuted => this[PaletteSlot.textMuted];
  Color get unreadBadge => this[PaletteSlot.unreadBadge];
  Color get failed => this[PaletteSlot.failed];

  /// What is as it should be: a verified contact, an encrypted chat, a
  /// connection.
  Color get success => this[PaletteSlot.success];

  /// Status badges on pictures (see `StatusBadge`).
  Color get online => this[PaletteSlot.online];

  Color get idle => this[PaletteSlot.idle];
  Color get focus => this[PaletteSlot.focus];
  Color get offline => this[PaletteSlot.offline];

  /// The line under a name on a profile card, and its facts' pills.
  Color get profileText => this[PaletteSlot.profileText];

  Color get profilePill => this[PaletteSlot.profilePill];

  /// The "B-DAY" tag on the picture of someone whose birthday is today.
  Color get birthday => this[PaletteSlot.birthday];

  Color get birthdayText => this[PaletteSlot.birthdayText];

  /// Security notices in a chat (sending paused, a key changed).
  Color get warning => this[PaletteSlot.warning];

  Color get warningBackground => this[PaletteSlot.warningBackground];

  /// Warnings in the app's log.
  Color get logWarning => this[PaletteSlot.logWarning];

  /// Shadows, at the opacity each needs.
  Color get shadow => this[PaletteSlot.shadow];

  /// The tile of someone in a call without video.
  Color get callTile => this[PaletteSlot.callTile];

  /// A theme file's colours for one brightness over [base], the built-in
  /// palette of it (see [of]): `{"header": "#FB94A7", ..., "avatarColors":
  /// [...]}`. Whatever it leaves out is [base]'s, and names it does not know
  /// are left alone, for later versions. Throws a [FormatException] for a
  /// colour that is not `#RRGGBB` or `#AARRGGBB`.
  factory HanashiPalette.fromJson(Map<String, Object?> json, {required HanashiPalette base}) {
    final colors = {...base._colors};
    for (final slot in PaletteSlot.values) {
      final value = json[slot.name];
      if (value != null) colors[slot] = parseColor(value, slot.name);
    }
    final avatars = json['avatarColors'];
    if (avatars != null && (avatars is! List || avatars.isEmpty)) {
      throw const FormatException('"avatarColors" must list at least one colour');
    }
    return HanashiPalette(
      brightness: base.brightness,
      colors: colors,
      avatarColors: avatars is List
          ? [for (final (i, color) in avatars.indexed) parseColor(color, 'avatarColors[$i]')]
          : base.avatarColors,
    );
  }

  /// Every colour, as theme files write them.
  Map<String, Object?> toJson() => {
    for (final slot in PaletteSlot.values) slot.name: formatColor(this[slot]),
    'avatarColors': [for (final color in avatarColors) formatColor(color)],
  };

  static final _hex = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

  /// `#RRGGBB` (opaque) or `#AARRGGBB`; [name] says which colour, for the
  /// [FormatException] anything else throws.
  static Color parseColor(Object? value, String name) {
    if (value is! String || !_hex.hasMatch(value)) {
      throw FormatException('"$name" must be a colour, #RRGGBB or #AARRGGBB', value);
    }
    final hex = int.parse(value.substring(1), radix: 16);
    return Color(value.length == 7 ? 0xFF000000 | hex : hex);
  }

  /// `#RRGGBB`, or `#AARRGGBB` for one that is not opaque.
  static String formatColor(Color color) {
    final argb = color.toARGB32();
    final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    return argb >>> 24 == 0xFF ? '#${hex.substring(2)}' : '#$hex';
  }

  @override
  HanashiPalette copyWith({Brightness? brightness, Map<PaletteSlot, Color>? colors, List<Color>? avatarColors}) =>
      HanashiPalette(
        brightness: brightness ?? this.brightness,
        colors: {..._colors, ...?colors},
        avatarColors: avatarColors ?? this.avatarColors,
      );

  @override
  HanashiPalette lerp(HanashiPalette? other, double t) {
    if (other == null) return this;
    return HanashiPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      colors: {for (final slot in PaletteSlot.values) slot: Color.lerp(this[slot], other[slot], t)!},
      // Themes may have more or fewer: those change halfway.
      avatarColors: avatarColors.length == other.avatarColors.length
          ? [for (final (i, color) in avatarColors.indexed) Color.lerp(color, other.avatarColors[i], t)!]
          : (t < 0.5 ? avatarColors : other.avatarColors),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! HanashiPalette || other.brightness != brightness) return false;
    if (other.avatarColors.length != avatarColors.length) return false;
    for (var i = 0; i < avatarColors.length; i++) {
      if (other.avatarColors[i] != avatarColors[i]) return false;
    }
    return PaletteSlot.values.every((slot) => other[slot] == this[slot]);
  }

  @override
  int get hashCode => Object.hash(
    brightness,
    Object.hashAll([for (final slot in PaletteSlot.values) this[slot]]),
    Object.hashAll(avatarColors),
  );
}

/// The palette of the current theme: `context.palette.textMuted`, say.
extension HanashiPaletteOf on BuildContext {
  HanashiPalette get palette => Theme.of(this).extension<HanashiPalette>() ?? HanashiPalette.light;
}

/// The app's own name: what it is built and installed as, and what it calls
/// itself unless the theme shown names it otherwise (see [HanashiBranding]).
const appTitle = 'Hanashi';

/// What a theme brands the app with besides its colours: the name the app
/// goes by, and the mark and the drawn name at the start of the title bar.
@immutable
class HanashiBranding extends ThemeExtension<HanashiBranding> {
  const HanashiBranding({this.appName = appTitle, this.logo, this.wordmark});

  static const none = HanashiBranding();

  /// The name the app goes by: the title bar writes it unless there is a
  /// [wordmark].
  final String appName;

  /// Drawn as tall as the title bar's text, in front of the name.
  final ImageProvider? logo;

  /// The app's name, drawn: in place of [appName].
  final ImageProvider? wordmark;

  @override
  HanashiBranding copyWith({String? appName, ImageProvider? logo, ImageProvider? wordmark}) =>
      HanashiBranding(appName: appName ?? this.appName, logo: logo ?? this.logo, wordmark: wordmark ?? this.wordmark);

  /// Names and pictures do not blend: the new ones show half way.
  @override
  HanashiBranding lerp(HanashiBranding? other, double t) => other == null || t < 0.5 ? this : other;

  @override
  bool operator ==(Object other) =>
      other is HanashiBranding && other.appName == appName && other.logo == logo && other.wordmark == wordmark;

  @override
  int get hashCode => Object.hash(appName, logo, wordmark);
}

/// The branding of the current theme (see [HanashiBranding]).
extension HanashiBrandingOf on BuildContext {
  HanashiBranding get branding => Theme.of(this).extension<HanashiBranding>() ?? HanashiBranding.none;

  /// The name the app goes by in the theme shown.
  String get appName => branding.appName;
}

/// Font fallback for text that is only emoji (reactions, and the emoji in
/// what people write: see emojiStyle): Noto Color Emoji where the platform
/// has it (and in tests), else the platform's own emoji.
/// Never for other text: that font also has digits and a space, which would
/// come out emoji-wide wherever the main font is missing.
const emojiOnlyFallback = ['Noto Color Emoji'];

/// The app's theme, of [palette]'s colours (light or dark, as it is) and
/// [branding]; widgets read those with `context.palette` and
/// `context.branding`.
ThemeData buildHanashiTheme([
  HanashiPalette palette = HanashiPalette.light,
  HanashiBranding branding = HanashiBranding.none,
]) {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      // Dialogs, menus and controls take their tones from it: in dark mode
      // from the frame around the chats, as the header's colour would tint
      // them all.
      seedColor: palette.brightness == Brightness.dark ? palette.rail : palette.header,
      brightness: palette.brightness,
      primary: palette.replyAccent,
      surface: palette.chatBackground,
    ),
    scaffoldBackgroundColor: palette.listBackground,
    dividerColor: palette.divider,
    extensions: [palette, branding],
  );
  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: BorderSide(color: color, width: width),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: palette.textPrimary, displayColor: palette.textPrimary),
    dividerTheme: DividerThemeData(color: palette.divider, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border(palette.fieldBorder),
      enabledBorder: border(palette.fieldBorder),
      focusedBorder: border(palette.replyAccent, 1.5),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
