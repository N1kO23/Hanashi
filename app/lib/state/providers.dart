import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ThemeData, ThemeMode;
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_storage.dart';
import '../data/account.dart';
import '../data/attachments.dart';
import '../data/chat_repository.dart';
import '../data/local/database.dart';
import '../data/models.dart';
import '../data/packs/sticker_pack.dart';
import '../data/themes/app_theme.dart';
import '../data/themes/appearance.dart';
import '../data/themes/theme_library.dart';
import '../data/remote/api_client.dart';
import '../data/remote/klipy.dart';
import '../data/remote/link_previews.dart';
import '../data/remote/remote_media.dart';
import '../data/server_chat_repository.dart';
import '../diagnostics/app_log.dart';
import '../e2ee/encryption_identity.dart';
import '../e2ee/primitives.dart';
import '../e2ee/secure_store.dart';
import '../e2ee/verification_service.dart';
import '../notifications/notification_center.dart';
import '../launcher/theme_launcher.dart';
import '../notifications/notification_look.dart';
import '../push/push_service.dart';
import '../ui/chat/bubble_look.dart';

const _log = Log('account');

/// Current time; overridden in tests so rendered timestamps are stable.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Directory for cached media; set in `main.dart`.
final mediaDirProvider = Provider<Directory>((ref) => throw UnimplementedError('mediaDirProvider must be overridden'));

/// Where the sticker packs the user keeps are, extracted: a temporary folder
/// unless overridden (in `main.dart`).
final stickerPacksDirProvider = Provider<Directory>(
  (ref) => Directory('${Directory.systemTemp.path}/hanashi/sticker_packs'),
);

/// Reads video metadata with the platform player; set in `main.dart`.
final videoProbeProvider = Provider<VideoProbe?>((ref) => null);

/// Keychain-backed in the app (`main.dart`); in memory for tests and demo mode.
final secureStoreProvider = Provider<SecureStore>(
  (ref) => throw UnimplementedError('secureStoreProvider must be overridden'),
);

/// Opened in `main.dart`.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final accountProvider = AsyncNotifierProvider<AccountController, Account?>(
  AccountController.new,
  // Reading it again rarely helps (the keyring is gone, say), and while
  // retrying the app would only show its loading screen. It says what is
  // wrong instead, with a button to try again.
  retry: (_, _) => null,
);

class AccountController extends AsyncNotifier<Account?> {
  AppDatabase get _db => ref.read(databaseProvider);
  SecureStore get _store => ref.read(secureStoreProvider);

  @override
  Future<Account?> build() => Account.read(_store);

  /// Signs in (or registers) this device. Throws [ApiException] on failure.
  Future<void> signIn({
    required String serverUrl,
    required String name,
    required String password,
    bool register = false,
    String? displayName,
    String? inviteCode,
  }) async {
    final api = ApiClient(serverUrl);
    try {
      final deviceName = _deviceName();
      final result = register
          ? await api.register(
              name: name,
              password: password,
              inviteCode: inviteCode,
              deviceName: deviceName,
              platform: Platform.operatingSystem,
            )
          : await api.login(name: name, password: password, deviceName: deviceName, platform: Platform.operatingSystem);
      final account = Account(
        serverUrl: api.baseUrl,
        userId: result.userId,
        displayName: displayName ?? UserId.tryParse(result.userId)?.name ?? result.userId,
        token: result.token,
        deviceId: result.deviceId,
      );
      await _db.clearAll(); // Never mix another account's cached chats in.
      await account.write(_store);
      _log.info('${register ? 'Registered' : 'Signed in'} as ${account.userId}, device ${account.deviceId}');
      state = AsyncData(account);
    } finally {
      api.close();
    }
  }

  /// Signs this device out and wipes its local data. With [notifyServer]
  /// false (the server already revoked the session) no request is made.
  Future<void> signOut({bool notifyServer = true}) async {
    final account = state.value;
    _log.info(
      'Signing out ${account?.userId}, device ${account?.deviceId}${notifyServer ? '' : ' (ended by the server)'}',
    );
    if (account != null && notifyServer) {
      final api = ApiClient(account.serverUrl, token: account.token);
      try {
        await api.logout();
      } on ApiException {
        // Signing out locally still works offline; the device can be revoked later.
      } finally {
        api.close();
      }
    }
    // Its notifications and pushes belonged to the account.
    await PushService.unregister();
    await ref.read(notificationDisplayProvider)?.cancelAll();
    if (account != null) {
      // This device's keys are useless once its session is gone.
      await EncryptionIdentity(api: ApiClient(account.serverUrl), account: account, store: _store).forget();
    }
    await _store.delete(Account.storageKey);
    await _db.clearAll();
    // Which packs the user keeps is theirs too.
    try {
      final packs = ref.read(stickerPacksDirProvider);
      if (packs.existsSync()) await packs.delete(recursive: true);
    } on FileSystemException {
      // In use: whatever the next account does not keep goes then.
    }
    state = const AsyncData(null);
  }

