import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kDoubleTapTimeout, kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/calls/call_connection.dart';
import 'package:hanashi/calls/call_controller.dart';
import 'package:hanashi/calls/call_ringer.dart';
import 'package:hanashi/calls/push_to_talk.dart';
import 'package:hanashi/calls/voice_gate.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/notifications/notification_center.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/calls/call_widgets.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:hanashi/ui/widgets/hideable.dart';
import 'package:hanashi/ui/window/window_controls.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../support/fake_calls.dart';
import '../support/test_app.dart';

void main() {
  setUpAll(loadRealFonts);
  const kumiko = 'kumiko@localhost';

  late CallsRepository repo;
  late FakeConnection connection;
  late SilentRinger ringer;
  late FakeCallWindow window;

  /// [phone]: as on Android.
  /// Says yes to the question before a call goes out, and lets it go.
  Future<void> sayYesToCall(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-confirm')));
    // A frame starts its going, and the next sees it gone.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openApp(
    WidgetTester tester, {
    CallsRepository? calls,
    String? chat,
    Size size = const Size(400, 860),
    bool phone = false,
    WindowControls? windowControls,
    List<Override> overrides = const [],
  }) async {
    repo = calls ?? CallsRepository();
    connection = FakeConnection();
    ringer = SilentRinger();
    window = FakeCallWindow();
    addTearDown(repo.dispose);
    await setSurfaceSize(tester, size);
    await tester.pumpWidget(
      testApp(
        repo,
        windowControls: windowControls,
        overrides: [
          callConnectionFactoryProvider.overrideWithValue(() => connection),
          callRingerProvider.overrideWithValue(ringer),
          callWindowProvider.overrideWithValue(window),
          callAlertsProvider.overrideWithValue(FakeCallAlerts()),
          callOnPhoneProvider.overrideWithValue(phone),
          ...overrides,
        ],
      ),
    );
    await tester.pumpAndSettle();
    if (chat != null) {
      await tester.tap(find.text(chat));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('no call button unless the server carries calls', (tester) async {
    await setSurfaceSize(tester, const Size(400, 860));
    final plain = testRepository();
    addTearDown(plain.dispose);
    await tester.pumpWidget(testApp(plain));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-button')), findsNothing);
  });

  testWidgets('a call made from the chat: the pill shows it, hanging up ends it', (tester) async {
    await openApp(tester, chat: 'Kumiko');
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    expect(repo.joined.single, 'dm-kumiko');
    expect(find.byKey(const Key('call-pill')), findsOneWidget);
    expect(find.text('Connecting...'), findsOneWidget);
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('Calling...'), findsOneWidget, reason: 'it rings Kumiko');
    connection.emit(
      const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', speaking: true)]),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('call-peer-$kumiko')), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-mute')));
    await tester.pump();
    expect(connection.log.last, 'muted true');
    await tester.tap(find.byKey(const Key('call-hang-up')));
    await tester.pumpAndSettle();
    expect(repo.left, hasLength(1));
    expect(find.byKey(const Key('call-pill')), findsNothing);
  });

  testWidgets('a call that rings: answered, or declined', (tester) async {
    await openApp(tester);
    final ringing = testCall(id: 'ui-ring', conv: 'dm-kumiko', startedBy: kumiko, ringUntil: testNow.add(const Duration(seconds: 45)));
    repo.tell(ringing);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('incoming-call')), findsOneWidget);
    expect(ringer.ringing, isTrue);
    await tester.tap(find.byKey(const Key('call-decline')));
    await tester.pumpAndSettle();
    expect((repo.declined.single, ringer.ringing), (ringing.id, false));
    expect(find.byKey(const Key('incoming-call')), findsNothing);
  });

  testWidgets("a group's call going on can be joined from the chat", (tester) async {
    final calls = CallsRepository();
    calls.tell(
      testCall(
        id: 'ui-group',
        conv: 'club',
        startedBy: kumiko,
        direct: false,
        participants: [CallParticipant(user: kumiko, device: 'phone', joinedAt: testNow)],
      ),
    );
    await openApp(tester, calls: calls, chat: 'Club Room');
    expect(find.text('Call in progress · 1 person'), findsOneWidget);
    calls.onJoin = (_) => calls.calls.values.single;
    await tester.tap(find.byKey(const Key('call-join')));
    await tester.pump();
    calls.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    expect(calls.joined.single, 'club');
    expect(find.byKey(const Key('call-strip')), findsNothing, reason: 'in it now');
  });

  testWidgets('what became of a call, in its chat', (tester) async {
    final calls = CallsRepository();
    Future<void> show(Call call, {required bool mine}) async {
      calls.tell(call);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(calls)],
          child: MaterialApp(
            theme: buildHanashiTheme(),
            home: Scaffold(
              body: MessageBubble(
                message: ChatMessage(
                  envelope: Envelope.call(conv: call.conv, from: mine ? calls.me : kumiko, call: call.id, now: testNow),
                ),
                isMine: mine,
                senderName: mine ? 'Sota' : 'Kumiko',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await show(testCall(id: 'missed', conv: 'dm', startedBy: kumiko, endedAt: testNow, reason: CallEnd.missed), mine: false);
    expect(find.text('Missed voice call'), findsOneWidget);
    await show(testCall(id: 'unanswered', conv: 'dm', startedBy: calls.me, endedAt: testNow, reason: CallEnd.missed), mine: true);
    expect(find.text('No answer'), findsOneWidget);
    await show(
      testCall(
        id: 'talked',
        conv: 'dm',
        startedBy: calls.me,
        answeredAt: testNow,
        endedAt: testNow.add(const Duration(minutes: 12, seconds: 10)),
        reason: CallEnd.ended,
      ),
      mine: true,
    );
    expect(find.text('12 min'), findsOneWidget);
    await show(testCall(id: 'going', conv: 'dm', startedBy: kumiko), mine: false);
    expect(find.text('Going on'), findsOneWidget);
    expect(find.byKey(ValueKey('call-record-join-${calls.calls.values.last.id}')), findsOneWidget);
    expect(callLength(const Duration(minutes: 65)), '1 h 5 min');
    expect(callTime(const Duration(hours: 1, minutes: 2, seconds: 5)), '1:02:05');
  });

  testWidgets('phone: a call ringing, and one going on', (tester) async {
    await openApp(tester, chat: 'Kumiko');
    repo.tell(
      testCall(id: 'ui-golden', conv: 'dm-naoko', startedBy: 'naoko@localhost', ringUntil: testNow.add(const Duration(seconds: 45))),
    );
    await tester.pump();
    await tester.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/phone_call_ringing.png'));

    await tester.tap(find.byKey(const Key('call-decline')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    repo.tell(
      testCall(
        conv: 'dm-kumiko',
        startedBy: repo.me,
        answeredAt: testNow,
        version: 2,
        participants: [CallParticipant(user: kumiko, device: 'phone', joinedAt: testNow)],
      ),
    );
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', speaking: true)]));
    await tester.pump();
    await tester.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/phone_call_going_on.png'));
  });

  testWidgets('over the lock screen: the call that rings and nothing else, answered from there', (tester) async {
    await openApp(tester);
    final call = testCall(
      id: 'locked',
      conv: 'dm-kumiko',
      startedBy: kumiko,
      ringUntil: testNow.add(const Duration(seconds: 45)),
    );
    window.lockScreen.add(true);
    await tester.pump();
    repo.tell(call);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('locked-call')), findsOneWidget);
    expect(find.text('Incoming voice call'), findsOneWidget);
    expect(find.text('Chats'), findsNothing, reason: 'nothing of the chats over the lock screen');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/phone_call_locked.png'));

    repo.onJoin = (_) => call;
    await tester.tap(find.byKey(const Key('locked-accept')));
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('locked-hang-up')), findsOneWidget);
    // Kumiko muted, then deafened too: on her picture, and in words. (Each
    // change: one pump takes it in, the next draws it.)
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', muted: true)]));
    await tester.pump();
    await tester.pump();
    // ignore: avoid_print
    expect(find.byKey(const ValueKey('call-peer-muted-$kumiko')), findsOneWidget);
    expect((find.text('Muted').evaluate().length, find.text('Deafened').evaluate().length), (1, 0));
    connection.emit(
      const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', muted: true, deafened: true)]),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('call-peer-deafened-$kumiko')), findsOneWidget);
    expect((find.text('Muted').evaluate().length, find.text('Deafened').evaluate().length), (1, 1));
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone')]));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('locked-peer-state')), findsNothing);
    await tester.tap(find.byKey(const Key('locked-hang-up')));
    await tester.pump();
    expect(window.callsOver, 1, reason: 'back behind the lock');
    window.lockScreen.add(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('locked-call')), findsNothing);
  });

  /// In a video call with Kumiko, on a wide window (or [size]), her camera
  /// and screen coming in.
  Future<void> videoCallWithKumiko(
    WidgetTester tester, {
    bool screen = true,
    Size size = const Size(1280, 800),
    bool phone = false,
    WindowControls? windowControls,
  }) async {
    await openApp(tester, chat: 'Kumiko', size: size, phone: phone, windowControls: windowControls);
    await tester.tap(find.byKey(const Key('video-call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    repo.tell(
      testCall(
        conv: 'dm-kumiko',
        startedBy: repo.me,
        video: true,
        answeredAt: testNow,
        version: 2,
        participants: [CallParticipant(user: kumiko, device: 'phone', joinedAt: testNow)],
      ),
    );
    connection.emit(
      CallRoomState(
        encrypted: true,
        camera: connection.last.camera,
        peers: [
          CallPeer(
            user: kumiko,
            device: 'phone',
            speaking: true,
            camera: FakeVideo('kumiko', color: const Color(0xFF8E6A9F)),
            screen: screen ? FakeVideo('kumiko-screen', color: const Color(0xFF3F6E5A)) : null,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a video call: its video in the chat, everyone in a grid, one large with a click; the window filled, and back', (
    tester,
  ) async {
    await videoCallWithKumiko(tester);
    expect((repo.joinedVideo.single, connection.camera), (true, true));
    expect(find.byKey(const Key('call-stage')), findsOneWidget);
    expect(find.byKey(const Key('call-pill')), findsNothing, reason: 'the stage is the call here');
    expect(find.byKey(const ValueKey('video-kumiko-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-kumiko')), findsOneWidget);
    expect(find.text('me (mirrored)'), findsOneWidget, reason: 'a picture of oneself, mirrored');
    final screen = find.byKey(const ValueKey('call-tile-screen $kumiko/phone'));
    final camera = find.byKey(const ValueKey('call-tile-$kumiko/phone'));
    expect(tester.getSize(screen), tester.getSize(camera), reason: 'nothing large until picked, her screen neither');
    await tester.tap(screen);
    await tester.pumpAndSettle();
    expect(tester.getSize(screen).width, greaterThan(tester.getSize(camera).width * 2));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/desktop_call_stage.png'));
    // Clicked again: everyone in the grid again.
    await tester.tap(screen);
    await tester.pumpAndSettle();
    expect(tester.getSize(screen), tester.getSize(camera));

    await tester.tap(find.byKey(const Key('stage-full')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('full-call-stage')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('full-call-stage')), findsNothing);
    expect(find.byKey(const Key('call-stage')), findsOneWidget);
    // The system's back (Android tablets) too, and no further.
    await tester.tap(find.byKey(const Key('stage-full')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect((find.byKey(const ValueKey('full-call-stage')).evaluate().length, find.byKey(const Key('call-stage')).evaluate().length), (0, 1));

    // Elsewhere in the app, the call bar again.
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();
    expect((find.byKey(const Key('call-stage')).evaluate().length, find.byKey(const Key('call-pill')).evaluate().length), (0, 1));
  });

  testWidgets('desktop: full screen from the stage or the keys, back to where it was; its controls fade', (tester) async {
    final desktop = FakeWindowControls();
    await videoCallWithKumiko(tester, windowControls: desktop);
    // Her screen made large (once a double click can no longer come).
    await tester.tap(find.byKey(const ValueKey('call-tile-screen $kumiko/phone')));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stage-full-screen')));
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'fullScreen');
    expect(find.byKey(const Key('call-stage-immersive')), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/desktop_call_full_screen.png'));
    // Esc: back to the chat.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'leaveFullScreen');
    expect((find.byKey(const ValueKey('full-call-stage')).evaluate().length, find.byKey(const Key('call-stage')).evaluate().length), (0, 1));

    // From the filled window: F11 in, Esc out, the window still filled.
    await tester.tap(find.byKey(const Key('stage-full')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'fullScreen');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'leaveFullScreen');
    expect(find.byKey(const ValueKey('full-call-stage')), findsOneWidget);

    // Over the whole window, the controls fade once the pointer is still,
    // and come back as it moves.
    Hideable controls() =>
        tester.widget(find.ancestor(of: find.byKey(const Key('stage-mute')), matching: find.byType(Hideable)).first);
    expect(controls().hidden, isFalse);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(controls().hidden, isTrue);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.moveTo(const Offset(420, 310));
    await tester.pump();
    expect(controls().hidden, isFalse);
    await mouse.removePointer();

    // The call over, out of full screen.
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stage-hang-up')));
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'leaveFullScreen');
  });

  testWidgets('desktop: a double click, or its button, makes a video full screen and large; again, back', (tester) async {
    final desktop = FakeWindowControls();
    await videoCallWithKumiko(tester, windowControls: desktop);
    final camera = find.byKey(const ValueKey('call-tile-$kumiko/phone'));
    await tester.tap(camera);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(camera);
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'fullScreen');
    // Kumiko's camera large, her screen in the strip.
    final strip = find.byKey(const Key('call-stage-strip'));
    expect(find.descendant(of: strip, matching: find.byKey(const ValueKey('call-tile-screen $kumiko/phone'))), findsOneWidget);
    expect(find.descendant(of: strip, matching: camera), findsNothing);
    await tester.tap(camera);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(camera);
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'leaveFullScreen');
    expect(find.byKey(const Key('call-stage')), findsOneWidget);

    // A single click only makes it large (once a double click can no
    // longer come).
    final screen = find.byKey(const ValueKey('call-tile-screen $kumiko/phone'));
    await tester.tap(screen);
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'leaveFullScreen');

    // Under the pointer, a video's own button.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(camera));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call-tile-full-screen-$kumiko/phone')));
    await tester.pumpAndSettle();
    expect(desktop.calls.last, 'fullScreen');
    await mouse.removePointer();
    await tester.tap(find.byKey(const Key('stage-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets("a screen share's resolution, frame rate and bitrate: chosen in Settings, used for the next share", (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openApp(tester, size: const Size(1280, 800), overrides: [databaseProvider.overrideWithValue(db)]);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final resolution = find.byKey(const Key('share-resolution'));
    await tester.scrollUntilVisible(
      resolution,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    expect(find.descendant(of: resolution, matching: find.text('1080p')), findsOneWidget, reason: 'as before');
    expect(find.descendant(of: find.byKey(const Key('share-fps')), matching: find.text('15 frames a second')), findsOneWidget);
    expect(find.textContaining('about 2.5 Mbit/s'), findsOneWidget);
    await tester.tap(resolution);
    await tester.pumpAndSettle();
    expect(find.text('1080p (now)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-resolution-1440')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-fps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-fps-30')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: resolution, matching: find.text('1440p')), findsOneWidget);
    expect(find.textContaining('about 8.8 Mbit/s'), findsOneWidget);
    expect((await db.getValue('calls.share.height'), await db.getValue('calls.share.fps')), ('1440', '30'));
    // A bitrate of one's own, rather than as they need.
    final bitrate = find.byKey(const Key('share-bitrate'));
    expect(find.descendant(of: bitrate, matching: find.text('Automatic')), findsOneWidget);
    await tester.tap(bitrate);
    await tester.pumpAndSettle();
    expect(find.text('Automatic (now)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-bitrate-20000000')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: bitrate, matching: find.text('20 Mbit/s')), findsOneWidget);
    expect(find.textContaining('up to 20 Mbit/s of your upload'), findsOneWidget);
    expect(await db.getValue('calls.share.bitrate'), '20000000');
    // Kept as the others change.
    await tester.tap(find.byKey(const Key('share-fps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-fps-60')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: bitrate, matching: find.text('20 Mbit/s')), findsOneWidget);

    // The next share goes so.
    await tester.tap(find.byIcon(Icons.sms_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection
      ..sources = []
      ..emit(CallRoomState(encrypted: true, camera: FakeVideo('me'), peers: const [CallPeer(user: kumiko, device: 'phone')]));
    await tester.pump();
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    expect(connection.qualities.single, const ShareQuality(height: 1440, fps: 60, maxBitrate: 20000000));

    // As the screen is, and the bitrate as it needs again.
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      resolution,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.tap(resolution);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-resolution-screen')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: resolution, matching: find.text('As the screen is')), findsOneWidget);
    expect(await db.getValue('calls.share.height'), 'screen');
    await tester.tap(find.byKey(const Key('share-bitrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-bitrate-auto')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('share-bitrate')), matching: find.text('Automatic')), findsOneWidget);
    expect(await db.getValue('calls.share.bitrate'), isNull);
    await tester.tap(find.byKey(const Key('call-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets('your voice: when it goes out, set in Settings, tried there with the meter', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gate = FakeVoiceGate();
    await openApp(
      tester,
      size: const Size(1280, 800),
      overrides: [databaseProvider.overrideWithValue(db), platformVoiceGateProvider.overrideWithValue(gate)],
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final automatic = find.byKey(const Key('voice-automatic'));
    final settings = find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(automatic, 200, scrollable: settings);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(automatic).value, isTrue, reason: 'automatic until set');
    expect(gate.configured.last, const VoiceGateSettings(), reason: 'the gate has the settings from the start');
    expect(gate.metering, isTrue);
    expect(find.byKey(const Key('voice-meter')), findsOneWidget);
    expect(find.byKey(const Key('voice-threshold')), findsNothing, reason: 'nothing to set while automatic');
    expect(find.textContaining('only while the bar is green'), findsOneWidget);

    // A level outside calls and tests is none of the meter's.
    gate.level(const VoiceLevel(level: -20, threshold: -45, open: true));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('voice-threshold-value'))).data, isEmpty);

    // Tried: the meter shows the microphone, and the threshold it is held to.
    await tester.ensureVisible(find.byKey(const Key('voice-test')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-test')));
    await tester.pumpAndSettle();
    expect(gate.testsStarted, 1);
    expect(find.text('Stop the test'), findsOneWidget);
    gate.level(const VoiceLevel(level: -20, threshold: -45, open: true));
    // One pump takes the level in, the next draws it.
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('voice-threshold-value'))).data, '-45 dB');

    // A threshold of its own: set by dragging, kept once let go.
    await tester.ensureVisible(automatic);
    await tester.pumpAndSettle();
    await tester.tap(automatic);
    await tester.pumpAndSettle();
    expect(await db.getValue('calls.voice.automatic'), 'false');
    expect(gate.configured.last, const VoiceGateSettings(automatic: false));
    final slider = find.byKey(const Key('voice-threshold'));
    expect(slider, findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('voice-threshold-value'))).data, '-50 dB');
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    // From the middle (-40 dB), well to the left.
    await tester.drag(slider, const Offset(-400, 0));
    await tester.pumpAndSettle();
    final kept = double.parse((await db.getValue('calls.voice.threshold'))!);
    expect(kept, lessThan(-50));
    expect(gate.configured.last, VoiceGateSettings(automatic: false, threshold: kept));
    expect(tester.widget<Text>(find.byKey(const Key('voice-threshold-value'))).data, '${kept.round()} dB');

    // A call takes the microphone over: the test ends, and the meter shows
    // the call's.
    await tester.tap(find.byIcon(Icons.sms_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    expect(gate.testsStopped, 1);
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection.emit(
      const CallRoomState(
        encrypted: true,
        peers: [CallPeer(user: kumiko, device: 'phone')],
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(automatic, 200, scrollable: settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-test')), findsNothing);
    expect(find.textContaining('your microphone in this call'), findsOneWidget);
    expect(gate.configured.last, VoiceGateSettings(automatic: false, threshold: kept), reason: 'the same for calls');
    await tester.tap(find.byKey(const Key('call-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets("your voice: a microphone that can't be tried says why", (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gate = FakeVoiceGate()..testFails = const MicrophoneTestException('Hanashi may not use the microphone');
    await openApp(
      tester,
      size: const Size(1280, 800),
      overrides: [databaseProvider.overrideWithValue(db), platformVoiceGateProvider.overrideWithValue(gate)],
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final test = find.byKey(const Key('voice-test'));
    await tester.scrollUntilVisible(
      test,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(test);
    await tester.pumpAndSettle();
    await tester.tap(test);
    await tester.pump();
    expect(find.text('Hanashi may not use the microphone'), findsOneWidget);
    expect(find.text('Test your microphone'), findsOneWidget);
  });

  testWidgets('a call asks first: Cancel calls nobody; in a group, everyone can join it', (tester) async {
    await openApp(tester, chat: 'Kumiko', size: const Size(1280, 800));
    await tester.tap(find.byKey(const Key('call-button')));
    await tester.pumpAndSettle();
    expect(find.text('Call Kumiko?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(repo.joined, isEmpty);
    expect(find.byKey(const Key('call-pill')), findsNothing);
    await tester.tap(find.byKey(const Key('video-call-button')));
    await tester.pumpAndSettle();
    expect(find.text('Video call Kumiko?'), findsOneWidget);
    // Esc is no too.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-confirm-dialog')), findsNothing);
    expect(repo.joined, isEmpty);

    // The chats are beside the chat this wide.
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-button')));
    await tester.pumpAndSettle();
    expect(find.text('Start a call in Club Room?'), findsOneWidget);
    expect(find.text('Everyone in the group can join it.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.joined, ['club']);
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('call-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets('push to talk: chosen in Settings, held with its key, the desktop\'s, or the talk button', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gate = FakeVoiceGate();
    final desktop = FakeDesktopKey(answer: 'F13');
    await openApp(
      tester,
      size: const Size(1280, 800),
      overrides: [
        databaseProvider.overrideWithValue(db),
        platformVoiceGateProvider.overrideWithValue(gate),
        desktopKeyProvider.overrideWithValue(desktop.open),
      ],
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final settings = find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first;
    final mode = find.byKey(const Key('voice-mode'));
    await tester.scrollUntilVisible(mode, 200, scrollable: settings);
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: mode, matching: find.text('Push to talk')));
    await tester.pumpAndSettle();
    expect(await db.getValue('calls.voice.push'), 'true');
    expect(gate.configured.last.pushToTalk, isTrue);
    expect(find.byKey(const Key('voice-automatic')), findsNothing, reason: 'nothing to set the sensitivity of');
    expect(find.textContaining('only while you hold the key'), findsOneWidget);

    // The key: the next one pressed.
    final key = find.byKey(const Key('push-key'));
    await tester.ensureVisible(key);
    await tester.pumpAndSettle();
    expect(find.descendant(of: key, matching: find.text('None yet: choose one')), findsOneWidget);
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('push-key-dialog')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f13, platform: 'linux', physicalKey: PhysicalKeyboardKey.f13);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('push-key-dialog')), findsNothing);
    expect(await db.getValue('calls.voice.push_key'), '${PhysicalKeyboardKey.f13.usbHidUsage}');
    expect(await db.getValue('calls.voice.push_key_name'), 'F13');
    expect(find.descendant(of: key, matching: find.text('F13')), findsOneWidget);

    // In other apps too: the desktop asks once, offered the same key.
    final everywhere = find.byKey(const Key('push-desktop'));
    await tester.ensureVisible(everywhere);
    await tester.pumpAndSettle();
    expect(find.descendant(of: everywhere, matching: find.text('In other apps too')), findsOneWidget);
    await tester.tap(everywhere);
    await tester.pumpAndSettle();
    expect(desktop.offered, ['F13']);
    expect(await db.getValue('calls.voice.desktop_key'), 'true');
    expect(find.descendant(of: everywhere, matching: find.text('In other apps: F13')), findsOneWidget);
    expect(desktop.closed, desktop.opened, reason: 'a session only while Settings asks');
    // Changed in the desktop's own settings.
    await tester.tap(everywhere);
    await tester.pumpAndSettle();
    expect(desktop.changed, 1);

    // A call: the talk button, the key, and the desktop's key all hold it.
    await tester.tap(find.byIcon(Icons.sms_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kumiko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection.emit(
      const CallRoomState(
        encrypted: true,
        peers: [CallPeer(user: kumiko, device: 'phone')],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(desktop.listened, isTrue, reason: "the desktop's key, during the call");
    final talk = find.byKey(const Key('call-talk'));
    expect(talk, findsOneWidget);
    final finger = await tester.startGesture(tester.getCenter(talk));
    await tester.pump();
    expect(gate.pushes, [true]);
    await finger.up();
    await tester.pump();
    expect(gate.pushes, [true, false]);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f13, platform: 'linux', physicalKey: PhysicalKeyboardKey.f13);
    await tester.pump();
    expect(gate.pushes.last, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f13, platform: 'linux', physicalKey: PhysicalKeyboardKey.f13);
    await tester.pump();
    expect(gate.pushes.last, isFalse);
    desktop.hold(true);
    await tester.pump();
    expect(gate.pushes.last, isTrue);
    desktop.hold(false);
    await tester.pump();
    expect(gate.pushes.last, isFalse);
    // Muted, the talk button holds nothing.
    await tester.tap(find.byKey(const Key('call-mute')));
    await tester.pump();
    await tester.pump();
    final pushed = gate.pushes.length;
    final muted = await tester.startGesture(tester.getCenter(talk));
    await tester.pump();
    await muted.up();
    expect(gate.pushes, hasLength(pushed));

    await tester.tap(find.byKey(const Key('call-hang-up')));
    await tester.pumpAndSettle();
    expect(desktop.listened, isFalse, reason: 'the key is the desktop\'s again');
    expect(desktop.closed, desktop.opened);
  });

  testWidgets("push to talk where the desktop can't keep a key: says why", (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.setValue('calls.voice.push', 'true');
    await openApp(
      tester,
      size: const Size(1280, 800),
      overrides: [
        databaseProvider.overrideWithValue(db),
        platformVoiceGateProvider.overrideWithValue(FakeVoiceGate()),
        desktopKeyProvider.overrideWithValue(
          () async => throw const DesktopShortcutException("Hanashi isn't installed with its desktop file"),
        ),
      ],
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final everywhere = find.byKey(const Key('push-desktop'));
    await tester.scrollUntilVisible(
      everywhere,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    expect(find.descendant(of: everywhere, matching: find.text('Only while Hanashi is in front')), findsOneWidget);
    expect(find.descendant(of: everywhere, matching: find.textContaining('desktop file')), findsOneWidget);
  });

  testWidgets('sharing a screen: picked from what this device lists', (tester) async {
    await videoCallWithKumiko(tester, screen: false);
    connection.sources = [
      ScreenSource(id: 'screen-1', name: 'Screen 1', window: false),
      ScreenSource(id: 'window-7', name: 'Notes', window: true),
    ];
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen-picker')), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/screen_picker.png'));
    await tester.tap(find.byKey(const ValueKey('screen-source-window-7')));
    await tester.pumpAndSettle();
    expect(connection.shared.single, 'window-7');
    // A picture of it, small (never large by itself: it may show itself).
    final mine = find.byKey(const ValueKey('call-tile-my-screen'));
    expect(find.descendant(of: mine, matching: find.byKey(const ValueKey('video-my screen'))), findsOneWidget);
    expect(find.text('Your screen'), findsOneWidget);
    expect(tester.getSize(mine).width, lessThan(400));
    // The share button, now to stop.
    expect(find.byTooltip('Stop sharing'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    expect((connection.sharing, find.byKey(const ValueKey('call-tile-my-screen')).evaluate().length), (false, 0));

    // Where the system picks (Wayland, Android), no picker of ours.
    connection.sources = [];
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    expect((connection.shared.last, find.byKey(const Key('screen-picker')).evaluate().length), ('system', 0));
  });

  testWidgets('cameras in a grid when nobody shares; voice only without the server\'s video', (tester) async {
    await videoCallWithKumiko(tester, screen: false);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/desktop_call_grid.png'));
  });

  testWidgets('no video buttons where the server has no video', (tester) async {
    final calls = CallsRepository()..video = false;
    await openApp(tester, calls: calls, chat: 'Kumiko');
    expect(find.byKey(const Key('call-button')), findsOneWidget);
    expect(find.byKey(const Key('video-call-button')), findsNothing);
  });

  testWidgets("a shared screen's sound: on or off, from all apps or one; another's, muted here", (tester) async {
    await videoCallWithKumiko(tester, screen: false);
    // The system picks what is shared (Wayland). Without sound where it
    // could have: why, dimmed.
    connection
      ..sources = []
      ..noSound = "The call server doesn't allow sharing sound yet: it needs updating";
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-share-sound')), findsNothing);
    expect(
      tester.widget<Tooltip>(find.byKey(const Key('call-share-sound-missing'))).message,
      "The call server doesn't allow sharing sound yet: it needs updating",
    );
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();

    connection
      ..shareHasSound = true
      ..apps = const [SoundApp(id: 'firefox', name: 'Firefox'), SoundApp(id: 'spotify', name: 'Spotify')];
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pumpAndSettle();
    expect(find.text('All apps'), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-share-sound')));
    await tester.pump();
    expect(connection.shareSound, isFalse);
    // Off: no choosing whose.
    expect(find.byKey(const Key('call-sound-from')), findsNothing);
    await tester.tap(find.byKey(const Key('call-share-sound')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('call-sound-from')));
    await tester.pumpAndSettle();
    expect(find.text('Firefox'), findsOneWidget);
    await tester.tap(find.text('Spotify'));
    await tester.pumpAndSettle();
    expect(connection.soundFrom?.id, 'spotify');
    expect(find.text('Spotify'), findsOneWidget, reason: 'shown as the one');
    await tester.tap(find.byKey(const Key('call-sound-from')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('call-sound-from-all')));
    await tester.pumpAndSettle();
    expect((connection.soundFrom, find.text('All apps').evaluate().length), (null, 1));

    // Kumiko's screen with its sound: muted here, and back.
    await tester.tap(find.byKey(const Key('stage-share')));
    await tester.pump();
    connection.emit(
      CallRoomState(
        encrypted: true,
        peers: [
          CallPeer(user: kumiko, device: 'phone', screen: FakeVideo('kumiko-screen'), screenSound: true),
        ],
      ),
    );
    await tester.pump();
    final speaker = find.byKey(ValueKey('call-screen-sound-screen $kumiko/phone'));
    expect(find.descendant(of: speaker, matching: find.byIcon(Icons.volume_up)), findsOneWidget);
    await tester.tap(speaker);
    await tester.pump();
    expect(find.descendant(of: speaker, matching: find.byIcon(Icons.volume_off)), findsOneWidget);
    expect(connection.log.last, 'screen sound of $kumiko/phone off');
  });

  testWidgets("a voice call's grid: opened from the call bar, in the call's chat; hidden again", (tester) async {
    await openApp(tester, chat: 'Kumiko', size: const Size(1280, 800));
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', speaking: true)]));
    await tester.pumpAndSettle();
    final stage = find.byKey(const Key('call-stage'));
    final pill = find.byKey(const Key('call-pill'));
    expect((stage.evaluate().length, pill.evaluate().length), (0, 1), reason: 'nothing to see, nothing opened');

    // From another chat: the call's chat, with everyone in the grid.
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-show')));
    await tester.pumpAndSettle();
    expect((stage.evaluate().length, pill.evaluate().length), (1, 0), reason: "in the call's chat, as only there");
    final her = find.byKey(const ValueKey('call-tile-$kumiko'));
    final me = find.byKey(const ValueKey('call-tile-me'));
    expect(tester.getSize(her), tester.getSize(me));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/desktop_call_voice_grid.png'));
    // Anyone made large, and back.
    await tester.tap(her);
    await tester.pumpAndSettle();
    expect(tester.getSize(her).width, greaterThan(tester.getSize(me).width));
    await tester.tap(her);
    await tester.pumpAndSettle();
    expect(tester.getSize(her), tester.getSize(me));

    await tester.tap(find.byKey(const Key('stage-hide')));
    await tester.pumpAndSettle();
    expect((stage.evaluate().length, pill.evaluate().length), (0, 1));
    await tester.tap(find.byKey(const Key('call-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets("phone: a voice call's view, opened from the call bar: everyone in a grid; put away, and back", (tester) async {
    await openApp(tester, chat: 'Kumiko', phone: true);
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone')]));
    await tester.pumpAndSettle();
    final view = find.byKey(const Key('phone-call-view'));
    expect(view, findsNothing);
    await tester.tap(find.byKey(const Key('call-show')));
    await tester.pumpAndSettle();
    expect(view, findsOneWidget);
    final her = find.byKey(const ValueKey('call-tile-$kumiko'));
    final me = find.byKey(const ValueKey('call-tile-me'));
    expect((her.evaluate().length, me.evaluate().length), (1, 1));
    expect(tester.getSize(her), tester.getSize(me), reason: 'a grid: nobody larger');
    expect(find.byKey(const Key('phone-call-strip')), findsNothing);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/phone_call_voice_grid.png'));

    await tester.tap(find.byKey(const Key('phone-call-minimize')));
    await tester.pumpAndSettle();
    expect((view.evaluate().length, find.byKey(const Key('call-pill')).evaluate().length), (0, 1));
    await tester.tap(find.byKey(const Key('call-show')));
    await tester.pumpAndSettle();
    expect(view, findsOneWidget);
    await tester.tap(find.byKey(const Key('stage-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets("someone's shared screen: none of it comes until watched; watching stops from its tile", (tester) async {
    await openApp(tester, chat: 'Kumiko', size: const Size(1280, 800));
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection.emit(
      const CallRoomState(
        encrypted: true,
        peers: [CallPeer(user: kumiko, device: 'phone', unwatchedScreen: true, screenSound: true)],
      ),
    );
    await tester.pumpAndSettle();
    const tile = 'screen $kumiko/phone';
    final watch = find.byKey(const ValueKey('call-watch-$tile'));
    final video = find.byKey(const ValueKey('video-$kumiko-screen'));
    final sound = find.byKey(const ValueKey('call-screen-sound-$tile'));
    expect(find.byKey(const Key('call-stage')), findsOneWidget, reason: 'a screen to watch is something to see');
    expect((watch.evaluate().length, sound.evaluate().length), (1, 0), reason: 'its sound comes only with it');

    await tester.tap(watch);
    await tester.pumpAndSettle();
    expect(connection.log.last, 'watch $kumiko/phone');
    expect((video.evaluate().length, watch.evaluate().length, sound.evaluate().length), (1, 0, 1));
    expect(
      tester.getSize(find.byKey(const ValueKey('call-tile-$tile'))).width,
      greaterThan(tester.getSize(find.byKey(const ValueKey('call-tile-me'))).width * 2),
      reason: 'watched, it shows large',
    );

    await tester.tap(find.byKey(const ValueKey('call-stop-watching-$tile')));
    await tester.pumpAndSettle();
    expect(connection.log.last, 'stop watching $kumiko/phone');
    expect((video.evaluate().length, watch.evaluate().length), (0, 1));
    await tester.tap(find.byKey(const Key('stage-hang-up')));
    await tester.pumpAndSettle();
  });

  testWidgets('how loud someone plays here, from the call bar: their voice, up to four times as loud', (tester) async {
    await openApp(tester, chat: 'Kumiko');
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone')]));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('call-pill-people')));
    await tester.pumpAndSettle();
    final voice = find.byKey(const ValueKey('call-volume-voice-$kumiko'));
    final screen = find.byKey(const ValueKey('call-volume-screen-$kumiko'));
    String shown(String what) => tester.widget<Text>(find.byKey(ValueKey('call-volume-$what-$kumiko-value'))).data!;
    expect((shown('voice'), screen.evaluate().length), ('100%', 0), reason: 'as she sends; she shares no screen');

    // All the way up: four times as loud; and down to nothing.
    await tester.drag(voice, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect((shown('voice'), connection.volumes[kumiko]), ('400%', const PeerVolume(voice: 4)));
    await tester.drag(voice, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect((shown('voice'), connection.volumes[kumiko]), ('0%', const PeerVolume(voice: 0)));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-volumes')), findsNothing);
  });

  testWidgets("someone's volume from the stage: their tile's button under the pointer, a right click or a long press", (
    tester,
  ) async {
    await videoCallWithKumiko(tester);
    final camera = find.byKey(const ValueKey('call-tile-$kumiko/phone'));
    final menu = find.byKey(const Key('call-volumes'));
    final screenSound = find.byKey(const ValueKey('call-volume-screen-$kumiko'));
    Future<void> closeMenu() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
    }

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await mouse.addPointer(location: tester.getCenter(camera));
    Future<void> rightClick(Finder on) async {
      await mouse.down(tester.getCenter(on));
      await mouse.up();
      await tester.pumpAndSettle();
    }

    await rightClick(camera);
    expect(find.descendant(of: menu, matching: find.byKey(const ValueKey('call-volume-voice-$kumiko'))), findsOneWidget);
    expect(screenSound, findsNothing, reason: 'her screen has no sound');
    // Its sound on: a slider of its own, in the menu still open.
    connection.emit(
      CallRoomState(
        encrypted: true,
        camera: connection.last.camera,
        peers: [
          CallPeer(
            user: kumiko,
            device: 'phone',
            camera: FakeVideo('kumiko'),
            screen: FakeVideo('kumiko-screen'),
            screenSound: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(screenSound, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(connection.volumes[kumiko], const PeerVolume(screen: 0));
    await closeMenu();
    await tester.longPress(find.byKey(const ValueKey('call-tile-screen $kumiko/phone')));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    await closeMenu();

    // Under the pointer, a button of its own.
    await mouse.moveTo(tester.getCenter(camera));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call-tile-volume-$kumiko/phone')));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    await closeMenu();
    // One's own tile has none.
    final mine = find.byKey(const ValueKey('call-tile-me'));
    await mouse.moveTo(tester.getCenter(mine));
    await tester.pump();
    expect(find.byKey(const ValueKey('call-tile-volume-me')), findsNothing);
    await rightClick(mine);
    expect(menu, findsNothing);
    await mouse.removePointer();
  });

  testWidgets('someone muted or deafened shows so: on the call bar, and on the stage', (tester) async {
    await openApp(tester, chat: 'Kumiko');
    await tester.tap(find.byKey(const Key('call-button')));
    await sayYesToCall(tester);
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    (int, int) badges() => (
      find.byKey(const ValueKey('call-peer-muted-$kumiko')).evaluate().length,
      find.byKey(const ValueKey('call-peer-deafened-$kumiko')).evaluate().length,
    );
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', muted: true)]));
    await tester.pump();
    await tester.pump();
    expect(badges(), (1, 0));
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', deafened: true)]));
    await tester.pump();
    await tester.pump();
    expect(badges(), (0, 1));
    // Both: both shown.
    connection.emit(
      const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone', deafened: true, muted: true)]),
    );
    await tester.pump();
    await tester.pump();
    expect(badges(), (1, 1));
    // One of two devices muted: the person is not.
    connection.emit(
      const CallRoomState(
        encrypted: true,
        peers: [
          CallPeer(user: kumiko, device: 'phone', muted: true),
          CallPeer(user: kumiko, device: 'desktop'),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(badges(), (0, 0));
    expect(find.text("Someone's audio can't be heard"), findsNothing);
    connection.emit(const CallRoomState(encrypted: true, peers: [CallPeer(user: kumiko, device: 'phone')]));
    await tester.pump();
    await tester.pump();
    expect(badges(), (0, 0));

    // On the stage, by the name.
    connection.emit(
      CallRoomState(
        encrypted: true,
        peers: [CallPeer(user: kumiko, device: 'phone', deafened: true, muted: true, camera: FakeVideo('kumiko'))],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('call-tile-deafened-$kumiko/phone')), findsOneWidget);
  });

  testWidgets('phone: a call with video fills the screen; put away for the call bar, and back from it', (tester) async {
    await videoCallWithKumiko(tester, screen: false, size: const Size(400, 860), phone: true);
    expect(find.byKey(const Key('phone-call-view')), findsOneWidget);
    expect((find.byKey(const Key('call-pill')).evaluate().length, find.byKey(const Key('call-stage')).evaluate().length), (0, 0));
    expect(find.text('me (mirrored)'), findsOneWidget, reason: 'oneself, small in a corner');
    expect(find.byKey(const Key('stage-flip')), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/phone_call_video.png'));

    // Put away: the call bar, in the call's chat too; and from it, back.
    await tester.tap(find.byKey(const Key('phone-call-minimize')));
    await tester.pumpAndSettle();
    expect((find.byKey(const Key('phone-call-view')).evaluate().length, find.byKey(const Key('call-pill')).evaluate().length), (0, 1));
    expect(find.byKey(const Key('call-stage')), findsNothing, reason: 'the chat shows no video on phones');
    await tester.tap(find.byKey(const Key('call-pill-where')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phone-call-view')), findsOneWidget);

    // The system's back puts it away, and goes no further; then out of the chat.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // (In the chat, its title bar's call button says "In the call".)
    expect((find.byKey(const Key('phone-call-view')).evaluate().length, find.byKey(const Key('call-button')).evaluate().length), (0, 1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect((find.byKey(const Key('call-button')).evaluate().length, find.byKey(const Key('call-pill')).evaluate().length), (0, 1));

    // Shared from the call bar too (Android asks first, then shares).
    connection.sources = [];
    await tester.tap(find.byKey(const Key('call-share')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(connection.shared.single, 'system');
  });

  testWidgets(
    "phone: a tap takes the controls away and back, and they go by themselves; full screen turns the phone the video's way; a shared screen zooms",
    (tester) async {
      final system = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method.startsWith('SystemChrome.')) system.add('${call.method.substring(13)} ${call.arguments}');
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await videoCallWithKumiko(tester, screen: false, size: const Size(400, 860), phone: true);
      connection.emit(
        CallRoomState(
          encrypted: true,
          camera: connection.last.camera,
          peers: [CallPeer(user: kumiko, device: 'phone', camera: FakeVideo('kumiko', size: const Size(1280, 720)))],
        ),
      );
      await tester.pump();
      Hideable controls() =>
          tester.widget(find.ancestor(of: find.byKey(const Key('stage-mute')), matching: find.byType(Hideable)).first);
      expect(controls().hidden, isFalse);

      // A tap on the video: away, with the system's bars; again: back.
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect((controls().hidden, system.last), (true, 'setEnabledSystemUIMode SystemUiMode.immersiveSticky'));
      // Away, a tap presses nothing: hanging up is not where it was.
      expect(find.byKey(const Key('stage-hang-up')).hitTestable(), findsNothing);
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect(controls().hidden, isFalse);
      expect(system.last, 'setEnabledSystemUIOverlays [SystemUiOverlay.top, SystemUiOverlay.bottom]');
      // Untouched for 5 s, they go by themselves.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(controls().hidden, isTrue);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/phone_call_video_bare.png'));

      // Full screen: turned sideways for a wide video, the controls away;
      // Back leaves full screen before putting the view away.
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('phone-call-full-screen')));
      await tester.pumpAndSettle();
      expect(system, contains('setPreferredOrientations [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]'));
      expect(controls().hidden, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(system.last, 'setEnabledSystemUIOverlays [SystemUiOverlay.top, SystemUiOverlay.bottom]');
      expect(system, contains('setPreferredOrientations []'));
      expect(find.byKey(const Key('phone-call-view')), findsOneWidget);

      // Her shared screen, large: a double tap zooms in, another out.
      connection.emit(
        CallRoomState(
          encrypted: true,
          camera: connection.last.camera,
          peers: [
            CallPeer(
              user: kumiko,
              device: 'phone',
              camera: FakeVideo('kumiko'),
              screen: FakeVideo('kumiko-screen', size: const Size(1920, 1080)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      double zoom() =>
          tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.getMaxScaleOnAxis();
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(zoom(), closeTo(2.5, 0.01));
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(zoom(), closeTo(1, 0.01));

      // Put away: the system's bars back.
      await tester.pump(kDoubleTapTimeout);
      await tester.tap(find.byKey(const Key('phone-call-minimize')));
      await tester.pumpAndSettle();
      expect(system.last, 'setEnabledSystemUIOverlays [SystemUiOverlay.top, SystemUiOverlay.bottom]');
    },
  );

  /// Over the lock screen, a video call from Kumiko answered there, her
  /// camera coming in.
  Future<void> lockedVideoCall(WidgetTester tester, {List<Override> overrides = const []}) async {
    await openApp(tester, phone: true, overrides: overrides);
    final call = testCall(
      id: 'locked-video',
      conv: 'dm-kumiko',
      startedBy: kumiko,
      video: true,
      ringUntil: testNow.add(const Duration(seconds: 45)),
    );
    window.lockScreen.add(true);
    await tester.pump();
    repo.tell(call);
    await tester.pump();
    await tester.pump();
    expect(find.text('Incoming video call'), findsOneWidget);
    repo.onJoin = (_) => call;
    await tester.tap(find.byKey(const Key('locked-accept')));
    await tester.pump();
    repo.keys.add(testKey(1));
    await tester.pump();
    await tester.pump();
    expect(connection.camera, isTrue, reason: 'answered with the camera on');
    connection.emit(
      CallRoomState(
        encrypted: true,
        camera: connection.last.camera,
        peers: [CallPeer(user: kumiko, device: 'phone', camera: FakeVideo('kumiko'))],
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('over the lock screen, a call with video: as on phones, and no way into the app but unlocking', (tester) async {
    await lockedVideoCall(tester);
    expect(find.byKey(const Key('phone-call-view')), findsOneWidget);
    expect((find.byKey(const Key('phone-call-minimize')).evaluate().length, find.byKey(const Key('phone-call-unlock')).evaluate().length), (0, 1));
    expect(find.text('Chats'), findsNothing, reason: 'nothing of the chats over the lock screen');
    expect(find.text('Kumiko'), findsWidgets);
    expect(find.byKey(const ValueKey('video-kumiko')), findsOneWidget);
  });

  testWidgets('over the lock screen without previews: no names', (tester) async {
    await lockedVideoCall(tester, overrides: [notificationPreferencesProvider.overrideWith(_NoPreviews.new)]);
    expect(find.byKey(const Key('phone-call-view')), findsOneWidget);
    expect((find.text('Kumiko').evaluate().length, find.text('Hanashi').evaluate().length), (0, 1));
    expect(find.byKey(const ValueKey('video-kumiko')), findsOneWidget, reason: 'her camera still');
  });
}

/// Notifications that show no names or text.
class _NoPreviews extends NotificationPreferencesController {
  @override
  Future<NotificationPreferences> build() async => const NotificationPreferences(preview: false);
}
