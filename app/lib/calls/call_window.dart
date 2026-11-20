import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';

const _log = Log('call');

/// The app's window during a call, where the system has a say in it:
/// Android (`MainActivity.kt`). Elsewhere it does nothing.
abstract class CallWindow {
  /// Whether the screen goes dark while something is near it, as an ear is
  /// to the earpiece.
  Future<void> setProximity(bool on);

  /// Rings with the system's ringtone, and vibrates as the phone is set to,
  /// while the app is in front (a notification rings otherwise).
  Future<void> setRinging(bool on);

  /// Whether the window shows over the lock screen for a call (opened from
  /// one's notification while locked): then it shows that call and nothing
  /// else. The current value first.
  Stream<bool> get overLockScreen;

  /// The call is over: the window shows over the lock screen no more, and
  /// goes back behind it if it was there.
  Future<void> callOver();

  /// Asks the user to unlock, to see the app from over the lock screen.
  Future<void> unlock();

  /// Whether a call may ring full screen over the lock screen: Android 14
  /// lets the user turn that off.
  Future<bool> canRingFullScreen();

  /// Opens the system's setting for [canRingFullScreen].
  Future<void> allowRingingFullScreen();
}

class PlatformCallWindow implements CallWindow {
  PlatformCallWindow() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'overLockScreen') _overLockScreen.add(call.arguments as bool);
    });
  }

  static const _channel = MethodChannel('hanashi/call_window');
  final _overLockScreen = StreamController<bool>.broadcast();

  @override
  Future<void> setProximity(bool on) => _invoke('proximity', on);

  @override
  Future<void> setRinging(bool on) => _invoke('ringing', on);

  @override
  Stream<bool> get overLockScreen async* {
    yield await _invoke<bool>('overLockScreen') ?? false;
    yield* _overLockScreen.stream;
  }

  @override
  Future<void> callOver() => _invoke('callOver');

  @override
  Future<void> unlock() => _invoke('unlock');

  @override
  Future<bool> canRingFullScreen() async => await _invoke<bool>('canRingFullScreen') ?? true;

  @override
  Future<void> allowRingingFullScreen() => _invoke('allowRingingFullScreen');

  static Future<T?> _invoke<T>(String method, [Object? argument]) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<T>(method, argument);
    } on Object catch (e) {
      _log.warning('Call window: $method: $e');
      return null;
    }
  }
}