  static String _deviceName() {
    final os = switch (Platform.operatingSystem) {
      'android' => 'Android',
      'ios' => 'iPhone/iPad',
      'macos' => 'Mac',
      'windows' => 'Windows PC',
      'linux' => 'Linux PC',
      final other => other,
    };
    final host = Platform.localHostname;
    return host.isEmpty || host == 'localhost' ? os : '$os ($host)';
  }
}

/// Where this device stands with end-to-end encryption, plus a freshly
/// created recovery key that the user still has to see.
class EncryptionState {
  const EncryptionState(this.status, {this.recoveryKeyToShow});

  final EncryptionStatus status;

  /// Encoded recovery key, shown once right after it is created.
  final String? recoveryKeyToShow;
}

final encryptionProvider = AsyncNotifierProvider<EncryptionController, EncryptionState?>(EncryptionController.new);

class EncryptionController extends AsyncNotifier<EncryptionState?> {
  EncryptionIdentity? _identity;

  EncryptionIdentity get identity => _identity!;

  @override
  Future<EncryptionState?> build() async {
    final account = ref.watch(accountProvider.select((a) => a.value));
    if (account == null) return null;
    final api = ApiClient(account.serverUrl, token: account.token);
    ref.onDispose(api.close);
    final identity = _identity = EncryptionIdentity(api: api, account: account, store: ref.watch(secureStoreProvider));
    try {
      return EncryptionState(await identity.status());
    } on ApiException catch (e) {
      // Offline or in need of an update: a device verified before keeps working.
      if ((e.isNetworkError || e.isClientTooOld) && await identity.localSecrets() != null) {
        return const EncryptionState(EncryptionStatus.verified);
      }
      rethrow;
    }
  }

  /// Creates the identity (or replaces it with [reset]) and shows the new recovery key.
  Future<void> setUp({bool reset = false}) async {
    final recoveryKey = await identity.setUp(reset: reset);
    state = AsyncData(EncryptionState(EncryptionStatus.verified, recoveryKeyToShow: await recoveryKey.encode()));
  }

  /// Throws [FormatException] for a mistyped key and [VerificationException]
  /// for a wrong one.
  Future<void> verifyWithRecoveryKey(String text) async {
    await identity.verifyWithRecoveryKey(await RecoveryKey.parse(text));
    state = const AsyncData(EncryptionState(EncryptionStatus.verified));
  }

  Future<void> newRecoveryKey() async {
    final recoveryKey = await identity.newRecoveryKey();
    state = AsyncData(EncryptionState(EncryptionStatus.verified, recoveryKeyToShow: await recoveryKey.encode()));
  }

  void acknowledgeRecoveryKey() => state = const AsyncData(EncryptionState(EncryptionStatus.verified));

  /// Another device verified this one (emoji verification).
  void deviceVerified() => state = const AsyncData(EncryptionState(EncryptionStatus.verified));

  /// The user's identity fingerprint, if this device holds the identity.
  Future<String?> fingerprint() async {
    final identityKey = await _identity?.localIdentity();
    return identityKey == null ? null : identityFingerprint(identityKey.publicKeyBase64);
  }

  void retry() => ref.invalidateSelf();
}

/// Top-level navigation state.
enum AppGate { loading, signedOut, needsSetup, unverified, showRecoveryKey, unavailable, ready }

final appGateProvider = Provider<AppGate>((ref) {
  final account = ref.watch(accountProvider);
  if (account.isLoading) return AppGate.loading;
  if (account.hasError) return AppGate.unavailable;
  if (account.value == null) return AppGate.signedOut;
  final encryption = ref.watch(encryptionProvider);
  if (encryption.hasError && !encryption.isLoading) return AppGate.unavailable;
  final state = encryption.value;
  if (state == null) return AppGate.loading;
  if (state.recoveryKeyToShow != null) return AppGate.showRecoveryKey;
  return switch (state.status) {
    EncryptionStatus.needsSetup => AppGate.needsSetup,
    EncryptionStatus.unverified => AppGate.unverified,
    EncryptionStatus.verified => AppGate.ready,
  };
});

