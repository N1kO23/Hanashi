import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../data/chat_repository.dart';
import '../data/models.dart';
import '../data/remote/api_client.dart';
import '../data/themes/builtin_themes.dart';
import '../diagnostics/app_log.dart';
import '../push/call_push.dart';
import '../state/providers.dart';
import 'call_alerts.dart';
import 'call_connection.dart';
import 'call_ringer.dart';
import 'call_window.dart';
import 'livekit_connection.dart';
import 'push_to_talk.dart';
import 'voice_gate.dart';

const _log = Log('call');

/// How the calls' audio is carried: LiveKit, or a fake in tests.
final callConnectionFactoryProvider = Provider<CallConnection Function()>((ref) {
  final gate = ref.watch(voiceGateProvider);
  return () => LiveKitConnection(gate);
});

/// When this device's microphone lets the voice out, as Settings has it:
/// kept on this device, whose microphone and room it is.
final voiceGateSettingsProvider = AsyncNotifierProvider<VoiceGateSettingsController, VoiceGateSettings>(
  VoiceGateSettingsController.new,
);

class VoiceGateSettingsController extends AsyncNotifier<VoiceGateSettings> {
  static const _automatic = 'calls.voice.automatic';
  static const _threshold = 'calls.voice.threshold';
  static const _push = 'calls.voice.push';
  static const _pushKey = 'calls.voice.push_key';
  static const _pushKeyName = 'calls.voice.push_key_name';
  static const _desktopKey = 'calls.voice.desktop_key';

  @override
  Future<VoiceGateSettings> build() async {
    final database = ref.watch(databaseProvider);
    final automatic = await database.getValue(_automatic);
    final threshold = double.tryParse(await database.getValue(_threshold) ?? '');
    const usual = VoiceGateSettings();
    return VoiceGateSettings(
      automatic: automatic != 'false',
      threshold: (threshold ?? usual.threshold).clamp(VoiceGateSettings.lowest, VoiceGateSettings.highest),
      pushToTalk: await database.getValue(_push) == 'true',
      pushKey: int.tryParse(await database.getValue(_pushKey) ?? ''),
      pushKeyName: await database.getValue(_pushKeyName),
      desktopKey: await database.getValue(_desktopKey) == 'true',
    );
  }

  /// Push to talk instead of the voice going out by itself.
  Future<void> setPushToTalk(bool on) async {
    await ref.read(databaseProvider).setValue(_push, '$on');
    state = AsyncData((await future).copyWith(pushToTalk: on));
  }

  /// The push-to-talk key while Hanashi is in front ([key]'s USB HID usage),
  /// and what it is called.
  Future<void> setPushKey(int key, String name) async {
    final database = ref.read(databaseProvider);
    await database.setValue(_pushKey, '$key');
    await database.setValue(_pushKeyName, name);
    state = AsyncData((await future).copyWith(pushKey: key, pushKeyName: name));
  }

  /// The desktop has a push-to-talk key for Hanashi in every app.
  Future<void> setDesktopKey(bool set) async {
    await ref.read(databaseProvider).setValue(_desktopKey, '$set');
    state = AsyncData((await future).copyWith(desktopKey: set));
  }

  Future<void> setAutomatic(bool automatic) async {
    await ref.read(databaseProvider).setValue(_automatic, '$automatic');
    state = AsyncData((await future).copyWith(automatic: automatic));
  }

  /// [threshold] in dBFS, whole decibels.
  Future<void> setThreshold(double threshold) async {
    final value = threshold.roundToDouble().clamp(VoiceGateSettings.lowest, VoiceGateSettings.highest);
    await ref.read(databaseProvider).setValue(_threshold, '${value.round()}');
    state = AsyncData((await future).copyWith(threshold: value));
  }
}

/// This device's voice gate as the platform has it, or a fake in tests.
final platformVoiceGateProvider = Provider<VoiceGate>(
  (ref) => NativeVoiceGate.platformHasOne ? NativeVoiceGate(LiveKitConnection.testMicrophone) : const NoVoiceGate(),
);

/// This device's voice gate, with the settings it has, as they change.
final voiceGateProvider = Provider<VoiceGate>((ref) {
  final gate = ref.watch(platformVoiceGateProvider);
  ref.listen(voiceGateSettingsProvider, (_, next) {
    if (next.value case final settings?) gate.configure(settings);
  }, fireImmediately: true);
  return gate;
});

/// Whether this device has a voice gate (Settings shows it then).
final voiceGateAvailableProvider = FutureProvider<bool>((ref) => ref.watch(voiceGateProvider).available());

