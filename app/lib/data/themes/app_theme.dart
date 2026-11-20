import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../ui/theme/hanashi_theme.dart';

/// A file of a theme: bundled with the app (an asset), or installed on this
/// device (a file).
@immutable
sealed class ThemeSource {
  const ThemeSource();

  /// As a picture.
  ImageProvider get image;

  /// As media_kit plays it: `asset:///…`, or the file's path.
  String get media;
}

/// A file bundled with the app.
final class AssetSource extends ThemeSource {
  const AssetSource(this.asset);

  final String asset;

  @override
  ImageProvider get image => AssetImage(asset);

  @override
  String get media => 'asset:///$asset';

  @override
  bool operator ==(Object other) => other is AssetSource && other.asset == asset;

  @override
  int get hashCode => asset.hashCode;
}

/// A file on this device, of an installed theme.
final class FileSource extends ThemeSource {
  const FileSource(this.path);

  final String path;

  @override
  ImageProvider get image => FileImage(File(path));

  @override
  String get media => path;

  @override
  bool operator ==(Object other) => other is FileSource && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// What a theme brings besides its colours; each is optional.
@immutable
class ThemeAssets {
  const ThemeAssets({this.logo, this.wordmark, this.appIcon, this.messageSound, this.ringtone});

  /// At the start of the title bar (see [HanashiBranding]).
  final ThemeSource? logo;
  final ThemeSource? wordmark;

  /// The app's icon where it can change while the app runs: in the tray, and
  /// on Linux notifications.
  final ThemeSource? appIcon;

  /// What new messages and contact requests sound like.
  final ThemeSource? messageSound;

  /// What a call that rings sounds like (Android rings with the system's).
  final ThemeSource? ringtone;
}

/// Where a theme came from (see `ThemeLibrary`).
enum ThemeOrigin {
  /// Part of the app.
  builtIn,

  /// A file the user imported.
  imported,
}

/// A theme: a light and a dark palette, and what it brands the app with.
@immutable
class AppTheme {
  const AppTheme({
    required this.id,
    required this.title,
    this.author,
    this.appName,
    this.version,
    required this.light,
    required this.dark,
    this.assets = const ThemeAssets(),
    required this.origin,
  });

  final String id;
  final String title;
  final String? author;

  /// The name the app goes by while this theme shows; the app's own if null
  /// (see [shownName]).
  final String? appName;

  /// What the app calls itself while this theme shows.
  String get shownName => appName ?? appTitle;
  final int? version;

  /// The palettes for light and dark mode (one theme may have the same in
  /// both).
  final HanashiPalette light;
  final HanashiPalette dark;

  final ThemeAssets assets;
  final ThemeOrigin origin;

  HanashiBranding get branding =>
      HanashiBranding(appName: shownName, logo: assets.logo?.image, wordmark: assets.wordmark?.image);
}

/// [theme] as Flutter's themes, for light and dark mode.
({ThemeData light, ThemeData dark}) themeDataOf(AppTheme theme) {
  final branding = theme.branding;
  return (light: buildHanashiTheme(theme.light, branding), dark: buildHanashiTheme(theme.dark, branding));
}