/// Emoji verification of this device and of contacts; exists from sign-in on,
/// also before this device is verified.
final Provider<VerificationService?> verificationServiceProvider = Provider<VerificationService?>((ref) {
  final account = ref.watch(accountProvider.select((a) => a.value));
  if (account == null) return null;
  final api = ApiClient(account.serverUrl, token: account.token);
  final service = VerificationService(
    api: api,
    account: account,
    identity: EncryptionIdentity(api: api, account: account, store: ref.watch(secureStoreProvider)),
    onDeviceVerified: () => ref.read(encryptionProvider.notifier).deviceVerified(),
    // onUserVerified is set by chatRepositoryProvider, which depends on this one.
  );
  ref.onDispose(() {
    service.close();
    api.close();
  });
  return service;
});

final verificationsProvider = StreamProvider<List<Verification>>(
  (ref) => ref.watch(verificationServiceProvider)?.watch() ?? Stream.value(const []),
);

/// Directory for this device's MLS database; set in `main.dart`. Null keeps
/// MLS state in memory (tests).
final mlsDirProvider = Provider<Directory?>((ref) => null);

/// Shows notifications; set in `main.dart`. Null in tests.
final notificationDisplayProvider = Provider<NotificationDisplay?>((ref) => null);

/// Whether the user is looking at the app (focused window, app on screen).
final appForegroundProvider = NotifierProvider<AppForeground, bool>(AppForeground.new);

class AppForeground extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(onStateChange: (s) => state = s == AppLifecycleState.resumed);
    ref.onDispose(listener.dispose);
    final current = WidgetsBinding.instance.lifecycleState;
    return current == null || current == AppLifecycleState.resumed;
  }
}

/// Whether this engine keeps a live connection. Desktop apps stay connected,
/// also in the tray. Phones disconnect shortly after the app goes to the
/// background: the server then wakes them with pushes, which a frozen app
/// with a stale connection would miss.
final syncActiveProvider = NotifierProvider<SyncActive, bool>(SyncActive.new);

class SyncActive extends Notifier<bool> {
  /// Quick trips away (a file picker, a glance at another app) keep the connection.
  static const grace = Duration(seconds: 5);

  @override
  bool build() {
    if (!(Platform.isAndroid || Platform.isIOS)) return true;
    Timer? timer;
    var foreground = true;
    // Listened to, not watched: a rebuild would start over in the foreground.
    ref.listen(callHoldProvider, (_, held) => state = foreground || held);
    final listener = AppLifecycleListener(
      onStateChange: (s) {
        timer?.cancel();
        if (s == AppLifecycleState.resumed || s == AppLifecycleState.inactive) {
          foreground = true;
          state = true;
        } else {
          timer = Timer(grace, () {
            foreground = false;
            state = ref.read(callHoldProvider);
          });
        }
      },
    );
    ref.onDispose(() {
      timer?.cancel();
      listener.dispose();
    });
    return true;
  }
}

/// A call is ringing or going on: the app stays connected in the background
/// (see [SyncActive]), so the call's keys keep up with its group.
final callHoldProvider = NotifierProvider<CallHold, bool>(CallHold.new);

class CallHold extends Notifier<bool> {
  @override
  bool build() => false;

  void hold(bool held) => state = held;
}

/// Whether the user is using the app: input, or the app coming to the front,
/// within [UserActivity.idleAfter].
final userActivityProvider = NotifierProvider<UserActivity, bool>(UserActivity.new);

class UserActivity extends Notifier<bool> {
  static const idleAfter = Duration(minutes: 5);

  var _last = DateTime.now();
  Timer? _timer;

  @override
  bool build() {
    final lifecycle = AppLifecycleListener(onResume: _touch);
    void onPointer(PointerEvent _) => _touch();
    bool onKey(KeyEvent _) {
      _touch();
      return false;
    }

    GestureBinding.instance.pointerRouter.addGlobalRoute(onPointer);
    HardwareKeyboard.instance.addHandler(onKey);
    ref.onDispose(() {
      _timer?.cancel();
      lifecycle.dispose();
      GestureBinding.instance.pointerRouter.removeGlobalRoute(onPointer);
      HardwareKeyboard.instance.removeHandler(onKey);
    });
    _last = DateTime.now();
    _timer = Timer(idleAfter, _check);
    return true;
  }

