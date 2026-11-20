import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:hanashi/calls/call_alerts.dart';
import 'package:hanashi/calls/call_connection.dart';
import 'package:hanashi/calls/call_window.dart';
import 'package:hanashi/calls/push_to_talk.dart';
import 'package:hanashi/calls/voice_gate.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'test_app.dart';

/// A video as a coloured box with its name, so a test can find it.
class FakeVideo implements CallVideo {
  FakeVideo(this.name, {this.color = const Color(0xFF6A8CAF), this.size});

  final String name;
  final Color color;

  @override
  final Size? size;

  @override
  Widget view({BoxFit fit = BoxFit.cover, bool mirror = false}) => ColoredBox(
    key: ValueKey('video-$name'),
    color: color,
    child: Center(
      child: Text('$name${mirror ? ' (mirrored)' : ''}', style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12)),
    ),
  );
}

/// A call's room that records what the app asks of it.
class FakeConnection implements CallConnection {
  final log = <String>[];
  final _states = StreamController<CallRoomState>.broadcast();
  final _closed = Completer<void>();

  /// Connecting waits for this, if set, then throws [connectError], if set.
  Completer<void>? connecting;
  Object? connectError;

  /// What disconnecting throws, if anything.
  Object? disconnectError;

  /// The microphone is open; opening it throws [microphoneError], if set.
  var microphoneOpen = false;
  Object? microphoneError;

  /// Speaker (true) or earpiece, as last set.
  bool? speaker;

  /// The camera is on; turning it on throws [cameraError], if set.
  var camera = false;
  Object? cameraError;
  var cameraSwitches = 0;

  /// What a picker would offer; null: the system picks.
  List<ScreenSource> sources = [ScreenSource(id: 'screen-1', name: 'Screen 1', window: false)];

  /// What sharing was asked for (`system` for the system's own picker);
  /// asking the system for leave answers [allowSharing].
  final shared = <String>[];
  var allowSharing = true;
  var sharing = false;

  /// Thrown by the next shares, one each.
  final shareErrors = <Object>[];

  /// A share has sound (Linux, with a server that allows it): on, from
  /// every app or [soundFrom]; the apps there are to pick from.
  var shareHasSound = false;
  bool? shareSound;
  SoundApp? soundFrom;
  var apps = <SoundApp>[];

  /// Why a share has no sound, if it has none.
  String? noSound;

  @override
  Future<void> openMicrophone() async {
    if (microphoneError case final error?) throw error;
    microphoneOpen = true;
  }

  @override
  Future<void> connect({
    required String url,
    required String token,
    required Uint8List key,
    required int keyIndex,
    bool muted = false,
  }) async {
    log.add('connect $keyIndex${muted ? ' muted' : ''}');
    await connecting?.future;
    if (connectError case final error?) throw error;
  }

  @override
  Future<void> addKey(Uint8List key, int keyIndex) async => log.add('add $keyIndex');

  @override
  Future<void> sendWithKey(int keyIndex) async => log.add('send $keyIndex');

  @override
  Future<void> setMuted(bool muted) async => log.add('muted $muted');

  @override
  Future<void> setDeafened(bool deafened) async => log.add('deafened $deafened');

  @override
  Future<void> setSpeaker(bool on) async => speaker = on;

  @override
  Future<void> setCamera(bool on) async {
    if (on && cameraError != null) throw cameraError!;
    camera = on;
    log.add('camera $on');
    _tell(camera: on ? FakeVideo('me') : null, sharing: sharing);
  }

  @override
  Future<void> switchCamera() async => cameraSwitches++;

  @override
  Future<List<ScreenSource>> screenSources() async => sources;

  @override
  Future<bool> allowScreenSharing() async => allowSharing;

  /// The quality each share was asked for.
  final qualities = <ShareQuality>[];

  @override
  Future<void> shareScreen(ScreenSource? source, {ShareQuality quality = const ShareQuality()}) async {
    qualities.add(quality);
    if (shareErrors.isNotEmpty) {
      log.add('share failed');
      throw shareErrors.removeAt(0);
    }
    shared.add(source?.id ?? 'system');
    sharing = true;
    shareSound = shareHasSound ? true : null;
    soundFrom = null;
    log.add('share ${source?.id ?? 'system'}');
    _tell(camera: last.camera, sharing: true);
  }

  @override
  Future<void> stopSharing() async {
    sharing = false;
    shareSound = null;
    log.add('share stopped');
    _tell(camera: last.camera, sharing: false);
  }

  @override
  Future<void> setShareSound(bool on) async {
    log.add('share sound $on');
    shareSound = on;
    _tell(camera: last.camera, sharing: sharing);
  }

  @override
  Future<List<SoundApp>> soundApps() async => apps;

  @override
  Future<void> shareSoundFrom(SoundApp? app) async {
    log.add('sound from ${app?.id ?? 'every app'}');
    soundFrom = app;
    _tell(camera: last.camera, sharing: sharing);
  }

