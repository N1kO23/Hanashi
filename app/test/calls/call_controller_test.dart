import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/calls/call_alerts.dart';
import 'package:hanashi/calls/call_connection.dart';
import 'package:hanashi/calls/call_controller.dart';
import 'package:hanashi/calls/call_ringer.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:hanashi/push/call_push.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../support/fake_calls.dart';
import '../support/test_app.dart';

void main() {
  const conv = 'dm';
  const kumiko = 'kumiko@localhost';
  late CallsRepository repo;
  late FakeConnection connection;
  late SilentRinger ringer;
  late FakeCallAlerts alerts;
  late FakeCallWindow window;
  late StreamController<CallAction> actions;
  late StreamController<CallPush> pushes;
  late ProviderContainer container;

  /// [phone]: as on Android; with a [database] for what is kept.
  void start({bool phone = false, AppDatabase? database}) {
    repo = CallsRepository();
    connection = FakeConnection();
    ringer = SilentRinger();
    alerts = FakeCallAlerts();
    window = FakeCallWindow();
    actions = StreamController();
    pushes = StreamController();
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(repo),
        callConnectionFactoryProvider.overrideWithValue(() => connection),
        callRingerProvider.overrideWithValue(ringer),
        callAlertsProvider.overrideWithValue(alerts),
        callWindowProvider.overrideWithValue(window),
        callActionsProvider.overrideWithValue(actions.stream),
        callPushesProvider.overrideWithValue(pushes.stream),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        clockProvider.overrideWithValue(() => testNow),
        callOnPhoneProvider.overrideWithValue(phone),
        if (database != null) databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);
    container.listen(callControllerProvider, (_, _) {});
  }

  CallView view() => container.read(callControllerProvider);
  CallController controller() => container.read(callControllerProvider.notifier);
  bool held() => container.read(callHoldProvider);
  final ringUntil = testNow.add(const Duration(seconds: 45));

  testWidgets('a call made: in once its key is here; later keys taken at once, sent with a while later', (tester) async {
    start();
    await tester.pump();
    final joining = controller().start(conv);
    await tester.pump();
    expect((view().phase, repo.joined.single, held()), (CallPhase.connecting, conv, true));
    expect(connection.log, isEmpty, reason: 'nothing before the key');
    repo.keys.add(testKey(3));
    await tester.pump();
    await joining;
    expect((view().phase, connection.log.single), (CallPhase.connected, 'connect 3'));

    // The next epoch: decrypted with at once, sent with 2 s later; one that a
    // newer key takes over from in between is never sent with.
    repo.keys.add(testKey(4));
    await tester.pump();
    expect(connection.log.last, 'add 4');
    await tester.pump(const Duration(seconds: 1));
    repo.keys.add(testKey(21));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(connection.log, ['connect 3', 'add 4', 'add 5']);
    await tester.pump(const Duration(seconds: 1));
    expect(connection.log.last, 'send 5');

    await controller().toggleMute();
    await controller().toggleDeafen();
    expect(connection.log.sublist(4), ['muted true', 'deafened true']);
    expect((view().muted, view().deafened), (true, true));

    // Over when the server says so.
    repo.tell(testCall(conv: conv, startedBy: repo.me, endedAt: testNow, reason: CallEnd.ended, version: 5));
    await tester.pump();
    expect((view().phase, connection.log.last, held()), (CallPhase.idle, 'disconnect', false));
  });

  testWidgets('a call of two rings, and stops once answered here', (tester) async {
    start();
    await tester.pump();
    final ringing = testCall(id: 'ring', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    repo.tell(ringing);
    await tester.pump();
    expect((view().phase, view().call?.id, ringer.ringing, held()), (CallPhase.incoming, ringing.id, true, true));
    repo.onJoin = (_) => ringing;
    final accepting = controller().accept();
    await tester.pump();
    expect(ringer.ringing, isFalse);
    repo.keys.add(testKey(1));
    await tester.pump();
    await accepting;
    expect((view().phase, connection.log.single), (CallPhase.connected, 'connect 1'));
  });

  testWidgets('declined, a call rings no more; answered on another device, it stops ringing', (tester) async {
    start();
    await tester.pump();
    repo.tell(testCall(id: 'declined', conv: conv, startedBy: kumiko, ringUntil: ringUntil));
    await tester.pump();
    await controller().decline();
    expect((view().phase, repo.declined.length, ringer.ringing, held()), (CallPhase.idle, 1, false, false));
    repo.tell(testCall(id: 'declined', conv: conv, startedBy: kumiko, ringUntil: ringUntil, version: 2));
    await tester.pump();
    expect(view().phase, CallPhase.idle);

    repo.tell(testCall(id: 'elsewhere', conv: conv, startedBy: kumiko, ringUntil: ringUntil));
    await tester.pump();
    expect(view().phase, CallPhase.incoming);
    repo.tell(
      testCall(
        id: 'elsewhere',
        conv: conv,
        startedBy: kumiko,
        ringUntil: ringUntil,
        answeredAt: testNow,
        version: 2,
        participants: [CallParticipant(user: repo.me, device: 'laptop', joinedAt: testNow)],
      ),
    );
    await tester.pump();
    expect((view().phase, view().problem, ringer.ringing), (CallPhase.idle, 'Answered on another device', false));
  });

  testWidgets("out of the chat's group, out of the call", (tester) async {
    start();
    await tester.pump();
    final joining = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await joining;
    repo.keys.add(null);
    await tester.pump();
    expect((view().phase, view().problem, repo.left.length), (CallPhase.idle, 'No longer in this chat', 1));
  });

  testWidgets('a call nobody says ended stops ringing once its time is up; a room gone is a call cut off', (tester) async {
    start();
    await tester.pump();
    repo.tell(testCall(id: 'unanswered', conv: conv, startedBy: kumiko, ringUntil: ringUntil));
    await tester.pump();
    expect(view().phase, CallPhase.incoming);
    await tester.pump(const Duration(seconds: 51));
    expect((view().phase, view().problem, ringer.ringing), (CallPhase.idle, 'Missed call', false));

    final joining = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await joining;
    connection.drop();
    await tester.pump();
    expect((view().phase, view().problem, connection.log.last), (CallPhase.idle, 'The call was cut off', 'disconnect'));
  });

  testWidgets("a room that can't be reached: over at once, the server told, and why shown", (tester) async {
    start();
    await tester.pump();
    connection
      ..connectError = const CallConnectionException('Could not reach the call server')
      // Nor does a room that fails to go keep the call.
      ..disconnectError = StateError('stuck');
    final joining = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await joining;
    expect(
      (view().phase, view().problem, repo.left.length, held()),
      (CallPhase.idle, 'Could not reach the call server', 1, false),
    );
  });

  testWidgets('hung up while the server is asked: the call goes no further, and is left', (tester) async {
    start();
    await tester.pump();
    final asked = repo.holdJoin = Completer();
    final joining = controller().start(conv);
    await tester.pump();
    await controller().hangUp();
    expect((view().phase, held()), (CallPhase.idle, false));
    asked.complete();
    await joining;
    repo.keys.add(testKey(1));
    await tester.pump();
    expect((view().phase, repo.left.length), (CallPhase.idle, 1));
    expect(connection.log, ['disconnect'], reason: 'never connected, only the microphone closed');
  });

  testWidgets('no key in time: out of the call, saying so', (tester) async {
    start();
    await tester.pump();
    final joining = controller().start(conv);
    await tester.pump(const Duration(seconds: 16));
    await joining;
    expect((view().phase, view().problem, repo.left.length), (CallPhase.idle, "Could not get the call's key", 1));
    expect(connection.log, ['disconnect']);
  });

  testWidgets('the microphone first: refused, nobody is rung, and a call that rings goes on ringing elsewhere', (tester) async {
    start();
    await tester.pump();
    connection.microphoneError = const CallConnectionException('Hanashi may not use the microphone');
    await controller().start(conv);
    expect((view().phase, view().problem, held()), (CallPhase.idle, 'Hanashi may not use the microphone', false));
    expect([...repo.joined, ...alerts.log], isEmpty);

    final ringing = testCall(id: 'mic', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    repo.tell(ringing);
    await tester.pump();
    await controller().accept();
    expect(view().phase, CallPhase.idle);
    expect([...repo.joined, ...repo.declined, ...repo.left], isEmpty);
    repo.tell(testCall(id: 'mic', conv: conv, startedBy: kumiko, ringUntil: ringUntil, version: 2));
    await tester.pump();
    expect(view().phase, CallPhase.idle, reason: 'it rings here no more');
  });

  testWidgets('a call going on: shown outside the app once the microphone is open, earpiece for two and speaker for groups', (tester) async {
    start();
    await tester.pump();
    final joining = controller().start(conv);
    await tester.pump();
    expect(connection.microphoneOpen, isTrue);
    expect(alerts.log, ['ongoing $conv Voice call']);
    // A chat of two: the earpiece, so the screen goes dark against the ear.
    expect((view().speaker, connection.speaker, window.proximity), (false, false, true));
    repo.keys.add(testKey(1));
    await tester.pump();
    await joining;
    await controller().toggleSpeaker();
    expect((view().speaker, connection.speaker, window.proximity), (true, true, false));
    await controller().hangUp();
    expect((alerts.log.last, window.proximity, connection.microphoneOpen), ('ongoing gone', false, false));

    // A group's call: the speaker.
    connection = FakeConnection();
    repo.onJoin = (id) => testCall(id: 'group', conv: id, startedBy: repo.me, direct: false);
    final group = controller().start('group');
    await tester.pump();
    expect((view().speaker, connection.speaker, window.proximity), (true, true, false));
    repo.keys.add(testKey(1));
    await tester.pump();
    await group;
    expect(view().phase, CallPhase.connected);
  });

  testWidgets('hung up, or declined, from a notification', (tester) async {
    start();
    await tester.pump();
    final joining = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await joining;
    actions.add((action: CallActionIds.hangUp, callId: null));
    await tester.pump();
    expect((view().phase, repo.left.length, alerts.log.last), (CallPhase.idle, 1, 'ongoing gone'));

    final ringing = testCall(id: 'declined', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    repo.tell(ringing);
    await tester.pump();
    expect(view().phase, CallPhase.incoming);
    actions.add((action: CallActionIds.decline, callId: ringing.id));
    await tester.pump();
    expect((view().phase, repo.declined.single, ringer.ringing), (CallPhase.idle, ringing.id, false));

    // One that has not rung here yet rings here no more.
    final later = testCall(id: 'later', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    actions.add((action: CallActionIds.decline, callId: later.id));
    await tester.pump();
    repo.tell(later);
    await tester.pump();
    expect((view().phase, repo.declined.last), (CallPhase.idle, later.id));
  });

  testWidgets('opened from a notification before the call is known: it rings once known, or with Accept is answered', (tester) async {
    start();
    // Names as the app knows them by then.
    container.listen(profilesProvider, (_, _) {});
    await tester.pump();
    final first = testCall(id: 'opened', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    controller().opened(first.id, accept: false);
    expect(view().phase, CallPhase.idle);
    repo.tell(first);
    await tester.pump();
    expect((view().phase, ringer.call?.callId, ringer.call?.caller), (CallPhase.incoming, first.id, 'Kumiko'));
    await controller().decline();

    final second = testCall(id: 'accepted', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    controller().opened(second.id, accept: true);
    repo.onJoin = (_) => second;
    repo.tell(second);
    await tester.pump();
    expect((view().phase, repo.joined.single), (CallPhase.connecting, conv));
    repo.keys.add(testKey(1));
    await tester.pump();
    expect(view().phase, CallPhase.connected);
    await controller().hangUp();
    expect(window.callsOver, 2, reason: 'each call over leaves the lock screen');

    // One that ended meanwhile: too late, and off the lock screen.
    final gone = testCall(id: 'gone', conv: conv, startedBy: kumiko, endedAt: testNow, reason: CallEnd.cancelled);
    repo.tell(gone);
    await tester.pump();
    controller().opened(gone.id, accept: true);
    expect((view().phase, view().problem, window.callsOver), (CallPhase.idle, 'Missed call', 3));
  });

  testWidgets('pushes while the app runs: a call that rings is told as the server would, one that stops stops', (tester) async {
    start();
    await tester.pump();
    final call = testCall(id: 'pushed', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    pushes.add(CallRing(call));
    await tester.pump();
    expect((view().phase, view().call?.id), (CallPhase.incoming, call.id));
    pushes.add(CallStop(callId: call.id, conv: conv, reason: CallEnd.cancelled));
    await tester.pump();
    expect((view().phase, view().problem, ringer.ringing), (CallPhase.idle, 'Missed call', false));
    // A late push of its ring rings no more.
    pushes.add(CallRing(testCall(id: 'pushed', conv: conv, startedBy: kumiko, ringUntil: ringUntil, version: 3)));
    await tester.pump();
    expect(view().phase, CallPhase.idle);
  });

  testWidgets('a video call: the camera goes on, from the speaker; answered, the callee\'s camera too', (tester) async {
    start();
    await tester.pump();
    final calling = controller().start(conv, video: true);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    expect(repo.joinedVideo.single, isTrue);
    expect((view().video, view().camera, connection.camera, view().speaker, window.proximity), (true, true, true, true, false));
    expect(view().room.camera, isNotNull, reason: 'a picture of oneself');
    await controller().hangUp();

    // Rung with a video call, and answered: the camera goes on here too.
    connection = FakeConnection();
    final ringing = testCall(id: 'video-ring', conv: conv, startedBy: kumiko, ringUntil: ringUntil, video: true);
    repo.tell(ringing);
    await tester.pump();
    repo.onJoin = (_) => ringing;
    final answering = controller().accept();
    await tester.pump();
    repo.keys.add(testKey(2));
    await tester.pump();
    await answering;
    expect((view().phase, connection.camera, view().speaker), (CallPhase.connected, true, true));
    await controller().toggleCamera();
    expect((view().camera, connection.camera), (false, false));
    await controller().hangUp();

    // A group's call that someone started with video: the camera waits to
    // be turned on.
    connection = FakeConnection();
    repo.onJoin = (id) => testCall(id: 'group-video', conv: id, startedBy: kumiko, direct: false, video: true);
    final joining = controller().start('group');
    await tester.pump();
    repo.keys.add(testKey(3));
    await tester.pump();
    await joining;
    expect((view().phase, connection.camera), (CallPhase.connected, false));
  });

  testWidgets('a camera that cannot be used: said so, and the call goes on', (tester) async {
    start();
    await tester.pump();
    connection.cameraError = const CallConnectionException('Hanashi may not use the camera');
    final calling = controller().start(conv, video: true);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    expect((view().phase, view().camera, view().notice), (CallPhase.connected, false, 'Hanashi may not use the camera'));
    final first = view().noticeCount;
    await controller().toggleCamera();
    expect((view().notice, view().noticeCount), ('Hanashi may not use the camera', first + 1), reason: 'told again');
    await controller().switchCamera();
    expect(connection.cameraSwitches, 1);
  });

  testWidgets('sharing a screen: picked here or by the system, stopped, or ended by the system', (tester) async {
    start();
    await tester.pump();
    final calling = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    final sources = await controller().screenSources();
    await controller().shareScreen(sources.single);
    await tester.pump();
    expect((connection.shared.single, view().sharing), ('screen-1', true));
    await controller().stopSharing();
    await tester.pump();
    expect(view().sharing, isFalse);

    // The system's own picker (Wayland, Android).
    await controller().shareScreen(null);
    await tester.pump();
    expect((connection.shared.last, view().sharing), ('system', true));
    // Its "Stop sharing", or a window that closed.
    connection.emit(const CallRoomState());
    await tester.pump();
    expect(view().sharing, isFalse);

    // Android asks first; a no shares nothing.
    connection.allowSharing = false;
    await controller().shareScreen(null);
    expect(connection.shared, hasLength(2));
  });

  testWidgets("a shared screen's sound: on at first, off and on, from one app or all; another's, off here", (
    tester,
  ) async {
    start();
    await tester.pump();
    final calling = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    // Without sound (not Linux, or the server does not allow it).
    await controller().shareScreen(null);
    await tester.pump();
    expect((view().sharing, view().shareSound), (true, null));
    await controller().toggleShareSound();
    expect(connection.log, isNot(contains('share sound false')));
    await controller().stopSharing();
    await tester.pump();

    connection
      ..shareHasSound = true
      ..apps = const [SoundApp(id: 'firefox', name: 'Firefox'), SoundApp(id: 'spotify', name: 'Spotify')];
    await controller().shareScreen(null);
    await tester.pump();
    expect((view().shareSound, view().shareSoundFrom), (true, null));
    await controller().toggleShareSound();
    await tester.pump();
    expect(view().shareSound, isFalse);
    await controller().toggleShareSound();
    await tester.pump();
    expect(view().shareSound, isTrue);
    expect((await controller().soundApps()).map((a) => a.name), ['Firefox', 'Spotify']);
    await controller().shareSoundFrom(const SoundApp(id: 'spotify', name: 'Spotify'));
    await tester.pump();
    expect(view().shareSoundFrom?.name, 'Spotify');
    await controller().shareSoundFrom(null);
    await tester.pump();
    expect(view().shareSoundFrom, isNull);
    expect(connection.log.where((l) => l.contains('sound')), [
      'share sound false',
      'share sound true',
      'sound from spotify',
      'sound from every app',
    ]);
    await controller().stopSharing();
    await tester.pump();
    expect(view().shareSound, isNull);

    // Someone else's shared screen's sound, turned off here and on again.
    connection.emit(
      CallRoomState(
        encrypted: true,
        peers: [CallPeer(user: kumiko, device: 'desktop', screen: FakeVideo('screen'), screenSound: true)],
      ),
    );
    await tester.pump();
    await controller().toggleScreenSound(view().room.peers.single);
    await tester.pump();
    expect(view().room.peers.single.screenSoundOff, isTrue);
    await controller().toggleScreenSound(view().room.peers.single);
    await tester.pump();
    expect(view().room.peers.single.screenSoundOff, isFalse);
    expect(connection.log.where((l) => l.startsWith('screen sound')), [
      'screen sound of $kumiko/desktop off',
      'screen sound of $kumiko/desktop on',
    ]);
  });

  testWidgets("another's shared screen: watched only once asked, and no longer when asked", (tester) async {
    start();
    await tester.pump();
    final calling = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    connection.emit(
      const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'desktop', unwatchedScreen: true)]),
    );
    await tester.pump();
    CallPeer kumikoThere() => view().room.peers.single;
    await controller().toggleWatching(kumikoThere());
    await tester.pump();
    expect(kumikoThere().unwatchedScreen, isFalse);
    expect(kumikoThere().screen, isNotNull);
    await controller().toggleWatching(kumikoThere());
    await tester.pump();
    expect(kumikoThere().unwatchedScreen, isTrue);
    expect(kumikoThere().screen, isNull);
    expect(connection.log.where((l) => l.contains('watch')), ['watch $kumiko/desktop', 'stop watching $kumiko/desktop']);
  });

  testWidgets('each one as loud as the user sets them: at once, in the next call, and after a restart', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    start(database: database);
    await tester.pump();
    PeerVolumes volumes() => container.read(peerVolumesProvider.notifier);
    Future<Object?> kept() async => switch (await database.getValue('calls.volumes')) {
      final json? => jsonDecode(json),
      null => null,
    };
    final joining = controller().start(conv);
    await tester.pump();
    expect(connection.volumes, isEmpty, reason: 'everyone as they send');
    repo.keys.add(testKey(1));
    await tester.pump();
    await joining;

    // While a slider moves: heard at once, kept once let go.
    volumes().set(kumiko, const PeerVolume(voice: 2.5), keep: false);
    await tester.pump();
    expect(connection.volumes, {kumiko: const PeerVolume(voice: 2.5)});
    expect(await kept(), isNull);
    volumes().set(kumiko, const PeerVolume(voice: 2.5, screen: 0.5));
    await tester.pump();
    expect(connection.volumes, {kumiko: const PeerVolume(voice: 2.5, screen: 0.5)});
    expect(await kept(), {
      kumiko: {'voice': 2.5, 'screen': 0.5},
    });

    // The next call has them from the start.
    await controller().hangUp();
    connection.volumes = {};
    final again = controller().start(conv);
    await tester.pump();
    expect(connection.volumes, {kumiko: const PeerVolume(voice: 2.5, screen: 0.5)});
    repo.keys.add(testKey(1));
    await tester.pump();
    await again;

    // Kept on this device, for the app's next start; back to as she sends,
    // nothing is kept of her.
    final restarted = ProviderContainer(overrides: [databaseProvider.overrideWithValue(database)]);
    addTearDown(restarted.dispose);
    restarted.listen(peerVolumesProvider, (_, _) {});
    await tester.pump();
    expect(restarted.read(peerVolumesProvider), {kumiko: const PeerVolume(voice: 2.5, screen: 0.5)});
    restarted.read(peerVolumesProvider.notifier).set(kumiko, const PeerVolume());
    await tester.pump();
    expect(restarted.read(peerVolumesProvider), isEmpty);
    expect(await kept(), isNull);
  });

  testWidgets('a phone shares its screen: leave, then the call service for it, then sharing; once more if too soon', (tester) async {
    start(phone: true);
    await tester.pump();
    final calling = controller().start(conv);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    expect(alerts.log, ['ongoing $conv Voice call']);
    final sharing = controller().shareScreen(null);
    await tester.pump();
    // Android captures a screen only from a service that says it does so.
    expect((alerts.log.last, connection.shared.length), ('ongoing $conv Voice call sharing', 0));
    await tester.pump(const Duration(milliseconds: 400));
    await sharing;
    expect((connection.shared.single, view().sharing), ('system', true));
    await controller().stopSharing();
    await tester.pump();
    expect(alerts.log.last, 'ongoing $conv Voice call', reason: 'the service captures no more');

    // The service not ready for it yet: once more, a moment later.
    connection.shareErrors.add(const CallConnectionException('Sharing the screen failed'));
    final again = controller().shareScreen(null);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 800));
    await again;
    expect((connection.shared.join(' '), view().sharing, view().notice), ('system system', true, null));
    // The system's "Stop sharing".
    connection.emit(const CallRoomState());
    await tester.pump();
    expect((view().sharing, alerts.log.last), (false, 'ongoing $conv Voice call'));

    // Failing again: said so, and the service as it was.
    connection.shareErrors.addAll([
      const CallConnectionException('Sharing the screen failed'),
      const CallConnectionException('Sharing the screen failed'),
    ]);
    final failing = controller().shareScreen(null);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 800));
    await failing;
    await tester.pump();
    expect((view().sharing, view().notice, alerts.log.last), (false, 'Sharing the screen failed', 'ongoing $conv Voice call'));

    // No leave: nothing else.
    final told = alerts.log.length;
    connection.allowSharing = false;
    await controller().shareScreen(null);
    expect((alerts.log.length, connection.shared.length), (told, 2));
  });

  testWidgets("a phone's camera pauses while the app is away, and comes back with it", (tester) async {
    start(phone: true);
    await tester.pump();
    final calling = controller().start(conv, video: true);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await calling;
    expect(connection.camera, isTrue);
    void lifecycle(List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    lifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump();
    expect((connection.camera, view().camera), (false, true), reason: 'paused, not turned off');
    expect(connection.log.where((l) => l == 'camera false'), hasLength(1));
    lifecycle([AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    expect(connection.camera, isTrue);

    // Turned off, it stays off.
    await controller().toggleCamera();
    lifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden]);
    lifecycle([AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    expect((connection.camera, view().camera), (false, false));
  });
}