  /// Cheap: it runs for every pointer move.
  void _touch() {
    _last = DateTime.now();
    if (!state) state = true;
    _timer ??= Timer(idleAfter, _check);
  }

  void _check() {
    _timer = null;
    final left = idleAfter - DateTime.now().difference(_last);
    if (left > Duration.zero) {
      _timer = Timer(left, _check);
    } else {
      state = false;
    }
  }
}

/// Keeps notifications in line with unread messages; null in tests.
final notificationCenterProvider = Provider<NotificationCenter?>((ref) {
  final notifier = ref.watch(notificationDisplayProvider);
  final account = ref.watch(accountProvider.select((a) => a.value));
  if (notifier == null || account == null) return null;
  return NotificationCenter(
    db: ref.watch(databaseProvider),
    me: account.userId,
    notifier: notifier,
    appInForeground: () => ref.read(appForegroundProvider),
    // Read when needed: the repository itself depends on this.
    pictureFile: (picture) => ref.read(chatRepositoryProvider).mediaFile(picture),
    appName: () => ref.read(activeThemeProvider).shownName,
  );
});

final Provider<ChatRepository> chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final account = ref.watch(accountProvider.select((a) => a.value));
  // Chats exist only once this device holds the encryption identity.
  if (account == null || ref.watch(appGateProvider) != AppGate.ready) return const SignedOutRepository();
  final mlsDir = ref.watch(mlsDirProvider);
  final verification = ref.watch(verificationServiceProvider);
  final repository = ServerChatRepository(
    db: ref.watch(databaseProvider),
    account: account,
    identity: ref.read(encryptionProvider.notifier).identity,
    onSignedOut: () => ref.read(accountProvider.notifier).signOut(notifyServer: false),
    mediaDir: ref.watch(mediaDirProvider),
    packsDir: ref.watch(stickerPacksDirProvider),
    tempDir: Directory('${Directory.systemTemp.path}/hanashi'),
    mlsDbPath: mlsDbPath(mlsDir, account.deviceId),
    probeVideo: ref.watch(videoProbeProvider),
    onSynced: ref.watch(notificationCenterProvider)?.update,
    onVerificationMessage: verification?.handle,
    // Reset elsewhere: checking again finds out, and asks to verify.
    onUnverified: () => ref.read(encryptionProvider.notifier).retry(),
  );
  verification?.onUserVerified = repository.markVerified;
  // Others see the user idle once none of their devices is in use.
  ref.listen(userActivityProvider, (_, active) => repository.setActive(active), fireImmediately: true);
  // In the background on a phone, the data stays readable but pushes do the syncing.
  if (ref.watch(syncActiveProvider)) repository.start();
  ref.onDispose(() {
    if (verification?.onUserVerified == repository.markVerified) verification?.onUserVerified = null;
    repository.dispose();
  });
  return repository;
});

/// The notifications the user tapped (see [NotificationOpen]). Set in
/// `main.dart`.
final notificationOpensProvider = Provider<Stream<NotificationOpen>>((ref) => const Stream.empty());

/// Once this device is ready: asks for notification permission (the first
/// time) and registers for pushes on Android. False if pushes are not set up.
final pushRegistrationProvider = FutureProvider<bool>((ref) async {
  final account = ref.watch(accountProvider.select((a) => a.value));
  final display = ref.watch(notificationDisplayProvider);
  if (account == null || display == null || ref.watch(appGateProvider) != AppGate.ready) return false;
  final db = ref.read(databaseProvider);
  if (await db.getValue(_permissionAskedKey) == null) {
    await db.setValue(_permissionAskedKey, 'yes');
    await display.requestPermission();
  }
  if (!PushService.supported) return false;
  final key = await ref.watch(vapidKeyProvider.future);
  return key != null && await PushService.register(vapidKey: key);
});

const _permissionAskedKey = 'notify.permission-asked';

/// What the user's server says of itself (`GET /server`); null signed out.
final serverInfoProvider = FutureProvider<ServerInfo?>((ref) async {
  final account = ref.watch(accountProvider.select((a) => a.value));
  if (account == null) return null;
  final api = ApiClient(account.serverUrl);
  try {
    return await api.serverInfo();
  } finally {
    api.close();
  }
});

