import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';

const _log = Log('call');

/// When the microphone's voice gate lets the voice out: once it is louder
/// than the noise around by itself ([automatic]), or than [threshold]
/// (dBFS); or, with [pushToTalk], while a key or the talk button is held.
class VoiceGateSettings {
  const VoiceGateSettings({
    this.automatic = true,
    this.threshold = -50,
    this.pushToTalk = false,
    this.pushKey,
    this.pushKeyName,
    this.desktopKey = false,
  });

  final bool automatic;
  final double threshold;
  final bool pushToTalk;

  /// The push-to-talk key while Hanashi is in front (a
  /// [PhysicalKeyboardKey]'s USB HID usage), and its name; none yet if null.
  final int? pushKey;
  final String? pushKeyName;

  /// The desktop has a push-to-talk key for Hanashi in every app too (its
  /// global shortcuts, on Linux: see `DesktopShortcut`).
  final bool desktopKey;

  /// The thresholds to choose from (dBFS): from letting nearly everything
  /// out to nothing but shouting.
  static const lowest = -80.0;
  static const highest = 0.0;

  VoiceGateSettings copyWith({
    bool? automatic,
    double? threshold,
    bool? pushToTalk,
    int? pushKey,
    String? pushKeyName,
    bool? desktopKey,
  }) => VoiceGateSettings(
    automatic: automatic ?? this.automatic,
    threshold: threshold ?? this.threshold,
    pushToTalk: pushToTalk ?? this.pushToTalk,
    pushKey: pushKey ?? this.pushKey,
    pushKeyName: pushKeyName ?? this.pushKeyName,
    desktopKey: desktopKey ?? this.desktopKey,
  );

  @override
  bool operator ==(Object other) =>
      other is VoiceGateSettings &&
      other.automatic == automatic &&
      other.threshold == threshold &&
      other.pushToTalk == pushToTalk &&
      other.pushKey == pushKey &&
      other.pushKeyName == pushKeyName &&
      other.desktopKey == desktopKey;

  @override
  int get hashCode => Object.hash(automatic, threshold, pushToTalk, pushKey, pushKeyName, desktopKey);

  @override
  String toString() => pushToTalk
      ? 'push to talk'
      : automatic
      ? 'automatic'
      : '${threshold.round()} dB';
}

/// What the meter shows: the loudest of the microphone's last moment and
/// the threshold it was held to (dBFS), and whether the voice went out.
class VoiceLevel {
  const VoiceLevel({required this.level, required this.threshold, required this.open});

  final double level;
  final double threshold;
  final bool open;
}

/// A try of the microphone outside calls, for the meter: running until
/// stopped.
abstract class MicrophoneTest {
  Future<void> stop();
}

/// The microphone's voice gate: its audio, after WebRTC's echo cancelling
/// and noise suppression, goes out only while the user speaks, and silence
/// in between (see `linux/webrtc/voice_gate_core.h`, and `VoiceGate.kt` on
/// Android). It is the device's own, for every call.
abstract class VoiceGate {
  /// Whether this device gates its voice; elsewhere it all goes out.
  Future<bool> available();

  /// For the microphone from now on, and while it is in use.
  void configure(VoiceGateSettings settings);

  /// The microphone is in use (WebRTC is set up): the gate goes on with the
  /// settings it has. False if this device has none.
  Future<bool> activate();

  /// It opens (true) and closes (false), once active.
  Stream<bool> get opens;

  /// The push-to-talk key or button is held (true), or let go.
  void push(bool held);

  /// How many frames (10 ms each) WebRTC has handed it so far, where it
  /// can say: still the same while the microphone is open means WebRTC
  /// passes it by, and everything goes out.
  Future<int?> framesGated();

  /// What the meter shows, 20 times a second, while listened to and the
  /// microphone is in use.
  Stream<VoiceLevel> get levels;

  /// Tries the microphone through the gate, for the meter, outside calls:
  /// nothing goes anywhere. Throws a [MicrophoneTestException] if the
  /// microphone cannot be used.
  Future<void> startTest();

  Future<void> stopTest();
}

class MicrophoneTestException implements Exception {
  const MicrophoneTestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where there is no gate: everything goes out, as LiveKit hears it.
class NoVoiceGate implements VoiceGate {
  const NoVoiceGate();

  @override
  Future<bool> available() async => false;

  @override
  void configure(VoiceGateSettings settings) {}