/// What rings while the app runs: on Android as a phone rings.
final callRingerProvider = Provider<CallRinger>((ref) {
  final CallRinger ringer = Platform.isAndroid
      ? PhoneRinger(ref.watch(callAlertsProvider), ref.watch(callWindowProvider))
      : MediaKitRinger(
          ringtone: () => (ref.read(activeThemeProvider).assets.ringtone ?? defaultTheme.assets.ringtone!).media,
        );
  ref.onDispose(ringer.stop);
  return ringer;
});

/// What the system shows of a call outside the app (Android's notifications).
final callAlertsProvider = Provider<CallAlerts>((ref) => const NoCallAlerts());

/// The window's part in a call (Android's proximity sensor).
final callWindowProvider = Provider<CallWindow>((ref) => PlatformCallWindow());

/// What the user does with call notifications outside the app (Android).
final callActionsProvider = Provider<Stream<CallAction>>((ref) => const Stream.empty());

/// Whether this is a phone: its camera pauses while the app is in the
/// background, and sharing its screen asks the system first (Android).
final callOnPhoneProvider = Provider<bool>((ref) => Platform.isAndroid || Platform.isIOS);

/// How this device shares its screen, as Settings has it: kept on this
/// device, whose upload and processor are what count.
final shareQualityProvider = AsyncNotifierProvider<ShareQualityController, ShareQuality>(ShareQualityController.new);

class ShareQualityController extends AsyncNotifier<ShareQuality> {
  static const _height = 'calls.share.height';
  static const _fps = 'calls.share.fps';
  static const _bitrate = 'calls.share.bitrate';

  /// The frame rates this device can share at: Android captures its screen
  /// 30 times a second at most.
  static List<int> get rates => [
    for (final rate in ShareQuality.rates)
      if (rate <= 30 || !Platform.isAndroid) rate,
  ];

  @override
  Future<ShareQuality> build() async {
    final database = ref.watch(databaseProvider);
    final height = await database.getValue(_height);
    final fps = int.tryParse(await database.getValue(_fps) ?? '');
    final bitrate = int.tryParse(await database.getValue(_bitrate) ?? '');
    const usual = ShareQuality();
    return ShareQuality(
      height: height == 'screen' ? null : int.tryParse(height ?? '') ?? usual.height,
      fps: fps != null && rates.contains(fps) ? fps : usual.fps,
      maxBitrate: ShareQuality.bitrates.contains(bitrate) ? bitrate : null,
    );
  }

  /// [height] null: as the screen is.
  Future<void> setHeight(int? height) async {
    await ref.read(databaseProvider).setValue(_height, height?.toString() ?? 'screen');
    final now = await future;
    state = AsyncData(ShareQuality(height: height, fps: now.fps, maxBitrate: now.maxBitrate));
  }

  Future<void> setFps(int fps) async {
    await ref.read(databaseProvider).setValue(_fps, '$fps');
    final now = await future;
    state = AsyncData(ShareQuality(height: now.height, fps: fps, maxBitrate: now.maxBitrate));
  }

  /// In bits a second; null: as the resolution and frame rate need.
  Future<void> setMaxBitrate(int? bitrate) async {
    await ref.read(databaseProvider).setValue(_bitrate, bitrate?.toString());
    final now = await future;
    state = AsyncData(ShareQuality(height: now.height, fps: now.fps, maxBitrate: bitrate));
  }
}

/// How loud this device plays each person in calls (by user), as the user
/// set them: kept on this device, whose speakers they are for. Anyone not
/// in it plays as they send.
final peerVolumesProvider = NotifierProvider<PeerVolumes, Map<String, PeerVolume>>(PeerVolumes.new);

class PeerVolumes extends Notifier<Map<String, PeerVolume>> {
  static const _key = 'calls.volumes';

  @override
  Map<String, PeerVolume> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final saved = await ref.read(databaseProvider).getValue(_key);
      if (saved == null || state.isNotEmpty) return;
      state = {
        for (final MapEntry(:key, :value) in (jsonDecode(saved) as Map<String, Object?>).entries)
          if (value case {'voice': final num voice, 'screen': final num screen})
            key: PeerVolume(voice: _fit(voice), screen: _fit(screen)),
      };
    } on Object {
      // Nothing kept (or no database, as in widget tests).
    }
  }

  static double _fit(num volume) => volume.toDouble().clamp(0, PeerVolume.most);

  /// [user] plays at [volume] from now on, kept unless not [keep]: heard at
  /// once while a slider moves, kept once it is let go.
  void set(String user, PeerVolume volume, {bool keep = true}) {
    state = {...state, user: volume}..removeWhere((_, volume) => volume == const PeerVolume());
    if (keep) unawaited(_save(state));
  }

  Future<void> _save(Map<String, PeerVolume> volumes) async {
    final json = {
      for (final MapEntry(:key, :value) in volumes.entries) key: {'voice': value.voice, 'screen': value.screen},
    };
    try {
      await ref.read(databaseProvider).setValue(_key, volumes.isEmpty ? null : jsonEncode(json));
    } on Object {
      // Kept until the app restarts.
    }
  }
}