/// The server's push key (null if it has none).
final vapidKeyProvider = FutureProvider<String?>((ref) async => (await ref.watch(serverInfoProvider.future))?.vapidKey);

final notificationPreferencesProvider = AsyncNotifierProvider<NotificationPreferencesController, NotificationPreferences>(
  NotificationPreferencesController.new,
);

class NotificationPreferencesController extends AsyncNotifier<NotificationPreferences> {
  @override
  Future<NotificationPreferences> build() => NotificationPreferences.load(ref.watch(databaseProvider));

  Future<void> save(NotificationPreferences preferences) async {
    await preferences.save(ref.read(databaseProvider));
    state = AsyncData(preferences);
    // Takes effect for notifications already shown, too.
    await ref.read(notificationCenterProvider)?.update();
  }
}

final connectionProvider = StreamProvider<ConnectionStatus>(
  (ref) => ref.watch(chatRepositoryProvider).watchConnection(),
);

/// Why the app is not online, if it knows.
final connectionProblemProvider = StreamProvider<String?>(
  (ref) => ref.watch(chatRepositoryProvider).watchConnectionProblem(),
);

final conversationsProvider = StreamProvider<List<ConversationSummary>>(
  (ref) => ref.watch(chatRepositoryProvider).watchConversations(),
);

final conversationProvider = Provider.family<ConversationSummary?, String>((ref, id) {
  final conversations = ref.watch(conversationsProvider).value ?? const [];
  return conversations.where((c) => c.id == id).firstOrNull;
});

/// Contacts the user verified.
final verifiedUsersProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(chatRepositoryProvider).watchVerifiedUsers(),
);

/// Users whose security key changed since this device pinned it.
final identityChangesProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(chatRepositoryProvider).watchIdentityChanges(),
);

/// Who else is typing in a conversation.
final typingProvider = StreamProvider.autoDispose.family<Set<String>, String>(
  (ref, conversationId) => ref.watch(chatRepositoryProvider).watchTyping(conversationId),
);

final messagesProvider = StreamProvider.autoDispose.family<List<ChatMessage>, String>(
  (ref, conversationId) => ref.watch(chatRepositoryProvider).watchMessages(conversationId),
);

/// The user's settings for each chat; chats without any are left out.
final chatSettingsProvider = StreamProvider<Map<String, ChatSettings>>(
  (ref) => ref.watch(chatRepositoryProvider).watchChatSettings(),
);

final chatSettingsOfProvider = Provider.family<ChatSettings, String>(
  (ref, conversationId) =>
      ref.watch(chatSettingsProvider.select((s) => s.value?[conversationId] ?? ChatSettings.empty)),
);

/// Everyone's status as last heard; anyone missing is offline.
final presenceProvider = StreamProvider<Map<String, Presence>>(
  (ref) => ref.watch(chatRepositoryProvider).watchPresence(),
);

/// One user's status.
final presenceOfProvider = Provider.family<Presence, String>(
  (ref, userId) => ref.watch(presenceProvider.select((p) => p.value?[userId] ?? Presence.offline)),
);

/// How the user chose to appear.
final presenceModeProvider = StreamProvider<PresenceMode>(
  (ref) => ref.watch(chatRepositoryProvider).watchPresenceMode(),
);

/// How the user stands with others (see [ContactState]).
final contactsProvider = StreamProvider<Map<String, ContactState>>(
  (ref) => ref.watch(chatRepositoryProvider).watchContacts(),
);

final profilesProvider = StreamProvider<Map<String, UserProfile>>(
  (ref) => ref
      .watch(chatRepositoryProvider)
      .watchProfiles()
      .map((profiles) => {for (final p in profiles) p.id: p}),
);

/// Unread messages, but not those of muted chats.
final totalUnreadProvider = Provider<int>((ref) {
  final conversations = ref.watch(conversationsProvider).value ?? const [];
  final settings = ref.watch(chatSettingsProvider).value ?? const {};
  final now = ref.watch(clockProvider)();
  return conversations.fold(0, (sum, c) => settings[c.id]?.mutedAt(now) ?? false ? sum : sum + c.unreadCount);
});

final devicesProvider = FutureProvider.autoDispose<List<DeviceInfo>>(
  (ref) => ref.watch(chatRepositoryProvider).devices(),
);