  @override
  Future<void> setScreenSoundOff(CallPeer peer, bool off) async {
    log.add('screen sound of ${peer.user}/${peer.device} ${off ? 'off' : 'on'}');
    _changePeer(peer, (p) => _peer(p, screen: p.screen, unwatched: p.unwatchedScreen, soundOff: off));
  }

  @override
  Future<void> watchScreen(CallPeer peer, bool watch) async {
    log.add('${watch ? 'watch' : 'stop watching'} ${peer.user}/${peer.device}');
    _changePeer(
      peer,
      (p) => _peer(p, screen: watch ? FakeVideo('${p.user}-screen') : null, unwatched: !watch, soundOff: p.screenSoundOff),
    );
  }

  /// [p] with its shared screen as given.
  static CallPeer _peer(CallPeer p, {required CallVideo? screen, required bool unwatched, required bool soundOff}) =>
      CallPeer(
        user: p.user,
        device: p.device,
        speaking: p.speaking,
        muted: p.muted,
        deafened: p.deafened,
        encrypted: p.encrypted,
        decrypting: p.decrypting,
        camera: p.camera,
        screen: screen,
        unwatchedScreen: unwatched,
        screenSound: p.screenSound,
        screenSoundOff: soundOff,
      );

  /// The room again, with [peer] as [change] makes it.
  void _changePeer(CallPeer peer, CallPeer Function(CallPeer) change) => emit(
    CallRoomState(
      peers: [for (final p in last.peers) p.user == peer.user && p.device == peer.device ? change(p) : p],
      encrypted: last.encrypted,
      speaking: last.speaking,
      camera: last.camera,
      sharing: last.sharing,
      shareSound: last.shareSound,
      shareSoundFrom: last.shareSoundFrom,
      shareSoundMissing: last.shareSoundMissing,
      ownScreen: last.ownScreen,
    ),
  );

  /// How loud each user plays, as last set.
  var volumes = <String, PeerVolume>{};

  @override
  Future<void> setVolumes(Map<String, PeerVolume> volumes) async => this.volumes = Map.of(volumes);

  /// What the room said last.
  CallRoomState last = const CallRoomState();

  void _tell({CallVideo? camera, required bool sharing}) => emit(
    CallRoomState(
      peers: last.peers,
      encrypted: last.encrypted,
      speaking: last.speaking,
      camera: camera,
      sharing: sharing,
      shareSound: sharing ? shareSound : null,
      shareSoundFrom: sharing ? soundFrom : null,
      shareSoundMissing: sharing && !shareHasSound ? noSound : null,
      ownScreen: sharing ? FakeVideo('my screen', color: const Color(0xFF55606E)) : null,
    ),
  );

  @override
  Stream<CallRoomState> get states => _states.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    microphoneOpen = false;
    if (disconnectError case final error?) throw error;
  }

  void emit(CallRoomState state) => _states.add(last = state);

  /// The room went away by itself.
  void drop() => _closed.complete();
}

/// What the system would show of calls outside the app.
class FakeCallAlerts implements CallAlerts {
  final log = <String>[];

  /// Who the last ring was from.
  String? caller;

  @override
  Future<void> showOngoing({required String conv, required String title, bool video = false, bool sharing = false}) async =>
      log.add('ongoing $conv $title${video ? ' video' : ''}${sharing ? ' sharing' : ''}');

  @override
  Future<void> hideOngoing() async => log.add('ongoing gone');

  @override
  Future<void> showRing(RingingCall call) async {
    caller = call.caller;
    log.add('ring ${call.callId}');
  }

  @override
  Future<void> cancelRing(String callId) async => log.add('ring gone $callId');

  @override
  Future<void> showMissedCall({required String conv, String? caller}) async => log.add('missed $conv ${caller ?? '-'}');
}

/// The window as a call would have it.
class FakeCallWindow implements CallWindow {
  var proximity = false;
  var ringing = false;
  var callsOver = 0;
  final lockScreen = StreamController<bool>.broadcast();

  @override
  Future<void> setProximity(bool on) async => proximity = on;

  @override
  Future<void> setRinging(bool on) async => ringing = on;

  @override
  Stream<bool> get overLockScreen async* {
    yield false;
    yield* lockScreen.stream;
  }

  @override
  Future<void> callOver() async => callsOver++;

  @override
  Future<void> unlock() async {}

  @override
  Future<bool> canRingFullScreen() async => true;

  @override
  Future<void> allowRingingFullScreen() async {}
}

/// The demo repository, with calls as a test makes them.
class CallsRepository extends MockChatRepository {
  CallsRepository() : super(latency: Duration.zero, autoReply: false, now: testNow);

  final calls = <String, Call>{};
  final _calls = StreamController<Map<String, Call>>.broadcast();
  final keys = StreamController<CallKey?>.broadcast();
  final joined = <String>[], declined = <String>[], left = <String>[];

  /// What joining a conversation's call gives: by default a new direct call
  /// started here, ringing.
  Call Function(String conversationId)? onJoin;

