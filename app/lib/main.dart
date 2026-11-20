import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:openmls/openmls.dart';

import 'app.dart';
import 'app_storage.dart';
import 'calls/call_controller.dart';
import 'data/account.dart';
import 'data/local/database.dart';
import 'data/mock_chat_repository.dart';
import 'data/themes/app_theme.dart';
import 'data/themes/theme_library.dart';
import 'desktop/autostart.dart';
import 'desktop/tray.dart';
import 'diagnostics/app_log.dart';
import 'e2ee/secure_store.dart';
import 'notifications/call_actions.dart';
import 'notifications/local_notifier.dart';
import 'notifications/notification_center.dart';
import 'notifications/notification_look.dart';
import 'push/background_sync.dart';
import 'push/call_push.dart';
import 'push/push_engine.dart';
import 'push/push_service.dart';
import 'state/providers.dart';
import 'ui/encryption/encryption_screens.dart';
import 'ui/media/video_probe.dart';
import 'ui/window/window_controls.dart';

/// `flutter run --dart-define=HANASHI_DEMO=true` shows sample chats without a server.
const _demo = bool.fromEnvironment('HANASHI_DEMO');

const _log = Log('app');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android starts the app without its UI to handle a push while it is closed.
  if (args.contains('--unifiedpush-bg')) return runPushEngine();

  final storage = await AppStorage.resolve();
  AppLog.instance.start(storage.supportDir);
  // Before anything shows: the keyring screen, the tray, the first frame.
  final themes = ThemeLibrary.load(storage.supportDir);
  _log.info('Started on ${Platform.operatingSystem}${_demo ? ' (demo)' : ''}, log level ${AppLog.instance.level.name}');
  MediaKit.ensureInitialized();
  await Openmls.init();
  final windowControls = await initDesktopWindow(hidden: args.contains(Autostart.hiddenFlag));
  if (windowControls != null) {
    try {
      await DesktopTray.install(theme: themes.active);
    } on Object catch (e) {
      // Without a tray, closing the window quits as before, and a window
      // started hidden would be out of reach: it shows after all.
      _log.warning('No tray icon', e);
      await DesktopTray.showWindow();
    }
  }
  final store = _demo
      ? MemorySecureStore()
      : SwitchableSecureStore(
          await chooseSecretStore(storage.supportDir, windowControls: windowControls, themes: themes),
        );
  // The demo's key would not open the real database, so it keeps its own in
  // memory.
  final db = _demo
      ? AppDatabase(NativeDatabase.memory())
      : AppStorage.openDatabase(key: await AppStorage.databaseKey(store));

  // Tapping a notification opens what it is about; so does one that
  // started the app.
  final opens = StreamController<NotificationOpen>();
  final sounds = await SoundPlatform.load(storage.supportDir);
  LocalNotifier? notifications;
  try {
    notifications = _demo
        ? null
        : await LocalNotifier.create(
            look: notificationLookOf(themes.active, sounds),
            onOpen: (open) {
              if (windowControls != null) unawaited(DesktopTray.showWindow());
              opens.add(open);
            },
          );
  } on Object catch (e) {
    // The app works without notifications.
    _log.warning('Notifications unavailable', e);
  }
  final launchedFor = await notifications?.launchOpen();
  if (launchedFor != null) opens.add(launchedFor);
  final callPushes = StreamController<CallPush>.broadcast();
  if (notifications != null) {
    // A push that reaches the app while it is in the background.
    await PushService.initialize(
      store: store,
      onWake: () => syncForPush(
        db: db,
        store: store,
        storage: storage,
        notifier: notifications!,
        appName: () => themes.active.shownName,
      ),
      onCall: (push) {
        // The app rings for itself; a call that stops, or was missed, shows
        // as with the app closed.
        callPushes.add(push);
        unawaited(_showCallPush(push, db: db, store: store, notifier: notifications!));
      },
    );
  }

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        themeLibraryProvider.overrideWithValue(themes),
        soundPlatformProvider.overrideWithValue(sounds),
        mediaDirProvider.overrideWithValue(storage.mediaDir),
        mlsDirProvider.overrideWithValue(storage.supportDir),
        stickerPacksDirProvider.overrideWithValue(stickerPacksDir(storage.supportDir)),
        videoProbeProvider.overrideWithValue(probeVideoWithPlayer),
        windowControlsProvider.overrideWithValue(windowControls),
        secureStoreProvider.overrideWithValue(store),
        notificationDisplayProvider.overrideWithValue(notifications),
        notificationOpensProvider.overrideWithValue(opens.stream),
        if (notifications != null) callAlertsProvider.overrideWithValue(notifications),
        if (Platform.isAndroid && !_demo) callActionsProvider.overrideWithValue(receiveCallActions()),
        callPushesProvider.overrideWithValue(callPushes.stream),
        if (_demo) ...[
          appGateProvider.overrideWithValue(AppGate.ready),
          chatRepositoryProvider.overrideWithValue(MockChatRepository()),
        ],
      ],
      child: const HanashiApp(),
    ),
  );
}

Future<void> _showCallPush(
  CallPush push, {
  required AppDatabase db,
  required SecureStore store,
  required LocalNotifier notifier,
}) async {
  final account = await Account.read(store);
  if (account == null) return;
  try {
    await showCallPush(push, db: db, me: account.userId, alerts: notifier, ring: false);
  } on Object catch (e, stack) {
    _log.warning('Showing a call push', e, stack);
  }
}

/// Where this device keeps its secrets: the system keyring, or the file the
/// user chose on a start without one (see [KeyringMissingScreen], which this
/// [show]s until the user decides).
Future<SecureStore> chooseSecretStore(
  Directory supportDir, {
  WindowControls? windowControls,
  PlatformSecureStore? keyring,
  FileSecureStore? file,
  ThemeLibrary? themes,
  void Function(Widget app) show = runApp,
}) async {
  file ??= FileSecureStore(supportDir);
  if (await file.exists()) return file;
  keyring ??= PlatformSecureStore();
  if (await keyring.isAvailable()) return keyring;
  // Also when started hidden at login: this needs the user.
  if (windowControls != null) await DesktopTray.showWindow();
  final chosen = Completer<SecureStore>();
  themes ??= ThemeLibrary.load(null);
  final theme = themeDataOf(themes.active);
  show(
    ProviderScope(
      // Its own key: the app's scope must replace it, not take it over with
      // other overrides (which Riverpod does not allow).
      key: const ValueKey('keyring'),
      overrides: [windowControlsProvider.overrideWithValue(windowControls)],
      child: MaterialApp(
        title: themes.active.shownName,
        debugShowCheckedModeBanner: false,
        theme: theme.light,
        darkTheme: theme.dark,
        themeMode: themes.appearance.mode,
        home: KeyringMissingScreen(
          onRetry: () async {
            final works = await keyring!.isAvailable();
            if (works) chosen.complete(keyring);
            return works;
          },
          onUseFile: () async {
            await file!.create();
            chosen.complete(file);
          },
        ),
      ),
    ),
  );
  return chosen.future;
}
