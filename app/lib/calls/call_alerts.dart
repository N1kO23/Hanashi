/// A call that rings this device, as its notification shows it.
class RingingCall {
  const RingingCall({
    required this.callId,
    required this.conv,
    required this.ringUntil,
    this.caller,
    this.video = false,
  });

  final String callId;
  final String conv;

  /// As the server says; the ring stops by itself a little after.
  final DateTime ringUntil;

  /// Who calls, by name; null when notifications show no names.
  final String? caller;

  /// A video call.
  final bool video;

  /// What rings: "Incoming voice call", or a video one.
  String get what => video ? 'Incoming video call' : 'Incoming voice call';
}

/// What the system shows of calls outside the app's window: Android's
/// notifications (see `LocalNotifier`). Elsewhere nothing, as the app's own
/// window shows it all.
abstract class CallAlerts {
  /// The call this device is in, with a way back to [conv] and a "Hang up".
  /// On Android this also keeps the app running, and its microphone open,
  /// in the background (a foreground service); with [sharing], also its
  /// screen captured (shown again with it once the user allowed that).
  Future<void> showOngoing({required String conv, required String title, bool video = false, bool sharing = false});

  Future<void> hideOngoing();

  /// Rings with the system's ringtone until answered, declined or stopped,
  /// over the lock screen too, with Accept and Decline. Once only: a call
  /// that rings already rings on.
  Future<void> showRing(RingingCall call);

  Future<void> cancelRing(String callId);

  /// A call of two that rang the user unanswered: one notification per
  /// chat, the latest.
  Future<void> showMissedCall({required String conv, String? caller});
}

class NoCallAlerts implements CallAlerts {
  const NoCallAlerts();

  @override
  Future<void> showOngoing({
    required String conv,
    required String title,
    bool video = false,
    bool sharing = false,
  }) async {}

  @override
  Future<void> hideOngoing() async {}

  @override
  Future<void> showRing(RingingCall call) async {}

  @override
  Future<void> cancelRing(String callId) async {}

  @override
  Future<void> showMissedCall({required String conv, String? caller}) async {}
}

/// The actions of call notifications.
abstract final class CallActionIds {
  /// Opens the app, answering.
  static const accept = 'accept';

  /// In the background, like [hangUp].
  static const decline = 'decline';
  static const hangUp = 'hang_up';
}

/// What the user did with a call's notification without opening the app:
/// one of [CallActionIds], and of which call (null: the one going on).
typedef CallAction = ({String action, String? callId});

/// A notification's payload for a call, and back.
String callPayload(String callId) => 'call:$callId';

String? callOfPayload(String? payload) =>
    payload != null && payload.startsWith('call:') ? payload.substring('call:'.length) : null;