  /// Joining answers once this completes, if set.
  Completer<void>? holdJoin;

  @override
  Future<bool> callsAvailable() async => true;

  /// Whether the server has video calls.
  var video = true;

  @override
  Future<bool> videoAvailable() async => video;

  /// Which joins asked for a video call.
  final joinedVideo = <bool>[];

  @override
  Stream<Map<String, Call>> watchCalls() async* {
    yield Map.unmodifiable(calls);
    yield* _calls.stream;
  }

  /// The server says this of a call.
  void tell(Call call) {
    calls[call.id] = call;
    _calls.add(Map.unmodifiable(calls));
  }

  @override
  void noteCall(Call call) {
    final known = calls[call.id];
    if (known == null || known.version < call.version) tell(call);
  }

  @override
  Future<CallJoin> joinCall(String conversationId, {bool video = false}) async {
    joined.add(conversationId);
    joinedVideo.add(video);
    await holdJoin?.future;
    final call =
        onJoin?.call(conversationId) ??
        testCall(conv: conversationId, startedBy: me, ringUntil: testNow.add(const Duration(seconds: 45)), video: video);
    tell(call);
    return CallJoin(call: call, url: 'wss://livekit.test', token: 'token');
  }

  @override
  Future<void> declineCall(String callId) async => declined.add(callId);

  @override
  Future<void> leaveCall(String callId) async => left.add(callId);

  @override
  Stream<CallKey?> watchCallKeys(String conversationId, String callId) => keys.stream;
}

final _ids = <String, String>{};

/// A call as the server would tell of it.
Call testCall({
  String id = 'a',
  required String conv,
  required String startedBy,
  bool direct = true,
  bool video = false,
  DateTime? ringUntil,
  DateTime? answeredAt,
  DateTime? endedAt,
  String? reason,
  int version = 1,
  List<CallParticipant> participants = const [],
}) => Call(
  id: _ids.putIfAbsent(id, newUlid),
  conv: conv,
  direct: direct,
  video: video,
  startedBy: startedBy,
  startedDevice: '01HZXQ8Z7K3V5M2N4P6R8T0W9Y',
  startedAt: testNow,
  ringUntil: ringUntil,
  answeredAt: answeredAt,
  endedAt: endedAt,
  reason: reason,
  version: version,
  participants: participants,
);

CallKey testKey(int epoch) => (epoch: epoch, key: Uint8List.fromList(List.filled(32, epoch)));

/// A voice gate that tells what it is told, and shows the levels a test
/// gives it.
class FakeVoiceGate implements VoiceGate {
  final configured = <VoiceGateSettings>[];
  var activated = 0;
  var testsStarted = 0;
  var testsStopped = 0;
  var testing = false;

  /// What starting a test throws, if anything.
  MicrophoneTestException? testFails;

  final _opens = StreamController<bool>.broadcast();
  final _levels = StreamController<VoiceLevel>.broadcast();

  void open(bool open) => _opens.add(open);
  void level(VoiceLevel level) => _levels.add(level);

  /// Someone listens to the meter.
  bool get metering => _levels.hasListener;

  @override
  Future<bool> available() async => true;

  @override
  void configure(VoiceGateSettings settings) => configured.add(settings);

  @override
  Future<bool> activate() async {
    activated++;
    return true;
  }

  @override
  Stream<bool> get opens => _opens.stream;

  /// What push to talk held and let go, in order.
  final pushes = <bool>[];

  @override
  void push(bool held) => pushes.add(held);

  /// Frames gated so far: a test moves it on.
  int? frames;

  @override
  Future<int?> framesGated() async => frames;

  @override
  Stream<VoiceLevel> get levels => _levels.stream;

  @override
  Future<void> startTest() async {
    if (testFails case final failure?) throw failure;
    testsStarted++;
    testing = true;
  }

  @override
  Future<void> stopTest() async {
    if (testing) testsStopped++;
    testing = false;
  }
}

/// The desktop's push-to-talk key, as a test has it: [key] once bound
/// ([answer] is what the user gives the first time), held as a test says.
class FakeDesktopKey implements DesktopKey {
  FakeDesktopKey({this.key, this.answer});

  String? key;
  String? answer;
  var opened = 0;
  var closed = 0;
  var changed = 0;
  final offered = <String?>[];
  final _held = StreamController<bool>.broadcast();

  void hold(bool down) => _held.add(down);

  /// Its key is listened for (a call has it).
  bool get listened => _held.hasListener;

  /// Opens a session of it, as the desktop would.
  Future<DesktopKey> open() async {
    opened++;
    return this;
  }

  @override
  Future<String?> bind({String? preferred}) async {
    offered.add(preferred);
    return key ??= answer;
  }

  @override
  Future<String?> current() async => key;

  @override
  Future<void> change() async => changed++;

  @override
  Stream<bool> get held => _held.stream;

  @override
  Future<void> close() async => closed++;
}