/// A local, decrypted copy of a media blob (null in demo mode). Keyed by
/// hash, key and where it is, so equal references share one download.
final mediaFileProvider = FutureProvider.autoDispose.family<File?, ({String hash, String? key, String? host})>(
  (ref, media) => ref
      .watch(chatRepositoryProvider)
      .mediaFile(
        MediaRef(hash: media.hash, size: 0, mime: 'application/octet-stream', key: media.key, host: media.host),
      ),
);

/// The provider argument for [media].
({String hash, String? key, String? host}) mediaFileKey(MediaRef media) =>
    (hash: media.hash, key: media.key, host: media.host);

/// GIF search for the GIF tab: KLIPY with the server's key, called from this
/// device. Null when the server has no key.
final gifSearchProvider = FutureProvider<GifSearch?>((ref) async {
  final key = await ref.watch(chatRepositoryProvider).klipyApiKey();
  if (key == null) return null;
  final country = WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  final search = KlipyGifSearch(key, locale: country?.toLowerCase());
  ref.onDispose(search.close);
  return search;
}, retry: (_, _) => null); // The GIF tab offers to try again.

/// Loads GIFs from KLIPY, keeping them in memory only.
final remoteMediaLoaderProvider = Provider<RemoteMediaLoader>((ref) {
  final loader = RemoteMediaLoader();
  ref.onDispose(loader.close);
  return loader;
});

final savedGifsProvider = StreamProvider<List<GifRef>>(
  (ref) => ref.watch(chatRepositoryProvider).watchSavedGifs(),
);

/// The user's stickers (see `ChatRepository.watchSavedStickers`).
final savedStickersProvider = StreamProvider<List<StickerRef>>(
  (ref) => ref.watch(chatRepositoryProvider).watchSavedStickers(),
);

/// The sticker packs the user keeps (see `ChatRepository.watchStickerPacks`).
final stickerPacksProvider = StreamProvider<List<StickerPack>>(
  (ref) => ref.watch(chatRepositoryProvider).watchStickerPacks(),
);

/// The user's own custom emojis, by name (see `ChatRepository.watchEmojis`).
final myEmojisProvider = StreamProvider<Map<String, MediaRef>>(
  (ref) => ref.watch(chatRepositoryProvider).watchEmojis(),
);

/// A group's custom emojis, by name.
final groupEmojisProvider = StreamProvider.family<Map<String, MediaRef>, String>(
  (ref, conversationId) => ref.watch(chatRepositoryProvider).watchEmojis(conversationId: conversationId),
);

/// What `:name:` stands for, written in a chat: the group's emoji of that
/// name, or else the user's own (as sending a message decides).
final chatEmojisProvider = Provider.family<Map<String, MediaRef>, String>(
  (ref, conversationId) => {
    ...?ref.watch(myEmojisProvider).value,
    ...?ref.watch(groupEmojisProvider(conversationId)).value,
  },
);

/// Whether the server carries voice calls.
final callsAvailableProvider = FutureProvider<bool>((ref) => ref.watch(chatRepositoryProvider).callsAvailable());

/// Whether calls may carry cameras and shared screens (see
/// [ChatRepository.videoAvailable]).
final videoAvailableProvider = FutureProvider<bool>((ref) => ref.watch(chatRepositoryProvider).videoAvailable());

/// The calls of the user's conversations, by ID (see
/// `ChatRepository.watchCalls`).
final callsProvider = StreamProvider<Map<String, Call>>((ref) => ref.watch(chatRepositoryProvider).watchCalls());

/// Whether GIFs from KLIPY in chats load by themselves; if not, a tap loads
/// one. (KLIPY sees the IP address of whoever loads a GIF.)
final gifAutoLoadProvider = AsyncNotifierProvider<GifAutoLoadController, bool>(GifAutoLoadController.new);

class GifAutoLoadController extends AsyncNotifier<bool> {
  static const _key = 'gifs.autoload';

  @override
  Future<bool> build() async => await ref.watch(databaseProvider).getValue(_key) != 'false';

  Future<void> set(bool autoLoad) async {
    await ref.read(databaseProvider).setValue(_key, autoLoad ? null : 'false');
    state = AsyncData(autoLoad);
  }
}

/// The themes of this device and how it shows the app (see [ThemeLibrary]):
/// read in `main.dart` before the first frame; the built-in ones only, kept
/// in memory, unless overridden (tests).
final themeLibraryProvider = Provider<ThemeLibrary>((ref) => ThemeLibrary.load(null));