/// Pushes about calls that reach the running app (Android).
final callPushesProvider = Provider<Stream<CallPush>>((ref) => const Stream.empty());

/// Whether the window shows over the lock screen for a call: then the app
/// shows that call and nothing else (see [CallWindow.overLockScreen]).
final overLockScreenProvider = StreamProvider<bool>((ref) => ref.watch(callWindowProvider).overLockScreen);

/// This device's call: one at a time.
final callControllerProvider = NotifierProvider<CallController, CallView>(CallController.new);

/// How far this device is with a call.
enum CallPhase {
  idle,

  /// A call of two rings this device.
  incoming,

  /// Getting into the call: its key, then its room.
  connecting,

  /// In the call (a call of two may still be ringing the other one).
  connected;

  /// Getting into a call, or in it.
  bool get inCall => this == connecting || this == connected;
}

class CallView {
  const CallView({
    this.phase = CallPhase.idle,
    this.call,
    this.room = const CallRoomState(),
    this.muted = false,
    this.deafened = false,
    this.speaker = false,
    this.camera = false,
    this.problem,
    this.notice,
    this.noticeCount = 0,
  });

  final CallPhase phase;

  /// The call, as the server last said.
  final Call? call;
  final CallRoomState room;
  final bool muted;
  final bool deafened;
  final bool speaker;

  /// The user wants the camera on (it may be paused meanwhile: see
  /// [CallRoomState.camera] for the one that is).
  final bool camera;

  /// Why the last call ended or could not start, to show for a moment.
  final String? problem;

  /// Something to tell during the call (the camera could not be used...),
  /// for a moment; [noticeCount] tells one from the next.
  final String? notice;
  final int noticeCount;

  String? get conv => call?.conv;

  /// Started as a video call.
  bool get video => call?.video ?? false;

  /// This device shares its screen.
  bool get sharing => room.sharing;

  /// Whether the shared screen's sound is on; null where it has none.
  bool? get shareSound => room.shareSound;

  /// The one app whose sound the shared screen has, or null for every app's.
  SoundApp? get shareSoundFrom => room.shareSoundFrom;

  CallView copyWith({
    CallPhase? phase,
    Call? call,
    CallRoomState? room,
    bool? muted,
    bool? deafened,
    bool? speaker,
    bool? camera,
  }) => CallView(
    phase: phase ?? this.phase,
    call: call ?? this.call,
    room: room ?? this.room,
    muted: muted ?? this.muted,
    deafened: deafened ?? this.deafened,
    speaker: speaker ?? this.speaker,
    camera: camera ?? this.camera,
    notice: notice,
    noticeCount: noticeCount,
  );

  /// This, telling [text] for a moment.
  CallView withNotice(String text) => CallView(
    phase: phase,
    call: call,
    room: room,
    muted: muted,
    deafened: deafened,
    speaker: speaker,
    camera: camera,
    problem: problem,
    notice: text,
    noticeCount: noticeCount + 1,
  );
}

class CallController extends Notifier<CallView> {
  /// How many keys LiveKit keeps, by index (`epoch % _keyRing`).
  static const _keyRing = 16;

  /// How long others have to take a new epoch's key before this device sends
  /// with it (a device a commit behind hears nothing meanwhile).
  static const keySwitchDelay = Duration(seconds: 2);

  CallConnection? _connection;
  StreamSubscription<CallKey?>? _keys;
  StreamSubscription<CallRoomState>? _room;
  Timer? _keySwitch;
  Timer? _ringTimeout;
  CallKey? _latestKey;
  int? _sendingEpoch;

  /// Counts the tries at getting into a call: one given up on (hung up,
  /// ended, signed out) goes no further.
  var _attempt = 0;

  /// Calls this device is done with (declined, ended): they ring no more.
  final _settled = <String>{};

  /// The user picked speaker or earpiece for this call.
  var _speakerChosen = false;

  /// The system shows the call going on (see [CallAlerts.showOngoing]), as
  /// this: shown again as sharing starts and stops.
  var _ongoing = false;
  ({String conv, String title, bool video})? _ongoingAs;

  /// A call whose notification opened the app, perhaps before this device
  /// knew of it: it rings once known, or with [accept] is answered.
  ({String callId, bool accept})? _opened;
  Timer? _openedTimeout;

