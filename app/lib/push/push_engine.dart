import 'dart:async';

import 'package:openmls/openmls.dart';

import '../app_storage.dart';
import '../data/account.dart';
import '../data/local/database.dart';
import '../data/themes/app_theme.dart';
import '../data/themes/theme_library.dart';
import '../diagnostics/app_log.dart';
import '../e2ee/secure_store.dart';
import '../notifications/local_notifier.dart';
import '../notifications/notification_look.dart';
import 'background_sync.dart';
import 'call_push.dart';
import 'push_service.dart';

const _log = Log('push');

/// Entry point when Android starts the app for a push (`--unifiedpush-bg`):
/// no UI, only syncing, notifications and ringing. The engine lives on while
/// Android keeps the push service running and handles further pushes.
Future<void> runPushEngine() async {
  final storage = await AppStorage.resolve();
  AppLog.instance.start(storage.supportDir);
  // A call rings without it, so it is not waited for to hear of one.
  final mls = Openmls.init();
  final store = PlatformSecureStore();
  final db = AppStorage.openDatabase(key: await AppStorage.databaseKey(store));
  final sounds = await SoundPlatform.load(storage.supportDir);
  // As the theme the app shows has them: read again on each push, as the
  // user may have chosen another since.
  NotificationLook look(AppTheme theme) => notificationLookOf(theme, sounds);
  final notifier = await LocalNotifier.create(look: look(ThemeLibrary.load(storage.supportDir).active));
  await PushService.initialize(
    store: store,
    onWake: () async {
      await mls;
      final theme = ThemeLibrary.load(storage.supportDir).active;
      await notifier.setLook(look(theme));
      await syncForPush(db: db, store: store, storage: storage, notifier: notifier, appName: () => theme.shownName);
    },
    onCall: (push) => unawaited(_showCall(push, db: db, store: store, notifier: notifier)),
  );
}

Future<void> _showCall(
  CallPush push, {
  required AppDatabase db,
  required SecureStore store,
  required LocalNotifier notifier,
}) async {
  final account = await Account.read(store);
  if (account == null) return;
  try {
    await showCallPush(push, db: db, me: account.userId, alerts: notifier);
  } on Object catch (e, stack) {
    _log.warning('Showing a call push', e, stack);
  }
}