/// Which theme this device shows, and whether light or dark (see
/// [Appearance]).
final appearanceProvider = NotifierProvider<AppearanceController, Appearance>(AppearanceController.new);

class AppearanceController extends Notifier<Appearance> {
  @override
  Appearance build() => ref.watch(themeLibraryProvider).appearance;

  Future<void> setTheme(String id) => _set(state.copyWith(themeId: id));

  Future<void> setMode(ThemeMode mode) => _set(state.copyWith(mode: mode));

  /// Shown at once; kept once written.
  Future<void> _set(Appearance appearance) async {
    state = appearance;
    await ref.read(themeLibraryProvider).setAppearance(appearance);
  }

  /// As the library has it now (after a theme went, say).
  void sync() => state = ref.read(themeLibraryProvider).appearance;
}

/// Every theme on this device, the built-in ones first.
final themesProvider = NotifierProvider<ThemesController, List<AppTheme>>(ThemesController.new);

class ThemesController extends Notifier<List<AppTheme>> {
  @override
  List<AppTheme> build() => ref.watch(themeLibraryProvider).themes;

  ThemeLibrary get _library => ref.read(themeLibraryProvider);

  /// Adds a theme file (see [ThemeLibrary.import]) and shows it.
  Future<AppTheme> import(String path, {bool replace = false}) async {
    final theme = await _library.import(path, replace: replace);
    state = _library.themes;
    await ref.read(appearanceProvider.notifier).setTheme(theme.id);
    return theme;
  }

  /// Lets an imported theme go (see [ThemeLibrary.remove]).
  Future<void> remove(String id) async {
    await _library.remove(id);
    state = _library.themes;
    ref.read(appearanceProvider.notifier).sync();
  }
}

/// The theme shown.
final activeThemeProvider = Provider<AppTheme>((ref) {
  final themes = ref.watch(themesProvider);
  final id = ref.watch(appearanceProvider.select((appearance) => appearance.themeId));
  return themes.where((theme) => theme.id == id).firstOrNull ?? ref.read(themeLibraryProvider).active;
});

/// The theme shown, made into Flutter's: once per theme, so that the app's
/// rebuilds do not start its change over again.
final themeDataProvider = Provider<({ThemeData light, ThemeData dark})>(
  (ref) => themeDataOf(ref.watch(activeThemeProvider)),
);

/// What decides whether this device's notifications can play a theme's own
/// sound file (Android's API level); set in `main.dart`.
final soundPlatformProvider = Provider<SoundPlatform>((ref) => const SoundPlatform());

/// The app on a phone's home screen as the theme shown has it (see
/// [ThemeLauncher]); a fake in tests.
final themeLauncherProvider = Provider<ThemeLauncher>((ref) => const ThemeLauncher());

/// How notifications sound and look, from the theme shown.
final notificationLookProvider = Provider<NotificationLook>(
  (ref) => notificationLookOf(ref.watch(activeThemeProvider), ref.watch(soundPlatformProvider)),
);

/// How chat bubbles are set on this device: text size, line spacing and
/// padding (see [BubbleLook]).
final bubbleLookProvider = AsyncNotifierProvider<BubbleLookController, BubbleLook>(BubbleLookController.new);

class BubbleLookController extends AsyncNotifier<BubbleLook> {
  static const _textSizeKey = 'chat.text_size';
  static const _lineSpacingKey = 'chat.line_spacing';
  static const _paddingKey = 'chat.padding';

  @override
  Future<BubbleLook> build() async {
    final db = ref.watch(databaseProvider);
    Future<double?> read(String key, ({double min, double max, double step}) range) async =>
        BubbleLook.fit(double.tryParse(await db.getValue(key) ?? ''), range);
    return BubbleLook(
      textSize: await read(_textSizeKey, BubbleLook.textSizes) ?? BubbleLook.defaultTextSize,
      lineSpacing: await read(_lineSpacingKey, BubbleLook.lineSpacings) ?? BubbleLook.defaultLineSpacing,
      padding: await read(_paddingKey, BubbleLook.paddings) ?? BubbleLook.defaultPadding,
    );
  }