  @override
  Future<bool> activate() async => false;

  @override
  Stream<bool> get opens => const Stream.empty();

  @override
  void push(bool held) {}

  @override
  Future<int?> framesGated() async => null;

  @override
  Stream<VoiceLevel> get levels => const Stream.empty();

  @override
  Future<void> startTest() async => throw const MicrophoneTestException('This device has no voice gate');

  @override
  Future<void> stopTest() async {}
}

/// The gate in WebRTC's audio processing, through the channel
/// "hanashi/voice" (Linux: `linux/webrtc/voice_gate.h`; Android:
/// `VoiceGate.kt`), with [_testMicrophone] to run the microphone through
/// WebRTC for a test.
class NativeVoiceGate implements VoiceGate {
  NativeVoiceGate(this._testMicrophone);

  final Future<MicrophoneTest> Function() _testMicrophone;

  static const _channel = MethodChannel('hanashi/voice');

  /// Where the platform side may be: our Linux build, Android.
  static bool get platformHasOne => Platform.isLinux || Platform.isAndroid;

  var _settings = const VoiceGateSettings();
  var _active = false;
  var _heard = false;
  bool? _available;
  MicrophoneTest? _test;

  final _opens = StreamController<bool>.broadcast();
  late final _levels = StreamController<VoiceLevel>.broadcast(
    onListen: () => _meter(true),
    onCancel: () => _meter(false),
  );

  void _hear() {
    if (_heard) return;
    _heard = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'open':
          if (call.arguments is bool) _opens.add(call.arguments as bool);
        case 'level':
          final level = call.arguments as Map?;
          if (level == null) return;
          _levels.add(
            VoiceLevel(
              level: (level['level'] as num?)?.toDouble() ?? -100,
              threshold: (level['threshold'] as num?)?.toDouble() ?? -100,
              open: level['open'] == true,
            ),
          );
      }
    });
  }

  @override
  Future<bool> available() async {
    if (!platformHasOne) return false;
    if (_available != null) return _available!;
    try {
      await _channel.invokeMethod<Object?>('info');
      return _available = true;
    } on MissingPluginException {
      // A Linux build without our copy of flutter_webrtc's screen capture.
      return _available = false;
    }
  }

  @override
  void configure(VoiceGateSettings settings) {
    _settings = settings;
    if (_active) unawaited(_send());
  }

  @override
  Future<bool> activate() async {
    if (!platformHasOne) return false;
    _hear();
    _active = true;
    final on = await _send();
    if (on) {
      final info = await _channel.invokeMapMethod<String, Object?>('info').catchError((Object _) => null);
      _log.info('The voice gate is on ($_settings)${_described(info)}');
    }
    return on;
  }

  /// What WebRTC hands the gate, once it has handed any.
  static String _described(Map<String, Object?>? info) {
    final rate = info?['rate'];
    final channels = info?['channels'];
    if (rate is! int || rate <= 0) return '';
    return ': $rate Hz${channels is int && channels > 0 ? ', $channels channel(s)' : ''}';
  }

  Future<bool> _send() async {
    try {
      return await _channel.invokeMethod<bool>('configure', {
            'automatic': _settings.automatic,
            'threshold': _settings.threshold,
            'pushToTalk': _settings.pushToTalk,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _log.warning('The voice gate', e);
      return false;
    }
  }

  Future<void> _meter(bool on) async {
    _hear();
    try {
      await _channel.invokeMethod<void>('meter', {'on': on});
    } on MissingPluginException {
      // No gate: no meter.
    }
  }

  @override
  Stream<bool> get opens => _opens.stream;

  @override
  void push(bool held) {
    if (!platformHasOne) return;
    unawaited(
      _channel.invokeMethod<void>('push', {'held': held}).catchError((Object e) {
        // No gate (a Linux build without it): nothing to hold open.
      }, test: (e) => e is MissingPluginException),
    );
  }

  @override
  Future<int?> framesGated() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('info');
      return (info?['processed'] as num?)?.toInt();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Stream<VoiceLevel> get levels => _levels.stream;

  @override
  Future<void> startTest() async {
    if (_test != null) return;
    final test = await _testMicrophone();
    _test = test;
    if (!await activate()) {
      await stopTest();
      throw const MicrophoneTestException('This device has no voice gate');
    }
  }

  @override
  Future<void> stopTest() async {
    final test = _test;
    _test = null;
    await test?.stop();
  }
}