  ChatRepository get _repo => ref.read(chatRepositoryProvider);

  /// Taken once: they are needed when this goes, when `ref` is not to be used.
  late CallRinger _ringer;
  late CallAlerts _alerts;
  late CallWindow _window;

  @override
  CallView build() {
    _ringer = ref.read(callRingerProvider);
    _alerts = ref.read(callAlertsProvider);
    _window = ref.read(callWindowProvider);
    // The screen goes dark against the ear while the earpiece plays.
    var near = false;
    listenSelf((_, next) {
      final now = next.phase.inCall && !next.speaker && !next.camera;
      if (now != near) unawaited(_window.setProximity(near = now));
    });
    ref.onDispose(() {
      if (near) unawaited(_window.setProximity(false));
    });
    // Sharing over (stopped, or by the system): the service captures no more.
    listenSelf((previous, next) {
      if (previous != null && previous.sharing && !next.sharing && next.phase.inCall && ref.read(callOnPhoneProvider)) {
        unawaited(_showOngoing(sharing: false));
      }
    });
    // A phone's camera pauses while the app is in the background (Android
    // gives an app in the background no camera), and goes on again after.
    CallConnection? pausedIn;
    final away = AppLifecycleListener(
      onStateChange: (lifecycle) {
        final connection = _connection;
        if (!ref.read(callOnPhoneProvider) || connection == null || !state.camera || !state.phase.inCall) return;
        final hidden = lifecycle == AppLifecycleState.hidden || lifecycle == AppLifecycleState.paused;
        if (hidden == identical(pausedIn, connection) || !hidden && lifecycle != AppLifecycleState.resumed) return;
        pausedIn = hidden ? connection : null;
        unawaited(
          connection.setCamera(!hidden).catchError((Object e) => _log.info('Camera ${hidden ? 'paused' : 'back'}: $e')),
        );
      },
    );
    ref.onDispose(away.dispose);
    // Over the lock screen no longer, once the call is over.
    listenSelf((previous, next) {
      if (previous != null && previous.phase != CallPhase.idle && next.phase == CallPhase.idle) {
        unawaited(_window.callOver());
      }
    });
    final actions = ref.read(callActionsProvider).listen(_act);
    ref.onDispose(actions.cancel);
    final pushes = ref.read(callPushesProvider).listen(_pushed);
    ref.onDispose(pushes.cancel);
    ref.onDispose(() => _openedTimeout?.cancel());
    ref.listen(callsProvider, (_, calls) => _callsChanged(calls.value ?? const {}));
    // Those known already, once this has a state of its own.
    scheduleMicrotask(() {
      if (ref.mounted) _callsChanged(ref.read(callsProvider).value ?? const {});
    });
    // Signed out, or another account: the call is over.
    ref.listen(chatRepositoryProvider, (previous, next) {
      if (previous != null && !identical(previous, next) && state.phase != CallPhase.idle) {
        unawaited(hangUp(problem: 'Signed out'));
      }
    });
    // Push to talk turned on or off, or its key in every app set up, during
    // a call: from now on.
    ref.listen(voiceGateSettingsProvider, (previous, next) {
      final (before, now) = (previous?.value, next.value);
      if (now == null || !state.phase.inCall) return;
      if (before?.pushToTalk != now.pushToTalk || before?.desktopKey != now.desktopKey) unawaited(_desktopKeyOn());
    });
    // Everyone as loud as the user sets them, in the call there is.
    ref.listen(peerVolumesProvider, (_, volumes) => unawaited(_connection?.setVolumes(volumes)));
    ref.onDispose(_teardown);
    return const CallView();
  }

  /// Push to talk, for the call ([_join] on).
  PushToTalkController? _push;

  /// The desktop's push-to-talk key in every app, during the call.
  DesktopKey? _desktopKey;
  StreamSubscription<bool>? _desktopHeld;

  /// The desktop's push-to-talk key in every app (Linux), where the user set
  /// one up: a session of its own for the call, closed with it, so the key
  /// is the desktop's to give elsewhere after.
  Future<void> _desktopKeyOn() async {
    _push?.hold(PushToTalkController.desktop, false);
    await _desktopKeyOff();
    final attempt = _attempt;
    final settings = ref.read(voiceGateSettingsProvider).value;
    final open = ref.read(desktopKeyProvider);
    if (open == null || settings == null || !settings.pushToTalk || !settings.desktopKey) return;
    bool over() => attempt != _attempt || !state.phase.inCall;
    try {
      final key = await open();
      if (over()) return unawaited(key.close());
      final pushKey = settings.pushKey;
      final bound = await key.bind(preferred: pushKey == null ? null : desktopKeyName(pushKey));
      if (over()) return unawaited(key.close());
      _desktopKey = key;
      _desktopHeld = key.held.listen((down) => _push?.hold(PushToTalkController.desktop, down));
      _log.info(bound == null ? 'The desktop has no push-to-talk key' : 'Push to talk with $bound, in every app');
    } on DesktopShortcutException catch (e) {
      _log.warning('No push-to-talk key in every app: $e');
    } catch (e, stack) {
      _log.warning("The desktop's push-to-talk key", e, stack);
    }
  }

