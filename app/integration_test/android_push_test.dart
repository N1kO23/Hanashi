// Push notifications on Android through the real push path: the app
// registers with UnifiedPush (here the built-in FCM distributor), the server
// sends an encrypted Web Push to FCM, the phone receives it, syncs and shows
// a notification. Needs an Android device with Google Play services and a
// server it can reach (10.0.2.2 is the host, from the emulator):
//
//   flutter test integration_test/android_push_test.dart -d emulator-5554 \
//     --dart-define=HANASHI_TEST_SERVER=http://10.0.2.2:18080
//
// Grant the notification permission once the app is installed:
//   adb shell pm grant app.nullpointr.hanashi android.permission.POST_NOTIFICATIONS
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hanashi/app_storage.dart';
import 'package:hanashi/data/account.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi/data/server_chat_repository.dart';
import 'package:hanashi/e2ee/encryption_identity.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:hanashi/notifications/local_notifier.dart';
import 'package:hanashi/push/background_sync.dart';
import 'package:hanashi/push/push_service.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:openmls/openmls.dart';

const _server = String.fromEnvironment('HANASHI_TEST_SERVER');

/// Lets the test send the app to the background and back.
class _ManualSync extends SyncActive {
  @override
  bool build() => true;

  void set(bool active) => state = active;
}

/// Kumiko, on another device: her own in-memory state.
class _Contact {
  _Contact._(this.api, this.db, this.repo);

  final ApiClient api;
  final AppDatabase db;
  final ServerChatRepository repo;

  static Future<_Contact> signUp(String name) async {
    final anonymous = ApiClient(_server);
    final auth = await anonymous.register(name: name, password: 'password123', deviceName: 'bot', platform: 'test');
    anonymous.close();
    final account = Account(
      serverUrl: _server,
      userId: auth.userId,
      displayName: name,
      token: auth.token,
      deviceId: auth.deviceId,
    );
    final api = ApiClient(_server, token: auth.token);
    final identity = EncryptionIdentity(api: api, account: account, store: MemorySecureStore());
    await identity.setUp();
    final dir = Directory.systemTemp.createTempSync('kumiko_');
    final db = AppDatabase(NativeDatabase.memory());
    final repo = ServerChatRepository(
      db: db,
      account: account,
      identity: identity,
      onSignedOut: () {},
      mediaDir: Directory('${dir.path}/media'),
      packsDir: Directory('${dir.path}/packs'),
      tempDir: Directory('${dir.path}/tmp'),
    )..start();
    await repo.watchConnection().firstWhere((s) => s == ConnectionStatus.online).timeout(const Duration(seconds: 30));
    return _Contact._(api, db, repo);
  }

  Future<void> close() async {
    await repo.dispose();
    await db.close();
    api.close();
  }
}

Future<T> _eventually<T extends Object>(Future<T?> Function() probe, String reason, {int seconds = 30}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    final value = await probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TestFailure('Timed out: $reason');
}

