import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/calls/call_alerts.dart';
import 'package:hanashi/calls/call_ringer.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/push/call_push.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../support/fake_calls.dart';
import '../support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = 'sota@localhost', kumiko = 'kumiko@localhost', conv = 'dm-kumiko';
  late AppDatabase db;
  late FakeCallAlerts alerts;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    alerts = FakeCallAlerts();
    await db.applyConversation(
      const ConversationInfo(
        id: conv,
        isDirect: true,
        members: [
          MemberInfo(id: me),
          MemberInfo(id: kumiko),
        ],
      ),
    );
    await db.into(db.profiles).insertOnConflictUpdate(ProfilesCompanion.insert(id: kumiko, displayName: 'Kumiko'));
  });

  Uint8List bytes(Object json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));
  final ringUntil = testNow.add(const Duration(seconds: 45));

  test('pushes about calls are told from the others', () {
    final call = testCall(conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    final ring = CallPush.parse(bytes({'type': 'call', 'call': call.toJson()}));
    expect((ring as CallRing).call.id, call.id);
    final stop = CallPush.parse(bytes({'type': 'call_stop', 'call': call.id, 'conv': conv, 'reason': 'cancelled'}));
    expect((stop as CallStop).missed, isTrue);
    expect(CallStop(callId: call.id, conv: conv, reason: CallStop.answered).missed, isFalse);
    expect(CallPush.parse(bytes({'type': 'sync'})), isNull);
    expect(CallPush.parse(Uint8List.fromList([0xff, 0x00, 0x13])), isNull, reason: 'not decrypted');
  });

  test('a call rings with the caller named, unless previews are off; one long gone, or our own, does not', () async {
    Future<void> show(CallPush push, {DateTime? now}) =>
        showCallPush(push, db: db, me: me, alerts: alerts, clock: () => now ?? testNow);
    final call = testCall(id: 'push-ring', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    await show(CallRing(call));
    expect((alerts.log.single, alerts.caller), ('ring ${call.id}', 'Kumiko'));

    await db.setValue('notify.preview', 'false');
    await show(CallRing(call));
    expect((alerts.log.length, alerts.caller), (2, null));

    await show(CallRing(call), now: ringUntil.add(const Duration(minutes: 2)));
    await show(CallRing(testCall(id: 'push-mine', conv: conv, startedBy: me, ringUntil: ringUntil)));
    await show(
      CallRing(testCall(id: 'push-answered', conv: conv, startedBy: kumiko, ringUntil: ringUntil, answeredAt: testNow)),
    );
    expect(alerts.log, hasLength(2));
  });

  test('a call that stops: the ring goes, and one unanswered shows as missed', () async {
    final call = testCall(id: 'push-stop', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    await showCallPush(
      CallStop(callId: call.id, conv: conv, reason: CallStop.answered),
      db: db,
      me: me,
      alerts: alerts,
    );
    expect(alerts.log, ['ring gone ${call.id}']);
    await showCallPush(
      CallStop(callId: call.id, conv: conv, reason: CallEnd.missed),
      db: db,
      me: me,
      alerts: alerts,
    );
    expect(alerts.log.sublist(1), ['ring gone ${call.id}', 'missed $conv Kumiko']);
  });

  test('while the app runs, it rings for itself: a push only stops a ring', () async {
    final call = testCall(id: 'push-app', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    await showCallPush(CallRing(call), db: db, me: me, alerts: alerts, ring: false);
    expect(alerts.log, isEmpty);
  });

  test('a phone rings from the app while it is in front, and from its notification otherwise', () {
    final window = FakeCallWindow();
    var inFront = true;
    final ringer = PhoneRinger(alerts, window, inFront: () => inFront);
    final call = testCall(id: 'phone', conv: conv, startedBy: kumiko, ringUntil: ringUntil);
    ringer.start(RingingCall(callId: call.id, conv: conv, ringUntil: ringUntil, caller: 'Kumiko'));
    expect((window.ringing, alerts.log.single), (true, 'ring gone ${call.id}'));

    inFront = false;
    ringer.changed();
    expect((window.ringing, alerts.log.last, alerts.caller), (false, 'ring ${call.id}', 'Kumiko'));
    ringer.changed();
    expect(alerts.log, hasLength(2), reason: 'no change, nothing done');

    inFront = true;
    ringer.changed();
    expect((window.ringing, alerts.log.last), (true, 'ring gone ${call.id}'));
    ringer.stop();
    expect((window.ringing, alerts.log.last, alerts.log.length), (false, 'ring gone ${call.id}', 4));
  });
}
