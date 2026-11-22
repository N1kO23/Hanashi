import 'dart:io';

import 'package:tray_manager/tray_manager.dart'
    show
        ContextMenuTrigger,
        ImageAsset,
        Menu,
        MenuItem,
        MenuItemClickedEvent,
        MenuItemType,
        TrayIcon,
        TrayIconClickedEvent;
import 'package:tray_manager/tray_manager.dart' as native show Image;
import 'package:window_manager/window_manager.dart';

import '../data/themes/app_theme.dart';
import '../data/themes/builtin_themes.dart';
import '../ui/window/window_controls.dart';

/// Keeps the desktop app running in the system tray, so messages and
/// notifications keep coming: closing the window only hides it. Clicking the
/// tray icon brings it back (on Linux the panel opens the menu instead); its
/// menu quits for real. Its icon is the theme's (see [showTheme]).
class DesktopTray {
  DesktopTray._(this._icon, this._menu, this._closeListener);

  // Kept while the icon shows: a tray icon whose object is collected goes
  // away, and so would the menu's listeners.
  final TrayIcon _icon;
  final List<MenuItem> _menu;

  /// Turns closing the window into hiding it.
  final ListenerId? _closeListener;

  static DesktopTray? _installed;

  static Future<DesktopTray> install({AppTheme theme = defaultTheme}) async {
    final icon = TrayIcon.create();
    if (icon == null) throw StateError('This desktop has no system tray');
    final image = _imageOf(theme);
    if (image == null) throw StateError('The tray icon image is missing');
    icon.icon = image;
    icon.setTooltip(theme.shownName);

    MenuItem item(String label, void Function() onClick) =>
        MenuItem.createWithLabelAndType(label, MenuItemType.normal)!..addListener((event) {
          if (event is MenuItemClickedEvent) onClick();
        });
    final items = [item('Open ${theme.shownName}', showWindow), item('Quit ${theme.shownName}', _quit)];
    final menu = Menu.create()!
      ..addItem(items.first)
      ..addSeparator()
      ..addItem(items.last);
    icon
      ..setContextMenu(menu)
      ..setContextMenuTrigger(ContextMenuTrigger.rightClicked)
      ..addListener((event) {
        if (event is TrayIconClickedEvent) showWindow();
      })
      ..setVisible(true);

    final window = appWindow;
    final closeListener = window?.addListener((event) {
      if (event is WindowCloseRequestedEvent) {
        event.request.cancel();
        window.hide();
      }
    });
    return _installed = DesktopTray._(icon, items, closeListener);
  }

  /// Shows [theme]'s icon and the name the app goes by in it, if the tray
  /// is there.
  static void showTheme(AppTheme theme) {
    final tray = _installed;
    if (tray == null) return;
    if (_imageOf(theme) case final image?) tray._icon.icon = image;
    tray._icon.setTooltip(theme.shownName);
    tray._menu.first.label = 'Open ${theme.shownName}';
    tray._menu.last.label = 'Quit ${theme.shownName}';
  }

  /// [theme]'s icon as the tray draws it; Default's if it has none, or its
  /// file is unreadable.
  static native.Image? _imageOf(AppTheme theme) {
    final sources = [?theme.assets.appIcon, ?defaultTheme.assets.appIcon];
    for (final source in sources) {
      final image = switch (source) {
        AssetSource(:final asset) => ImageAsset.fromAsset(asset),
        FileSource(:final path) => native.Image.fromFile(path),
      };
      if (image != null) return image;
    }
    return null;
  }

  /// Brings the window back, e.g. for a tapped notification.
  static Future<void> showWindow() async {
    final window = appWindow;
    if (window == null) return;
    if (window.isMinimized) window.restore();
    window
      ..show()
      ..focus();
  }

  /// Takes the icon away again; closing the window then quits.
  static Future<void> uninstall() async {
    final tray = _installed;
    if (tray == null) return;
    _installed = null;
    if (tray._closeListener case final listener?) appWindow?.removeListener(listener);
    tray._icon.dispose();
    for (final item in tray._menu) {
      item.dispose();
    }
  }

  static Future<void> _quit() async {
    await uninstall();
    // Nothing keeps it open now: the last window closing ends the app.
    appWindow?.close();
    // macOS keeps apps running without windows (see AppDelegate.swift).
    if (Platform.isMacOS) exit(0);
  }
}
