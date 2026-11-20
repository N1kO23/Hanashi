import 'package:material_ui/material_ui.dart';

/// How this device shows the app: in which theme, and whether light or dark
/// (or as the system is). Kept in a file of its own, `appearance.json`, not
/// in the database: the first screens show before there is one, the push
/// engine has none open, and signing out keeps it.
@immutable
class Appearance {
  const Appearance({required this.themeId, this.mode = ThemeMode.system});

  final String themeId;
  final ThemeMode mode;

  /// From `appearance.json`; what is missing or not understood is the
  /// default, [fallbackTheme] for the theme.
  factory Appearance.fromJson(Object? json, {required String fallbackTheme}) {
    final map = json is Map ? json : const {};
    final theme = map['theme'];
    return Appearance(
      themeId: theme is String && theme.isNotEmpty ? theme : fallbackTheme,
      mode: ThemeMode.values.where((mode) => mode.name == map['mode']).firstOrNull ?? ThemeMode.system,
    );
  }

  Map<String, Object?> toJson() => {'theme': themeId, 'mode': mode.name};

  Appearance copyWith({String? themeId, ThemeMode? mode}) =>
      Appearance(themeId: themeId ?? this.themeId, mode: mode ?? this.mode);

  @override
  bool operator ==(Object other) => other is Appearance && other.themeId == themeId && other.mode == mode;

  @override
  int get hashCode => Object.hash(themeId, mode);
}