  /// Touches no provider: it also runs as this one goes.
  Future<void> _desktopKeyOff() async {
    final (key, held) = (_desktopKey, _desktopHeld);
    _desktopKey = null;
    _desktopHeld = null;
    // Not listened to from now on (what cancel returns completes later).
    if (held != null) unawaited(held.cancel());
    await key?.close().catchError((Object e) => _log.debug('Closing the desktop key: $e'));
  }

  void _hold(bool held) => ref.read(callHoldProvider.notifier).hold(held);

  void _callsChanged(Map<String, Call> calls) {
    final current = state.call;
    if (current != null && state.phase != CallPhase.idle) {
      final latest = calls[current.id];
      if (latest == null || latest.version <= current.version) return;
      state = state.copyWith(call: latest);
      if (!latest.active) {
        _ended(latest);
      } else if (state.phase == CallPhase.incoming && latest.answeredAt != null) {
        _settled.add(latest.id);
        _finish(problem: 'Answered on another device');
      } else if (state.phase == CallPhase.connected && _laterDeviceOfMine(latest)) {
        unawaited(hangUp(problem: 'Continued on another device'));
      }
      return;
    }
    if (state.phase != CallPhase.idle) return;
    final me = _repo.me;
    final now = ref.read(clockProvider)();
    bool rings(Call call) =>
        call.unanswered &&
        call.startedBy != me &&
        !_settled.contains(call.id) &&
        !call.users.contains(me) &&
        (call.ringUntil?.isAfter(now) ?? false);
    final opened = _opened;
    if (opened != null) {
      final call = calls[opened.callId];
      if (call != null && !rings(call)) {
        // Too late to answer.
        _opened = null;
        _openedTimeout?.cancel();
        state = CallView(
          problem: call.active && call.answeredAt != null ? 'Answered on another device' : 'Missed call',
        );
        unawaited(_window.callOver());
      }
    }
    for (final call in calls.values) {
      if (!rings(call)) continue;
      final answered = _opened?.callId == call.id && _opened!.accept;
      if (_opened?.callId == call.id) {
        _opened = null;
        _openedTimeout?.cancel();
      }
      if (answered) {
        // Accepted from its notification: no ring first.
        state = CallView(phase: CallPhase.incoming, call: call);
        unawaited(accept());
      } else {
        _ring(call);
      }
      return;
    }
  }

  /// The app was opened from a call's notification (Android): tapped, it
  /// shows the call ringing; with [accept], it answers. The call may be
  /// unknown here still, as the app has only just started: then this waits
  /// for the server's word of it.
  void opened(String callId, {required bool accept}) {
    _log.info('Opened from the notification of call $callId${accept ? ', answering' : ''}');
    if (state.phase == CallPhase.incoming && state.call?.id == callId) {
      if (accept) unawaited(this.accept());
      return;
    }
    if (state.phase != CallPhase.idle) return;
    _opened = (callId: callId, accept: accept);
    _openedTimeout?.cancel();
    _openedTimeout = Timer(const Duration(seconds: 30), () {
      if (_opened?.callId != callId) return;
      _opened = null;
      unawaited(_window.callOver());
    });
    _callsChanged(ref.read(callsProvider).value ?? const {});
  }

  /// A push about a call while the app runs (Android): the server's word,
  /// which its connection may not bring while the app is in the background.
  void _pushed(CallPush push) {
    switch (push) {
      case CallRing(:final call):
        _repo.noteCall(call);
      case CallStop(:final callId, :final reason, :final missed):
        _settled.add(callId);
        if (state.phase == CallPhase.incoming && state.call?.id == callId) {
          _finish(
            problem: missed ? 'Missed call' : (reason == CallStop.answered ? 'Answered on another device' : null),
          );
        }
    }
  }

  String _nameOf(String user) =>
      ref.read(profilesProvider).value?[user]?.displayName ?? UserId.fallbackName(user, me: _repo.me);

