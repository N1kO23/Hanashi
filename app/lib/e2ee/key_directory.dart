import '../data/local/database.dart';
import '../data/remote/api_client.dart';
import '../diagnostics/app_log.dart';
import 'primitives.dart';

const _log = Log('keys');

/// A user's devices that are cross-signed by the identity key this device
/// trusts for them.
class TrustedDevices {
  const TrustedDevices({required this.userId, required this.devices, this.identityKey, this.identityChanged = false});

  final String userId;

  /// The pinned identity key; null if the user has not set up encryption.
  final String? identityKey;

  /// The server shows a different identity key than the pinned one. Until the
  /// user accepts it, none of the user's devices are trusted.
  final bool identityChanged;

  /// Device ID -> base64 MLS signature key, for verified devices only.
  final Map<String, String> devices;
}

/// Looks up and verifies users' device keys. Identity keys are pinned the
/// first time they are seen (trust on first use); our own comes from the
/// secrets this verified device holds.
class KeyDirectory {
  KeyDirectory({required this.api, required this.db, required this.me, required this.ownIdentityKey});

  final ApiClient api;
  final AppDatabase db;
  final String me;
  final String ownIdentityKey;
  final _cache = <String, Future<TrustedDevices>>{};

  void invalidate(String userId) => _cache.remove(userId);

  Future<TrustedDevices> devicesOf(String userId) {
    final cached = _cache[userId];
    if (cached != null) return cached;
    final future = _load(userId);
    _cache[userId] = future;
    // Don't cache failures (e.g. offline).
    future.catchError((Object _) {
      _cache.remove(userId);
      return TrustedDevices(userId: userId, devices: const {});
    });
    return future;
  }

  Future<TrustedDevices> _load(String userId) async {
    final keys = await api.userKeys(userId);
    final published = keys.identityKey;
    if (published == null) {
      return TrustedDevices(userId: userId, devices: const {});
    }

    String trusted;
    var changed = false;
    if (userId == me) {
      trusted = ownIdentityKey;
      changed = published != ownIdentityKey;
      if (changed) _log.warning("This account's key on the server is not the one this device holds: reset elsewhere?");
    } else {
      final pin = await db.pinnedIdentity(userId);
      if (pin == null) {
        _log.info('First saw the key of $userId (version ${keys.identityVersion})');
        await db.pinIdentity(userId, published);
        trusted = published;
      } else {
        trusted = pin.identityKey;
        if (published != trusted) {
          if (pin.verifiedKey == trusted) {
            // A contact the user verified: they decide (accept or verify
            // again); until then nothing is sent to that user.
            changed = true;
            if (pin.changedTo != published) {
              _log.warning(
                "$userId's verified key changed (version ${keys.identityVersion}): sending waits for the user",
              );
              await db.markIdentityChanged(userId, published);
            }
          } else {
            // Trusted on first use only: take the new key, and say so in
            // the chats with them.
            _log.info("$userId's key changed (version ${keys.identityVersion}): taking it, with a notice");
            await db.pinIdentity(userId, published);
            await db.addKeyChangeNotice(userId);
            trusted = published;
          }
        }
      }
    }
    final devices = <String, String>{};
    if (!changed) {
      for (final device in keys.devices) {
        if (await isDeviceVerified(identityKey: trusted, userId: userId, device: device)) {
          devices[device.deviceId] = device.mlsSigKey;
        }
      }
    }
    _log.debug(
      'Keys of $userId: version ${keys.identityVersion}${changed ? ' (changed)' : ''}, '
      '${devices.length} of ${keys.devices.length} devices verified: ${devices.keys.join(', ')}',
    );
    return TrustedDevices(userId: userId, identityKey: trusted, identityChanged: changed, devices: devices);
  }

  /// Trusts the user's new identity key (after a reset on their side).
  Future<void> acceptIdentityChange(String userId) async {
    final pin = await db.pinnedIdentity(userId);
    final changedTo = pin?.changedTo;
    if (changedTo != null) await db.pinIdentity(userId, changedTo);
    invalidate(userId);
  }
}
