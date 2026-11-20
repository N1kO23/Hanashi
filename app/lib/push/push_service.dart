import 'dart:async';
import 'dart:io';

import 'package:unifiedpush_platform_interface/data/push_endpoint.dart';
import 'package:unifiedpush_platform_interface/unifiedpush_platform_interface.dart';

import '../data/account.dart';
import '../data/remote/api_client.dart';
import '../diagnostics/app_log.dart';
import '../e2ee/secure_store.dart';
import 'call_push.dart';

const _log = Log('push');

/// Wakes the Android app for new messages while it is closed, with
/// UnifiedPush: the user's distributor app (such as ntfy), or else the
/// FCM distributor built into the app, which needs Google Play services but
/// no Firebase project. Pushes about messages carry no content; they only
/// make the app sync (see `background_sync.dart`). Pushes about calls say
/// which call rings, or stops ringing (see `call_push.dart`).
///
/// Uses the Android implementation directly rather than the `unifiedpush`
/// package, whose Linux part brings a BoringSSL build into every platform's
/// build (desktops sync over their open connection instead).
abstract final class PushService {
  static bool get supported => Platform.isAndroid;

  static UnifiedPushPlatform get _push => UnifiedPushPlatform.instance;

  /// The app registers one endpoint.
  static const _instance = 'default';

  /// The built-in FCM distributor is the app itself.
  static const builtInDistributor = 'app.nullpointr.hanashi';

  /// Hooks up push callbacks. Runs in the app and in the headless engine
  /// Android starts for a push while the app is closed. [onCall] gets the
  /// pushes about calls, [onWake] the others. [onRegistered] gets each
  /// endpoint once the server knows it.
  static Future<void> initialize({
    required SecureStore store,
    required Future<void> Function() onWake,
    required void Function(CallPush push) onCall,
    void Function(String endpoint)? onRegistered,
  }) async {
    if (!supported) return;
    await _push.initializeCallback(
      onNewEndpoint: (endpoint, _) async {
        if (await _upload(store, endpoint)) onRegistered?.call(endpoint.url);
      },
      onMessage: (message, _) {
        final call = message.decrypted ? CallPush.parse(message.content) : null;
        if (call != null) {
          onCall(call);
        } else {
          unawaited(onWake());
        }
      },
      onUnregistered: (_) => unawaited(_forget(store)),
      onRegistrationFailed: (reason, _) => _log.warning('Push registration failed: $reason'),
    );
  }

  /// Registers with the saved or default distributor, or picks one: a
  /// distributor app the user installed before the built-in one. Call at
  /// every start. Returns false if there is no distributor at all. The
  /// endpoint arrives later (see [initialize]); only then does [current]
  /// name the distributor.
  static Future<bool> register({required String vapidKey}) async {
    if (!supported) return false;
    if (!await _push.tryUseCurrentOrDefaultDistributor()) {
      final available = await _push.getDistributors(const []);
      final choice =
          available.where((d) => d != builtInDistributor).firstOrNull ??
          (available.contains(builtInDistributor) ? builtInDistributor : null);
      if (choice == null) return false;
      await _push.saveDistributor(choice);
    }
    await _push.register(_instance, const [], null, vapidKey);
    return true;
  }

  /// Switches to [distributor] (one of [distributors]).
  static Future<void> use(String distributor, {required String vapidKey}) async {
    if (await _push.getDistributor() == distributor) return;
    await _push.unregister(_instance);
    await _push.saveDistributor(distributor);
    await _push.register(_instance, const [], null, vapidKey);
  }

  static Future<List<String>> distributors() async => supported ? _push.getDistributors(const []) : const [];

  /// The distributor that confirmed the registration.
  static Future<String?> current() async => supported ? _push.getDistributor() : null;

  /// Stops pushes, e.g. when signing out.
  static Future<void> unregister() async {
    if (supported) await _push.unregister(_instance);
  }

  static Future<bool> _upload(SecureStore store, PushEndpoint endpoint) async {
    final account = await Account.read(store);
    if (account == null) return false;
    final keys = endpoint.pubKeySet;
    final api = ApiClient(account.serverUrl, token: account.token);
    try {
      await api.putPushSubscription(
        endpoint: endpoint.url,
        p256dh: keys == null ? null : _base64UrlNoPadding(keys.pubKey),
        auth: keys == null ? null : _base64UrlNoPadding(keys.auth),
      );
      return true;
    } on ApiException catch (e) {
      // Uploaded again on the next start, when the distributor repeats it.
      _log.warning('Could not register for push', e);
      return false;
    } finally {
      api.close();
    }
  }

  static Future<void> _forget(SecureStore store) async {
    final account = await Account.read(store);
    if (account == null) return;
    final api = ApiClient(account.serverUrl, token: account.token);
    try {
      await api.deletePushSubscription();
    } on ApiException {
      // The server forgets it when a push to it fails.
    } finally {
      api.close();
    }
  }

  static String _base64UrlNoPadding(String key) =>
      key.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}
