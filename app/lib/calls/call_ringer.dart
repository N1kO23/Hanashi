import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'call_alerts.dart';
import 'call_window.dart';

/// Rings for a call while the app runs: over and over until stopped.
abstract class CallRinger {
  void start(RingingCall call);
  void stop();
}

/// Plays a ringtone with media_kit (desktops): the theme's, read as a call
/// starts ringing.
class MediaKitRinger implements CallRinger {
  MediaKitRinger({String Function()? ringtone}) : _ringtone = ringtone ?? _bundled;

  /// As media_kit opens it: `asset:///…`, or a file's path.
  final String Function() _ringtone;
  Player? _player;

  static String _bundled() => 'asset:///assets/sounds/ringtone.wav';

  @override
  void start(RingingCall call) {
    final player = _player ??= Player();
    player
      ..setPlaylistMode(PlaylistMode.single)
      ..open(Media(_ringtone()));
  }

  @override
  void stop() {
    _player?.dispose();
    _player = null;
  }
}

/// Rings as a phone does (Android): the system's ringtone, keeping to the
/// phone's silent and vibrate modes. While the app is in front it rings
/// itself, beside its own incoming call; otherwise a notification rings,
/// which shows over the lock screen and wakes the screen.
class PhoneRinger implements CallRinger {
  PhoneRinger(this._alerts, this._window, {bool Function()? inFront}) : _inFront = inFront ?? _appInFront;

  final CallAlerts _alerts;
  final CallWindow _window;
  final bool Function() _inFront;

  RingingCall? _call;

  /// How it rings now: from the app (true) or its notification (false).
  bool? _fromApp;
  AppLifecycleListener? _lifecycle;

  static bool _appInFront() => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  @override
  void start(RingingCall call) {
    if (_call?.callId != call.callId) _fromApp = null;
    _call = call;
    _lifecycle ??= AppLifecycleListener(onStateChange: (_) => changed());
    changed();
  }

  /// The app came to the front, or went from it.
  @visibleForTesting
  void changed() {
    final call = _call;
    if (call == null) return;
    final fromApp = _inFront();
    if (fromApp == _fromApp) return;
    _fromApp = fromApp;
    if (fromApp) {
      unawaited(_alerts.cancelRing(call.callId));
      unawaited(_window.setRinging(true));
    } else {
      unawaited(_window.setRinging(false));
      unawaited(_alerts.showRing(call));
    }
  }

  @override
  void stop() {
    final call = _call;
    _call = null;
    _fromApp = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    if (call == null) return;
    unawaited(_window.setRinging(false));
    unawaited(_alerts.cancelRing(call.callId));
  }
}

/// For tests: rings nobody, but says when it would.
class SilentRinger implements CallRinger {
  RingingCall? call;

  bool get ringing => call != null;

  @override
  void start(RingingCall call) => this.call = call;

  @override
  void stop() => call = null;
}
