import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:media_kit/media_kit.dart';

import '../calls/call_alerts.dart';
import '../data/themes/app_theme.dart';
import '../diagnostics/app_log.dart';
import 'call_actions.dart';
import 'notification_center.dart';
import 'notification_look.dart';

const _log = Log('notify');

/// [NotificationDisplay] backed by the platform's notification system,
/// sounding and looking as the theme shown has it (see [NotificationLook]);
/// on Android also the [CallAlerts].
class LocalNotifier implements NotificationDisplay, CallAlerts {
  LocalNotifier._(this._plugin, this._look, {required this._linuxServerPlays});

  final FlutterLocalNotificationsPlugin _plugin;

  /// Whether the Linux notification server plays sounds: dunst and mako play
  /// none, so the app plays its own there (see [planSound]).
  final bool _linuxServerPlays;

  NotificationLook _look;
  Player? _player;

  /// Audible messages and contact requests: an Android channel keeps the
  /// sound it was made with, so each sound has channels of its own (see
  /// [SoundPlan.androidChannel]). Silent notifications have their own too.
  static const _messages = 'messages';
  static const _contacts = 'contacts';
  static const _silentChannelId = 'messages_silent';
  static const _silentContactsChannelId = 'contacts_silent';

  /// The call this device is in, while it goes on (Android).
  static const _ongoingChannelId = 'calls_ongoing';
  static final _ongoingId = notificationId('call:ongoing');

  /// Calls that ring, with the system's ringtone, and those missed.
  static const _ringChannelId = 'calls_ring';
  static const _missedChannelId = 'calls_missed';

  /// Notification.FLAG_INSISTENT: the sound goes on until the ring stops.
  static const _insistent = 4;

  /// Sets up the plugin, for notifications that sound and look as [look]
  /// says (see [setLook]). [onOpen] gets the notifications the user taps
  /// while the app runs. Actions that do not open the app go to
  /// [onCallNotificationAction], in an isolate of their own (Android).
  static Future<LocalNotifier> create({
    void Function(NotificationOpen open)? onOpen,
    NotificationLook look = const NotificationLook(),
  }) async {
    final plugin = FlutterLocalNotificationsPlugin();
    const darwin = DarwinInitializationSettings(
      // Asked for in Settings, not at startup.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('ic_notification'),
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(
          defaultActionName: 'Open',
          defaultIcon: _linuxIcon(look.icon),
        ),
        windows: const WindowsInitializationSettings(
          appName: 'Hanashi',
          appUserModelId: 'nullpointr.Hanashi',
          guid: 'f6ed0ec4-1749-48a3-a520-9fbfdcad67a4',
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final target = response.payload;
        if (target != null && target.isNotEmpty) onOpen?.call(NotificationOpen(target, action: response.actionId));
      },
      onDidReceiveBackgroundNotificationResponse: onCallNotificationAction,
    );
    final linux = plugin.resolvePlatformSpecificImplementation<LinuxFlutterLocalNotificationsPlugin>();
    final notifier = LocalNotifier._(
      plugin,
      look,
      linuxServerPlays: linux != null && (await linux.getCapabilities()).sound,
    );
    await notifier._tidyChannels();
    return notifier;
  }

  /// How notifications sound and look from now on: as the theme shown has
  /// it. Those already shown stay as they are.
  NotificationLook get look => _look;

  Future<void> setLook(NotificationLook look) async {
    _look = look;
    await _tidyChannels();
  }

  /// How the theme's sound plays for [kind] notifications here.
  SoundPlan _sound(String kind) =>
      planSound(_look.sound, kind: kind, platform: defaultTargetPlatform, linuxServerPlays: _linuxServerPlays);

  /// Lets Android's audible message and contact channels of other sounds go.
  /// One with a notification showing stays until the next time: deleting it
  /// would take that away.
  Future<void> _tidyChannels() async {
    final android = _android;
    if (android == null) return;
    try {
      final current = {_sound(_messages).androidChannel, _sound(_contacts).androidChannel};
      final showing = {for (final shown in await android.getActiveNotifications()) ?shown.channelId};
      for (final channel in await android.getNotificationChannels() ?? const <AndroidNotificationChannel>[]) {
        final id = channel.id;
        final stale = soundChannelPattern.hasMatch(id) && !current.contains(id);
        if (stale && !showing.contains(id)) await android.deleteNotificationChannel(channelId: id);
      }
    } on PlatformException catch (e) {
      _log.info('Could not tidy the notification channels: $e');
    }
  }

