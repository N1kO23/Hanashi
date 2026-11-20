import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../diagnostics/app_log.dart';
import '../theme/hanashi_theme.dart' show appTitle;

const _log = Log('window');

/// Desktop window actions for the in-app title bar.
abstract interface class WindowControls {
  Future<void> minimize();
  Future<void> toggleMaximize();
  Future<void> close();

  /// Hands the current pointer drag to the window manager to move the window.
  Future<void> startDragging();

  /// Makes the window fill the screen, without anything of the desktop's, or
  /// leaves that again.
  Future<void> setFullScreen(bool fullScreen);

  /// Emits the current maximized state and every change.
  Stream<bool> watchMaximized();
}

/// Null on phones (and in widget tests): no window buttons are shown.
final windowControlsProvider = Provider<WindowControls?>((ref) => null);

final windowMaximizedProvider = StreamProvider<bool>(
  (ref) => ref.watch(windowControlsProvider)?.watchMaximized().distinct() ?? Stream.value(false),
);

bool get isDesktopPlatform => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// The app's one window, once [initDesktopWindow] found it.
Window? get appWindow => _appWindow;
Window? _appWindow;

/// Hides the native title bar and returns controls for the in-app one, or
/// null on platforms without windows. With [hidden] (started at login) the
/// window stays in the tray until the user opens it: the runners do not show
/// it either then.
Future<WindowControls?> initDesktopWindow({bool hidden = false}) async {
  if (!isDesktopPlatform) return null;
  final window = _appWindow ??= WindowManager.instance.getCurrent();
  if (window == null) {
    _log.warning('No window to control');
    return null;
  }
  window.title = appTitle;
  // On Linux the runner hides the title bar itself, with a header bar it never
  // shows, which keeps GTK's own frame: its shadow and the resize edges in it.
  // nativeapi's hidden style would replace that frame with one of its own and
  // limit input to the content, so the window could not be resized by its
  // edges, and it would be sized and placed against the wrong frame.
  if (!Platform.isLinux) {
    window
      ..titleBarStyle = TitleBarStyle.hidden
      // macOS's traffic lights; Hanashi draws its own buttons.
      ..isWindowControlButtonsVisible = false;
  }
  window
    ..minimumSize = const Size(380, 560).toNative()
    ..setSize(const Size(1200, 780).toNative(), false)
    ..center();
  if (!hidden) {
    window
      ..show()
      ..focus();
  }
  return NativeWindowControls(window);
}

class NativeWindowControls implements WindowControls {
  NativeWindowControls(this.window) {
    window.addListener((event) {
      // One "restored" says that the window is neither maximized nor
      // minimized any more, so the state is read rather than kept.
      if (event is WindowMaximizedEvent || event is WindowRestoredEvent || event is WindowResizedEvent) {
        _maximized.add(window.isMaximized);
      }
    });
  }

  final Window window;
  final _maximized = StreamController<bool>.broadcast();

  @override
  Stream<bool> watchMaximized() async* {
    yield window.isMaximized;
    yield* _maximized.stream;
  }

  @override
  Future<void> minimize() async => window.minimize();

  @override
  Future<void> toggleMaximize() async => window.isMaximized ? window.unmaximize() : window.maximize();

  /// With the tray installed, this hides the window (see `DesktopTray`).
  @override
  Future<void> close() async => window.close();

  @override
  Future<void> startDragging() async => window.startDragging();

  @override
  Future<void> setFullScreen(bool fullScreen) async => window.isFullScreen = fullScreen;
}
