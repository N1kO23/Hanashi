import 'dart:convert';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../calls/call_alerts.dart';
import '../data/local/database.dart';
import '../diagnostics/app_log.dart';
import '../notifications/notification_center.dart';

const _log = Log('push');

/// A push about a call (see docs/protocol.md): one that rings this user, or
/// one that stops ringing.
sealed class CallPush {
  const CallPush();

  /// What [content] says of a call; null if it says something else (a sync
  /// push, or one the distributor could not decrypt).
  static CallPush? parse(Uint8List content) {
    try {
      final json = jsonDecode(utf8.decode(content));
      if (json is! Map) return null;
      return switch (json['type']) {
        'call' => CallRing(Call.fromJson((json['call'] as Map).cast<String, Object?>())),
        'call_stop' => CallStop(
          callId: json['call'] as String,
          conv: json['conv'] as String,
          reason: json['reason'] as String,
        ),
        _ => null,
      };
    } on Object {
      return null;
    }
  }
}

/// A call of two rings the user.
class CallRing extends CallPush {
  const CallRing(this.call);

  final Call call;
}

/// A call stops ringing the user: answered (on another device), or over.
class CallStop extends CallPush {
  const CallStop({required this.callId, required this.conv, required this.reason});

  /// The reason when one of the user's devices answered.
  static const answered = 'answered';

  final String callId;
  final String conv;

  /// [answered], or how the call ended (`CallEnd`).
  final String reason;

  /// Over before anyone answered it: a missed call.
  bool get missed => reason == CallEnd.missed || reason == CallEnd.cancelled;
}

/// Shows what a call push says, while the app is closed (the push engine),
/// or with [ring] false while it runs, where the app rings for itself: a
/// call that stops, and a missed call. The caller's name shows only where
/// notification previews are on.
Future<void> showCallPush(
  CallPush push, {
  required AppDatabase db,
  required String me,
  required CallAlerts alerts,
  bool ring = true,
  DateTime Function() clock = DateTime.now,
}) async {
  switch (push) {
    case CallRing(:final call) when ring:
      final until = call.ringUntil;
      if (!call.unanswered || until == null || call.startedBy == me) return;
      // Long gone, whatever the clocks say.
      if (clock().isAfter(until.add(const Duration(minutes: 1)))) {
        _log.info('Call ${call.id} rang too long ago');
        return;
      }
      _log.info('Ringing for call ${call.id} in ${call.conv}');
      await alerts.showRing(
        RingingCall(
          callId: call.id,
          conv: call.conv,
          ringUntil: until,
          caller: await _name(db, call.startedBy, me),
          video: call.video,
        ),
      );
    case CallRing():
      return;
    case CallStop stop:
      await alerts.cancelRing(stop.callId);
      if (!stop.missed) return;
      final other = (await db.memberIds(stop.conv)).where((m) => m != me).firstOrNull;
      await alerts.showMissedCall(conv: stop.conv, caller: other == null ? null : await _name(db, other, me));
  }
}

/// Someone's name for a notification, or null when previews are off.
Future<String?> _name(AppDatabase db, String user, String me) async {
  if (!(await NotificationPreferences.load(db)).preview) return null;
  return (await db.profileNames())[user] ?? UserId.fallbackName(user, me: me);
}