  /// The notification that started the app, if one did (see [create]).
  Future<NotificationOpen?> launchOpen() async {
    // On Linux a click always reaches the running app (the plugin has no
    // launch details there).
    if (Platform.isLinux) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    final response = details?.notificationResponse;
    final target = response?.payload;
    if (details == null || !details.didNotificationLaunchApp || target == null || target.isEmpty) return null;
    return NotificationOpen(target, action: response?.actionId);
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  // Calls

  /// A call to show once the app is in front again: Android lets an app start
  /// using the microphone in the background only from there.
  ({String conv, String title, bool video, bool sharing})? _ongoingLater;
  AppLifecycleListener? _inFront;

  /// When the call shown going on began: its time keeps counting when it is
  /// shown again (sharing a screen, or no longer).
  ({String conv, int when})? _ongoingSince;

  @override
  Future<void> showOngoing({required String conv, required String title, bool video = false, bool sharing = false}) async {
    final android = _android;
    if (android == null) return;
    final now = WidgetsBinding.instance.lifecycleState;
    if (now == AppLifecycleState.hidden || now == AppLifecycleState.paused) {
      _ongoingLater = (conv: conv, title: title, video: video, sharing: sharing);
      _inFront ??= AppLifecycleListener(
        onResume: () {
          final later = _ongoingLater;
          _ongoingLater = null;
          if (later != null) {
            unawaited(showOngoing(conv: later.conv, title: later.title, video: later.video, sharing: later.sharing));
          }
        },
      );
      return;
    }
    final since = _ongoingSince;
    final when = since != null && since.conv == conv ? since.when : DateTime.now().millisecondsSinceEpoch;
    _ongoingSince = (conv: conv, when: when);
    try {
      await android.startForegroundService(
        id: _ongoingId,
        title: title,
        body: video ? 'Video call' : 'Voice call',
        payload: conv,
        // Not started again by the system: a call does not outlive the app.
        startType: AndroidServiceStartType.startNotSticky,
        foregroundServiceTypes: {
          AndroidServiceForegroundType.foregroundServiceTypeMicrophone,
          // Only once the user allowed capturing: Android checks.
          if (sharing) AndroidServiceForegroundType.foregroundServiceTypeMediaProjection,
        },
        notificationDetails: AndroidNotificationDetails(
          _ongoingChannelId,
          'Calls going on',
          channelDescription: 'The call you are in, while Hanashi is in the background',
          importance: Importance.low,
          priority: Priority.low,
          category: AndroidNotificationCategory.call,
          ongoing: true,
          autoCancel: false,
          silent: true,
          usesChronometer: true,
          when: when,
          visibility: NotificationVisibility.private,
          actions: const [
            // The service's notification goes with the service.
            AndroidNotificationAction(CallActionIds.hangUp, 'Hang up', cancelNotification: false),
          ],
        ),
      );
    } on PlatformException catch (e) {
      // The call goes on while the app is in front.
      _log.warning('Could not keep the call going in the background', e);
    }
  }

  @override
  Future<void> hideOngoing() async {
    _ongoingLater = null;
    _ongoingSince = null;
    await _android?.stopForegroundService();
  }

  @override
  Future<void> showRing(RingingCall call) async {
    final android = _android;
    if (android == null) return;
    final id = _ringId(call.callId);
    // Shown again, it would ring from the start.
    if ((await android.getActiveNotifications()).any((n) => n.id == id)) return;
    final left = call.ringUntil.difference(DateTime.now());
    await _plugin.show(
      id: id,
      title: call.caller ?? call.what,
      body: call.caller == null ? null : call.what,
      payload: callPayload(call.callId),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _ringChannelId,
          'Incoming calls',
          channelDescription: 'Calls that ring you, also on the lock screen',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          // Over the lock screen, and the screen woken: the app's own call
          // screen (see MainActivity.kt).
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          vibrationPattern: Int64List.fromList([0, 1000, 1000]),
          additionalFlags: Int32List.fromList([_insistent]),
          // Should the server's word that it stopped not come (and whatever
          // the clocks say).
          timeoutAfter: left.inMilliseconds.clamp(15000, 90000) + 5000,
          visibility: NotificationVisibility.private,
          actions: const [
            AndroidNotificationAction(CallActionIds.decline, 'Decline', titleColor: Color(0xFFD32F2F)),
            AndroidNotificationAction(
              CallActionIds.accept,
              'Accept',
              titleColor: Color(0xFF2E7D32),
              showsUserInterface: true,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Future<void> cancelRing(String callId) async {
    if (_android != null) await _plugin.cancel(id: _ringId(callId));
  }

  @override
  Future<void> showMissedCall({required String conv, String? caller}) async {
    if (_android == null) return;
    await _plugin.show(
      id: notificationId('missed:$conv'),
      title: 'Missed voice call',
      body: caller,
      payload: conv,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _missedChannelId,
          'Missed calls',
          channelDescription: 'Calls that rang you unanswered',
          category: AndroidNotificationCategory.missedCall,
          // The ring was heard, or it was not: either way no second sound.
          playSound: false,
          enableVibration: false,
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }

  static int _ringId(String callId) => notificationId(callPayload(callId));

  /// Android 13+, macOS and iOS ask the user; elsewhere it is allowed.
  @override
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          true;
    }
    if (Platform.isMacOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true) ??
          true;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true) ??
          true;
    }
    return true;
  }

  @override
  Future<void> show(ChatNotification n) async {
    final lines = n.lines;
    final String body;
    if (lines.isEmpty) {
      body = n.unread == 1 ? 'New message' : '${n.unread} new messages';
    } else {
      body = [for (final line in lines) n.isGroup ? '${line.sender}: ${line.text}' : line.text].join('\n');
    }
    final sound = _sound(_messages);
    await _plugin.show(
      id: notificationId(n.conversationId),
      title: n.title,
      body: body,
      payload: n.conversationId,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          n.audible ? sound.androidChannel : _silentChannelId,
          n.audible ? 'Messages' : 'Silent messages',
          channelDescription: n.audible ? 'New chat messages' : 'Chat messages that make no sound',
          importance: n.audible ? Importance.high : Importance.low,
          priority: n.audible ? Priority.high : Priority.low,
          category: AndroidNotificationCategory.message,
          playSound: n.audible,
          sound: n.audible ? sound.androidSound : null,
          // On the lock screen only "Hanashi", unless the user allows more.
          visibility: NotificationVisibility.private,
          number: n.unread,
          styleInformation: lines.isEmpty
              ? null
              : MessagingStyleInformation(
                  const Person(name: 'You'),
                  conversationTitle: n.isGroup ? n.title : null,
                  groupConversation: n.isGroup,
                  messages: [
                    for (final line in lines)
                      Message(
                        line.text,
                        line.time,
                        Person(
                          name: line.sender,
                          icon: line.picture == null ? null : BitmapFilePathAndroidIcon(line.picture!),
                        ),
                      ),
                  ],
                ),
        ),
        linux: _linux(sound, audible: n.audible, category: LinuxNotificationCategory.imReceived),
        macOS: _darwin(audible: n.audible && !sound.silenced, thread: 'messages'),
        iOS: _darwin(audible: n.audible, thread: 'messages'),
        windows: _windows(sound),
      ),
    );
    if (n.audible) await _playInApp(sound);
  }