  void _ring(Call call) {
    _log.info('Ringing for call ${call.id} in ${call.conv}');
    state = CallView(phase: CallPhase.incoming, call: call);
    _hold(true);
    // Names show where notifications show them.
    final named = ref.read(notificationPreferencesProvider).value?.preview ?? true;
    _ringer.start(
      RingingCall(
        callId: call.id,
        conv: call.conv,
        ringUntil: call.ringUntil!,
        caller: named ? _nameOf(call.startedBy) : null,
        video: call.video,
      ),
    );
    // Should the server's word that it stopped not come.
    _ringTimeout?.cancel();
    _ringTimeout = Timer(call.ringUntil!.difference(ref.read(clockProvider)()) + const Duration(seconds: 5), () {
      if (state.phase == CallPhase.incoming && state.call?.id == call.id) {
        _settled.add(call.id);
        _finish(problem: 'Missed call');
      }
    });
  }

  /// Whether a device of this user got into the call after this one.
  bool _laterDeviceOfMine(Call call) {
    final device = ref.read(accountProvider).value?.deviceId;
    final mine = [
      for (final p in call.participants)
        if (p.user == _repo.me) p,
    ];
    final self = mine.where((p) => p.device == device).firstOrNull;
    return self != null && mine.any((p) => p.device != device && p.joinedAt.isAfter(self.joinedAt));
  }

  /// Calls a conversation, or joins its call going on; with [video], one it
  /// starts is a video call, and the camera goes on.
  Future<void> start(String conversationId, {bool video = false}) async {
    if (state.phase != CallPhase.idle) return;
    await _join(conversationId, video: video);
  }

  /// Answers the call that rings.
  Future<void> accept() async {
    final call = state.call;
    if (state.phase != CallPhase.incoming || call == null) return;
    await _join(call.conv);
  }

  /// Says no to the call that rings.
  Future<void> decline() async {
    final call = state.call;
    if (state.phase != CallPhase.incoming || call == null) return;
    _settled.add(call.id);
    _finish();
    try {
      await _repo.declineCall(call.id);
    } on ApiException catch (e) {
      _log.warning('Declining call ${call.id}: $e');
    }
  }

