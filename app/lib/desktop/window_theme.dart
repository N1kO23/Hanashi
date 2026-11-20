import 'dart:io';

import 'package:nativeapi/nativeapi.dart' show Application;

import '../data/themes/app_theme.dart';
import '../data/themes/builtin_themes.dart';
import '../diagnostics/app_log.dart';
import '../ui/window/window_controls.dart';

const _log = Log('window');

/// The window's title, and the app's icon in the taskbar or the dock, as
/// [theme] names and draws the app. What the system's menus and launchers
/// list stays the app's own (see `ThemeLauncher` for a phone's home screen).
void showThemeInWindow(AppTheme theme) {
  final window = appWindow;
  if (window == null) return;
  window.title = theme.shownName;
  final icon = theme.assets.appIcon ?? defaultTheme.assets.appIcon!;
  final path = switch (icon) {
    AssetSource(:final asset) => bundledAssetPath(asset),
    FileSource(:final path) => path,
  };
  try {
    if (!Application.instance.setIcon(path)) _log.info('The system took no icon from $path');
  } on Object catch (e) {
    _log.info('Could not change the app icon: $e');
  }
}

/// Where a desktop build keeps [asset], one of the app's assets, as a file.
String bundledAssetPath(String asset) {
  final executable = File(Platform.resolvedExecutable).parent.path;
  // macOS keeps them in the app bundle's framework, beside the executable's
  // folder.
  if (Platform.isMacOS) {
    return '${File(executable).parent.path}/Frameworks/App.framework/Resources/flutter_assets/$asset';
  }
  return '$executable${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets'
      '${Platform.pathSeparator}${asset.replaceAll('/', Platform.pathSeparator)}';
}