  /// Taps open the Contacts tab: the requests to answer, or the new contact.
  @override
  Future<void> showContact(ContactNotification n) async {
    final sound = _sound(_contacts);
    await _plugin.show(
      id: notificationId(_contactKey(n.userId)),
      title: n.title,
      body: n.body,
      payload: n.notice == ContactNotice.request ? '/contacts' : '/contacts/${Uri.encodeComponent(n.userId)}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          n.audible ? sound.androidChannel : _silentContactsChannelId,
          n.audible ? 'Contact requests' : 'Silent contact requests',
          channelDescription: n.audible
              ? 'Requests to become your contact, and answers to yours'
              : 'Contact requests that make no sound',
          importance: n.audible ? Importance.high : Importance.low,
          priority: n.audible ? Priority.high : Priority.low,
          category: AndroidNotificationCategory.social,
          playSound: n.audible,
          sound: n.audible ? sound.androidSound : null,
          visibility: NotificationVisibility.private,
        ),
        linux: _linux(sound, audible: n.audible, category: LinuxNotificationCategory.im),
        macOS: _darwin(audible: n.audible && !sound.silenced, thread: 'contacts'),
        iOS: _darwin(audible: n.audible, thread: 'contacts'),
        windows: _windows(sound),
      ),
    );
    if (n.audible) await _playInApp(sound);
  }

  @override
  Future<void> cancelContact(String userId) => _plugin.cancel(id: notificationId(_contactKey(userId)));

  /// Apart from conversation IDs, which are ULIDs.
  static String _contactKey(String userId) => 'contact:$userId';

  LinuxNotificationDetails _linux(
    SoundPlan sound, {
    required bool audible,
    required LinuxNotificationCategory category,
  }) => LinuxNotificationDetails(
    category: category,
    // The theme's now (the plugin's default is the one shown when it started).
    icon: _linuxIcon(_look.icon),
    sound: audible ? sound.linuxSound : null,
    suppressSound: !audible || sound.linuxSuppress,
  );

  static LinuxNotificationIcon? _linuxIcon(ThemeSource? icon) => switch (icon) {
    AssetSource(:final asset) => AssetsLinuxIcon(asset),
    FileSource(:final path) => FilePathLinuxIcon(path),
    null => null,
  };

  static DarwinNotificationDetails _darwin({required bool audible, required String thread}) =>
      DarwinNotificationDetails(threadIdentifier: thread, presentSound: audible);

  static WindowsNotificationDetails? _windows(SoundPlan sound) =>
      sound.silenced ? WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()) : null;

  /// Plays the sound where the notification does not (see [SoundPlan.inApp]).
  Future<void> _playInApp(SoundPlan sound) async {
    final media = sound.inApp;
    if (media == null) return;
    try {
      await (_player ??= Player()).open(Media(media));
    } on Object catch (e) {
      _log.info('Could not play the notification sound: $e');
    }
  }

  @override
  Future<void> cancel(String conversationId) => _plugin.cancel(id: notificationId(conversationId));

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}

/// A stable notification ID for a conversation (FNV-1a), the same in every
/// engine and every run, so a later sync replaces or removes it.
int notificationId(String conversationId) {
  var hash = 0x811c9dc5;
  for (final unit in conversationId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}