  /// Keeps [look]; what is the default is stored as nothing.
  Future<void> set(BubbleLook look) async {
    final db = ref.read(databaseProvider);
    Future<void> write(String key, double value, double fallback) =>
        db.setValue(key, value == fallback ? null : '$value');
    await write(_textSizeKey, look.textSize, BubbleLook.defaultTextSize);
    await write(_lineSpacingKey, look.lineSpacing, BubbleLook.defaultLineSpacing);
    await write(_paddingKey, look.padding, BubbleLook.defaultPadding);
    state = AsyncData(look);
  }
}

/// Makes previews of links the user is about to send.
final linkPreviewFetcherProvider = Provider<LinkPreviewFetcher>((ref) {
  final fetcher = LinkPreviewFetcher(probeVideo: ref.watch(videoProbeProvider));
  ref.onDispose(fetcher.close);
  return fetcher;
});

/// Whether links get a preview before they are sent. (The site sees the
/// sender's IP address; those who receive the message do not contact it,
/// unless they choose to: see [linkSourcesProvider].)
final linkPreviewsProvider = AsyncNotifierProvider<LinkPreviewsController, bool>(LinkPreviewsController.new);

class LinkPreviewsController extends AsyncNotifier<bool> {
  static const _key = 'links.previews';

  @override
  Future<bool> build() async => await ref.watch(databaseProvider).getValue(_key) != 'false';

  Future<void> set(bool previews) async {
    await ref.read(databaseProvider).setValue(_key, previews ? null : 'false');
    state = AsyncData(previews);
  }
}

/// Whether a link's video or GIF that did not come with the message can be
/// loaded from its site in the viewer, after asking. (The site then sees the
/// IP address of whoever loads it.) Off unless the user turns it on.
final linkSourcesProvider = AsyncNotifierProvider<LinkSourcesController, bool>(LinkSourcesController.new);

class LinkSourcesController extends AsyncNotifier<bool> {
  static const _key = 'links.sources';

  @override
  Future<bool> build() async => await ref.watch(databaseProvider).getValue(_key) == 'true';

  Future<void> set(bool load) async {
    await ref.read(databaseProvider).setValue(_key, load ? 'true' : null);
    state = AsyncData(load);
  }
}

/// Whether the others in a chat see that the user is typing (from this
/// device). Seeing them type does not depend on it.
final typingNotificationsProvider = AsyncNotifierProvider<TypingNotificationsController, bool>(
  TypingNotificationsController.new,
);

class TypingNotificationsController extends AsyncNotifier<bool> {
  static const _key = 'privacy.typing';

  @override
  Future<bool> build() async => await ref.watch(databaseProvider).getValue(_key) != 'false';

  Future<void> set(bool send) async {
    await ref.read(databaseProvider).setValue(_key, send ? null : 'false');
    state = AsyncData(send);
  }
}

/// How much goes into the app's log on this device (see [AppLog]).
final logLevelProvider = NotifierProvider<LogLevelController, LogLevel>(LogLevelController.new);

class LogLevelController extends Notifier<LogLevel> {
  @override
  LogLevel build() => AppLog.instance.level;

  Future<void> set(LogLevel level) async {
    await AppLog.instance.setLevel(level);
    _log.info('Log level ${level.name}');
    state = level;
  }
}

/// Opens a link in the browser (or the app for it); false if nothing could.
final openLinkProvider = Provider<Future<bool> Function(Uri url)>(
  (ref) => (url) => launchUrl(url, mode: LaunchMode.externalApplication),
);

/// The emoji the user reacted with lately, most recent first, as this device
/// remembers them. The quick reactions show them before the defaults.
final recentReactionsProvider = NotifierProvider<RecentReactions, List<String>>(RecentReactions.new);

class RecentReactions extends Notifier<List<String>> {
  static const _key = 'reactions.recent';

  /// As many as the quick reactions show.
  static const keep = 6;

  @override
  List<String> build() {
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    try {
      final saved = await ref.read(databaseProvider).getValue(_key);
      if (saved == null || state.isNotEmpty) return;
      state = [for (final emoji in jsonDecode(saved) as List) ?(emoji is String ? emoji : null)];
    } on Object {
      // Nothing remembered (or no database, as in widget tests).
    }
  }

  /// [emoji] was just used: it comes first.
  void use(String emoji) {
    state = [emoji, ...state.where((e) => e != emoji)].take(keep).toList();
    unawaited(_save(state));
  }

  Future<void> _save(List<String> recent) async {
    try {
      await ref.read(databaseProvider).setValue(_key, jsonEncode(recent));
    } on Object {
      // Remembered until the app restarts.
    }
  }
}