// The app stays running here (in the background), so pushes reach its
// engine. A push while the app is not running starts a headless engine
// instead (`push_engine.dart`), which a test build cannot exercise: its
// entry point is the test runner.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(Openmls.init);

  testWidgets('a push through FCM wakes the app, which syncs and shows a notification', (tester) async {
    if (!Platform.isAndroid || _server.isEmpty) {
      markTestSkipped('Needs Android and --dart-define=HANASHI_TEST_SERVER=...');
      return;
    }
    await tester.runAsync(() async {
      // The same storage as the app and its headless push engine.
      final storage = await AppStorage.resolve();
      final store = PlatformSecureStore();
      final db = AppStorage.openDatabase(key: await AppStorage.databaseKey(store));
      await store.delete(Account.storageKey);
      await db.clearAll();
      final display = await LocalNotifier.create();
      await display.cancelAll();

      final endpoints = StreamController<String>.broadcast();
      var wakes = 0;
      await PushService.initialize(
        store: store,
        onWake: () {
          wakes++;
          return syncForPush(db: db, store: store, storage: storage, notifier: display);
        },
        onCall: (_) {},
        onRegistered: endpoints.add,
      );

      final run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final kumiko = await _Contact.signUp('kumiko$run');
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(store),
          mediaDirProvider.overrideWithValue(storage.mediaDir),
          mlsDirProvider.overrideWithValue(storage.supportDir),
          notificationDisplayProvider.overrideWithValue(display),
          syncActiveProvider.overrideWith(_ManualSync.new),
        ],
      );
      final keepAlive = container.listen(chatRepositoryProvider, (_, _) {});

      // Sota signs up on this phone and sets up encryption.
      await container.read(accountProvider.future);
      await container
          .read(accountProvider.notifier)
          .signIn(serverUrl: _server, name: 'sota$run', password: 'password123', register: true);
      await container.read(encryptionProvider.future);
      await container.read(encryptionProvider.notifier).setUp();
      container.read(encryptionProvider.notifier).acknowledgeRecoveryKey();
      expect(container.read(appGateProvider), AppGate.ready);
      await container
          .read(chatRepositoryProvider)
          .watchConnection()
          .firstWhere((s) => s == ConnectionStatus.online)
          .timeout(const Duration(seconds: 30));

      // Push registration: no distributor app here, so the built-in FCM one.
      await db.setValue('notify.permission-asked', 'yes'); // Granted with adb instead of a prompt.
      final firstEndpoint = endpoints.stream.first;
      expect(await container.read(pushRegistrationProvider.future), isTrue);
      final endpoint = await firstEndpoint.timeout(const Duration(seconds: 60));
      debugPrint('Push endpoint: $endpoint');
      expect(endpoint, startsWith('https://fcm.googleapis.com/'));
      expect(await PushService.current(), PushService.builtInDistributor);

      // Kumiko starts a chat while the app is open.
      final me = container.read(accountProvider).value!.userId;
      await container.read(chatRepositoryProvider).requestContact(kumiko.repo.me);
      await kumiko.repo.watchContacts().firstWhere((c) => c[me] == ContactState.incoming).timeout(const Duration(seconds: 30));
      await kumiko.repo.acceptContact(me);
      final conv = await kumiko.repo.openDirectConversation(me);
      await kumiko.repo.sendText(conv, 'Are you there?');
      await _eventually(() async {
        final messages = await db.watchMessages(conv).first;
        return messages.length == 1 && messages.single.envelope.text == 'Are you there?' ? true : null;
      }, 'the open app receives the first message');

      // The app goes to the background: it disconnects, pushes take over.
      (container.read(syncActiveProvider.notifier) as _ManualSync).set(false);
      await Future<void>.delayed(const Duration(seconds: 2));
      await kumiko.repo.sendText(conv, 'Sota, push check!');

      // FCM delivers the push; the app syncs and shows a notification.
      final shown = await _eventually(() async {
        final active = await FlutterLocalNotificationsPlugin().getActiveNotifications();
        return active.where((n) => n.id == notificationId(conv)).firstOrNull;
      }, 'the notification appears', seconds: 120);
      debugPrint('Notification: ${shown.title} / ${shown.body} after $wakes wake-up(s)');
      expect(shown.title, 'kumiko$run');
      expect(shown.body, contains('Sota, push check!'));
      expect(wakes, greaterThan(0));

      // Back in the foreground: the message was decrypted in the background.
      (container.read(syncActiveProvider.notifier) as _ManualSync).set(true);
      final messages = await _eventually(() async {
        final messages = await db.watchMessages(conv).first;
        return messages.length == 2 ? messages : null;
      }, 'the app shows both messages');
      expect(messages.last.envelope.text, 'Sota, push check!');
      expect(messages.last.envelope.type, isNot(Envelope.encryptedType));

      keepAlive.close();
      container.dispose();
      await kumiko.close();
      await display.cancelAll();
    });
  });
}