  Future<void> _join(String conv, {bool video = false}) async {
    _ringer.stop();
    _ringTimeout?.cancel();
    final attempt = ++_attempt;
    bool givenUp() => attempt != _attempt;
    _speakerChosen = false;
    state = CallView(phase: CallPhase.connecting, call: state.call, muted: state.muted);
    _hold(true);
    // A test of the microphone in Settings ends: the call's goes out.
    unawaited(ref.read(voiceGateProvider).stopTest());
    _push = ref.read(pushToTalkProvider.notifier);
    unawaited(_desktopKeyOn());
    final connection = _connection = ref.read(callConnectionFactoryProvider)();
    _room = connection.states.listen((room) => state = state.copyWith(room: room));
    unawaited(connection.setVolumes(ref.read(peerVolumesProvider)));
    try {
      // The microphone first: nobody is rung for a call this device cannot
      // speak in.
      try {
        await connection.openMicrophone();
      } on CallConnectionException catch (e) {
        // The server knows nothing of this device in the call: nothing to
        // leave, and a call that rings goes on ringing the user's other
        // devices.
        if (!givenUp()) {
          if (state.call case final call?) _settled.add(call.id);
          _finish(problem: e.message);
        }
        return;
      }
      if (givenUp()) return;
      // Kept going in the background from now on.
      _ongoing = true;
      final videoCall = video || (state.call?.video ?? false);
      final shown = _ongoingAs = (
        conv: conv,
        title: ref.read(conversationProvider(conv))?.title ?? (videoCall ? 'Video call' : 'Voice call'),
        video: videoCall,
      );
      unawaited(_alerts.showOngoing(conv: shown.conv, title: shown.title, video: shown.video));
      final join = await _repo.joinCall(conv, video: video);
      if (givenUp()) {
        // Hung up while the server was asked: out of the call again.
        if (join.call.active) await _leave(join.call.id);
        return;
      }
      final known = state.call;
      state = state.copyWith(
        call: known != null && known.id == join.call.id && known.version > join.call.version ? known : join.call,
      );
      if (!join.call.active) {
        _ended(join.call);
        return;
      }
      // A call of two plays from the earpiece, like a phone call; a group's,
      // or a video call (seen, not held to the ear), from the speaker.
      if (!_speakerChosen) state = state.copyWith(speaker: !join.call.direct || join.call.video);
      await connection.setSpeaker(state.speaker);
      if (givenUp()) return;
      // Nothing goes out without the call's key.
      final first = Completer<CallKey>();
      _keys = _repo
          .watchCallKeys(conv, join.call.id)
          .listen(
            (key) => _takeKey(key, first),
            onError: (Object e) {
              if (!first.isCompleted) first.completeError(e);
            },
          );
      final key = await first.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const CallConnectionException("Could not get the call's key"),
      );
      if (givenUp()) return;
      _sendingEpoch = key.epoch;
      await connection.connect(
        url: join.url,
        token: join.token,
        key: key.key,
        keyIndex: key.epoch % _keyRing,
        muted: state.muted,
      );
      if (givenUp()) return;
      // Watched once in: a connect that fails says so by throwing.
      unawaited(
        connection.closed.then((_) {
          if (identical(_connection, connection)) unawaited(hangUp(problem: 'The call was cut off'));
        }),
      );
      state = state.copyWith(phase: CallPhase.connected);
      // A video call this device started, or answered: the camera too.
      if (video || (join.call.video && join.call.direct)) await _setCamera(true);
      // A key of a later epoch that came while connecting.
      final latest = _latestKey;
      if (latest != null && latest.epoch != key.epoch) _useKey(latest);
    } on ApiException catch (e) {
      if (!givenUp()) _finish(problem: _describe(e));
    } on CallConnectionException catch (e) {
      if (!givenUp()) await hangUp(problem: e.message);
    } catch (e, stack) {
      _log.warning('Joining a call failed', e, stack);
      if (!givenUp()) await hangUp(problem: 'Could not join the call');
    }
  }

  void _takeKey(CallKey? key, Completer<CallKey> first) {
    if (key == null) {
      // The chat's group is gone (left, or removed from it).
      if (first.isCompleted) unawaited(hangUp(problem: 'No longer in this chat'));
      return;
    }
    _latestKey = key;
    if (!first.isCompleted) {
      first.complete(key);
    } else if (_connection != null && _sendingEpoch != null) {
      _useKey(key);
    }
  }

  /// Decrypts with [key] at once; sends with it a little later, unless a
  /// newer one comes meanwhile.
  void _useKey(CallKey key) {
    final connection = _connection;
    if (connection == null || key.epoch == _sendingEpoch) return;
    final index = key.epoch % _keyRing;
    unawaited(connection.addKey(key.key, index));
    _keySwitch?.cancel();
    _keySwitch = Timer(keySwitchDelay, () {
      if (!identical(_connection, connection) || _latestKey?.epoch != key.epoch) return;
      _sendingEpoch = key.epoch;
      unawaited(connection.sendWithKey(index));
    });
  }

  Future<void> toggleMute() async {
    final muted = !state.muted;
    state = state.copyWith(muted: muted);
    await _connection?.setMuted(muted);
  }

  Future<void> toggleDeafen() async {
    final deafened = !state.deafened;
    state = state.copyWith(deafened: deafened);
    await _connection?.setDeafened(deafened);
  }

  Future<void> toggleCamera() => _setCamera(!state.camera);

  Future<void> _setCamera(bool on) async {
    final connection = _connection;
    if (connection == null || !state.phase.inCall) return;
    try {
      await connection.setCamera(on);
      if (identical(_connection, connection)) state = state.copyWith(camera: on);
    } on CallConnectionException catch (e) {
      if (identical(_connection, connection)) state = state.withNotice(e.message);
    }
  }

  /// The other camera, on phones: front or back.
  Future<void> switchCamera() async {
    try {
      await _connection?.switchCamera();
    } on CallConnectionException catch (e) {
      state = state.withNotice(e.message);
    }
  }

  /// Screens and windows to share; none where the system picks (see
  /// [CallConnection.screenSources]).
  Future<List<ScreenSource>> screenSources() async => await _connection?.screenSources() ?? const [];

  /// Shares [source], or for null what the system's own picker gives.
  ///
  /// On Android the user allows it first, each time; then the call's service
  /// captures the screen too, which Android wants running before capturing.
  Future<void> shareScreen(ScreenSource? source) async {
    final connection = _connection;
    if (connection == null || state.phase != CallPhase.connected || state.sharing) return;
    final phone = ref.read(callOnPhoneProvider);
    // The usual, should the setting not be read.
    final quality = await ref.read(shareQualityProvider.future).catchError((Object _) => const ShareQuality());
    try {
      if (!await connection.allowScreenSharing()) return;
      if (phone) {
        await _showOngoing(sharing: true);
        // The service takes its new kind in a moment.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!identical(_connection, connection)) return;
      }
      try {
        await connection.shareScreen(source, quality: quality);
      } on CallConnectionException {
        if (!phone || !identical(_connection, connection)) rethrow;
        // Once more, should the service have been slow to change.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await connection.shareScreen(source, quality: quality);
      }
    } on CallConnectionException catch (e) {
      if (!identical(_connection, connection)) return;
      state = state.withNotice(e.message);
      if (phone) unawaited(_showOngoing(sharing: false));
    }
  }

  Future<void> _showOngoing({required bool sharing}) async {
    final shown = _ongoingAs;
    if (!_ongoing || shown == null) return;
    await _alerts.showOngoing(conv: shown.conv, title: shown.title, video: shown.video, sharing: sharing);
  }

  Future<void> stopSharing() async => _connection?.stopSharing();

  /// The shared screen's sound on or off (Linux).
  Future<void> toggleShareSound() async {
    final on = state.shareSound;
    if (on != null) await _connection?.setShareSound(!on);
  }

  /// The apps whose sound the shared screen can have now.
  Future<List<SoundApp>> soundApps() async => await _connection?.soundApps() ?? const [];

  /// The shared screen's sound from [app] only, or (null) from every app.
  Future<void> shareSoundFrom(SoundApp? app) async => _connection?.shareSoundFrom(app);

  /// Plays [peer]'s shared screen's sound on this device, or not.
  Future<void> toggleScreenSound(CallPeer peer) async => _connection?.setScreenSoundOff(peer, !peer.screenSoundOff);

  /// Watches [peer]'s shared screen, or stops watching it: only those watched
  /// come to this device.
  Future<void> toggleWatching(CallPeer peer) async => _connection?.watchScreen(peer, peer.unwatchedScreen);

  Future<void> toggleSpeaker() async {
    final speaker = !state.speaker;
    _speakerChosen = true;
    state = state.copyWith(speaker: speaker);
    await _connection?.setSpeaker(speaker);
  }

  /// What the user did with a call's notification outside the app.
  void _act(CallAction action) {
    final call = state.call;
    final ours = action.callId == null || action.callId == call?.id;
    _log.info('From a notification: ${action.action} ${action.callId ?? ''}');
    switch (action.action) {
      case CallActionIds.hangUp when ours && state.phase.inCall:
        unawaited(hangUp());
      case CallActionIds.decline when ours && state.phase == CallPhase.incoming:
        unawaited(decline());
      case CallActionIds.decline when action.callId != null:
        // Not rung here (yet): it rings here no more.
        final id = action.callId!;
        _settled.add(id);
        unawaited(_repo.declineCall(id).catchError((Object e) => _log.warning('Declining call $id: $e')));
    }
  }

  /// Hangs up: out of the room, and the server told.
  Future<void> hangUp({String? problem}) async {
    final call = state.call;
    _finish(problem: problem);
    if (call == null || !call.active) return;
    _settled.add(call.id);
    await _leave(call.id);
  }

  Future<void> _leave(String callId) async {
    try {
      await _repo.leaveCall(callId);
    } on ApiException catch (e) {
      // LiveKit tells the server of a device in the room anyway, and the
      // server ends a call nobody got into.
      _log.warning('Leaving call $callId: $e');
    }
  }

  void _ended(Call call) {
    _settled.add(call.id);
    final mine = call.startedBy == _repo.me;
    _finish(
      problem: switch (call.reason) {
        CallEnd.declined when mine => 'Declined',
        CallEnd.missed when mine => 'No answer',
        CallEnd.missed || CallEnd.cancelled when !mine => 'Missed call',
        CallEnd.failed => 'The call could not start',
        _ => null,
      },
    );
  }

  /// Back to idle, out of any room.
  void _finish({String? problem}) {
    _teardown();
    _push?.releaseAll();
    state = CallView(problem: problem);
    _hold(false);
  }

  void _teardown() {
    _attempt++;
    unawaited(_desktopKeyOff());
    _ringer.stop();
    _ringTimeout?.cancel();
    _keySwitch?.cancel();
    if (_ongoing) {
      _ongoing = false;
      _ongoingAs = null;
      unawaited(_alerts.hideOngoing().onError((e, stack) => _log.warning('Hiding the call', e, stack)));
    }
    final (connection, keys, room) = (_connection, _keys, _room);
    _connection = null;
    _keys = null;
    _room = null;
    _latestKey = null;
    _sendingEpoch = null;
    // Not waited for: nothing comes of them once the fields are cleared, and
    // the call is over here whatever the room does meanwhile.
    if (keys != null) unawaited(keys.cancel());
    if (room != null) unawaited(room.cancel());
    if (connection != null) {
      unawaited(connection.disconnect().onError((e, stack) => _log.warning('Leaving the room', e, stack)));
    }
  }

  static String _describe(ApiException e) => switch (e.code) {
    'calls_unavailable' => 'Calls with people of other servers come later',
    'not_a_contact' => 'You can call contacts only',
    'calls_off' => 'This server has no calls',
    'call_ended' => 'That call has ended',
    'network' => 'Could not reach the server',
    _ => 'Could not start the call: ${e.message ?? e.code}',
  };
}
