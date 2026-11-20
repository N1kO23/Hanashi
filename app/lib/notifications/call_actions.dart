import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../calls/call_alerts.dart';
import '../data/account.dart';
import '../data/remote/api_client.dart';
import '../diagnostics/app_log.dart';
import '../e2ee/secure_store.dart';

const _log = Log('call');

/// Where the app's isolate hears of call notification actions.
const _portName = 'hanashi.call';

/// In the app's isolate: what the user does with call notifications outside
/// the app (see [onCallNotificationAction]). For the app's lifetime.
Stream<CallAction> receiveCallActions() {
  final port = ReceivePort('call actions');
  IsolateNameServer.removePortNameMapping(_portName);
  IsolateNameServer.registerPortWithName(port.sendPort, _portName);
  return port.map((message) {
    final [action as String, callId as String?] = message as List<Object?>;
    return (action: action, callId: callId);
  }).asBroadcastStream();
}

/// A notification action that does not open the app (Android runs it in an
/// isolate of its own): passed on to the app if it runs, or else done here.
@pragma('vm:entry-point')
Future<void> onCallNotificationAction(NotificationResponse response) async {
  final action = response.actionId;
  if (action == null) return;
  final callId = callOfPayload(response.payload);
  final app = IsolateNameServer.lookupPortByName(_portName);
  if (app != null) {
    app.send([action, callId]);
    return;
  }
  switch (action) {
    case CallActionIds.hangUp:
      // The app is gone, and its call with it: only the notification was left.
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.stopForegroundService();
    case CallActionIds.decline when callId != null:
      await declineWithoutApp(callId);
  }
}

/// Says no to a call that rings while the app is closed.
Future<void> declineWithoutApp(String callId) async {
  WidgetsFlutterBinding.ensureInitialized();
  final account = await Account.read(PlatformSecureStore());
  if (account == null) return;
  final api = ApiClient(account.serverUrl, token: account.token);
  try {
    await api.declineCall(callId);
  } on ApiException catch (e) {
    // It stops ringing anyway once its time is up.
    _log.warning('Declining call $callId: $e');
  } finally {
    api.close();
  }
}
