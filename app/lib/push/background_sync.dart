import 'dart:io';

import '../app_storage.dart';
import '../data/account.dart';
import '../data/local/database.dart';
import '../data/remote/api_client.dart';
import '../data/server_chat_repository.dart';
import '../data/sync_lock.dart';
import '../diagnostics/app_log.dart';
import '../e2ee/encryption_identity.dart';
import '../e2ee/secure_store.dart';
import '../notifications/notification_center.dart';

/// Handles a push: syncs once over HTTP and shows notifications for what
/// arrived. If the app (or another push) is syncing already, it is asked
/// to catch up instead.
const _log = Log('push');

Future<void> syncForPush({
  required AppDatabase db,
  required SecureStore store,
  required AppStorage storage,
  required NotificationDisplay notifier,
  String Function()? appName,
}) async {
  final account = await Account.read(store);
  if (account == null) return;
  if (await SyncLock.wakeHolder(account.deviceId)) {
    _log.debug('Woken by a push: the app is syncing already');
    return;
  }
  _log.debug('Woken by a push: syncing');
  final api = ApiClient(account.serverUrl, token: account.token);
  final identity = EncryptionIdentity(api: api, account: account, store: store);
  if (await identity.localSecrets() == null) {
    api.close();
    return;
  }
  late final ServerChatRepository repository;
  final notifications = NotificationCenter(
    db: db,
    me: account.userId,
    notifier: notifier,
    pictureBytes: (picture) => repository.mediaBytes(picture),
    appName: appName,
  );
  repository = ServerChatRepository(
    db: db,
    account: account,
    identity: identity,
    // The app notices too, the next time it opens.
    onSignedOut: () {},
    mediaDir: storage.mediaDir,
    packsDir: stickerPacksDir(storage.supportDir),
    tempDir: Directory('${Directory.systemTemp.path}/hanashi'),
    mlsDbPath: mlsDbPath(storage.supportDir, account.deviceId),
    onSynced: notifications.update,
  );
  try {
    await repository.syncOnce();
  } on Object catch (e, stack) {
    _log.warning('Sync for a push failed', e, stack);
  } finally {
    await repository.dispose();
    api.close();
  }
}
