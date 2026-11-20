import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../data/account.dart';
import '../data/remote/api_client.dart';
import '../diagnostics/app_log.dart';
import 'primitives.dart';
import 'secure_store.dart';

const _log = Log('keys');

/// The MLS ciphersuite Hanashi uses: X25519, AES-128-GCM, SHA-256, Ed25519.
const mlsCiphersuite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;

enum EncryptionStatus {
  /// The account has no encryption identity yet.
  needsSetup,

  /// The account has one, but this device has not been verified.
  unverified,

  /// This device holds the identity and is cross-signed.
  verified,
}

/// This device's MLS signing key.
class DeviceSigner {
  const DeviceSigner({required this.signerBytes, required this.publicKey});

  /// Serialized signer for openmls calls.
  final Uint8List signerBytes;
  final Uint8List publicKey;

  String get publicKeyBase64 => base64.encode(publicKey);
}

/// Thrown when verification cannot proceed; [message] is user-facing.
class VerificationException implements Exception {
  const VerificationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The account's encryption identity as seen from this device: setting it
/// up, verifying this device, recovery keys and resets.
class EncryptionIdentity {
  EncryptionIdentity({required this.api, required this.account, required this.store});

  final ApiClient api;
  final Account account;
  final SecureStore store;

  String _key(String name) => 'device.${account.deviceId}.$name';

  /// This device's MLS signing key, created on first use and kept in secure storage.
  Future<DeviceSigner> deviceSigner() async {
    final signer = await store.read(_key('mlsSigner'));
    final publicKey = await store.read(_key('mlsPublicKey'));
    if (signer != null && publicKey != null) {
      return DeviceSigner(signerBytes: base64.decode(signer), publicKey: base64.decode(publicKey));
    }
    final keyPair = MlsSignatureKeyPair.generate(ciphersuite: mlsCiphersuite);
    final created = DeviceSigner(
      signerBytes: serializeSigner(
        ciphersuite: mlsCiphersuite,
        privateKey: keyPair.privateKey(),
        publicKey: keyPair.publicKey(),
      ),
      publicKey: keyPair.publicKey(),
    );
    await store.write(_key('mlsSigner'), base64.encode(created.signerBytes));
    await store.write(_key('mlsPublicKey'), created.publicKeyBase64);
    return created;
  }

  /// Key of this device's encrypted MLS database, created on first use.
  Future<Uint8List> mlsDatabaseKey() async {
    final stored = await store.read(_key('mlsDbKey'));
    if (stored != null) return base64.decode(stored);
    final key = randomBytes(32);
    await store.write(_key('mlsDbKey'), base64.encode(key));
    return key;
  }

  /// The identity and backup secrets, present only on a verified device.
  Future<AccountSecrets?> localSecrets() async {
    final json = await store.read(_key('secrets'));
    return json == null ? null : AccountSecrets.fromJson(json);
  }

  Future<IdentityKeyPair?> localIdentity() async {
    final secrets = await localSecrets();
    return secrets == null ? null : IdentityKeyPair.fromSeed(secrets.identitySeed);
  }

  /// Registers this device's key and works out where it stands.
  Future<EncryptionStatus> status() async {
    final signer = await deviceSigner();
    await api.putDeviceKey(signer.publicKeyBase64);
    final keys = await api.userKeys(account.userId);
    final identityKey = keys.identityKey;
    if (identityKey == null) return EncryptionStatus.needsSetup;
    final identity = await localIdentity();
    if (identity == null) {
      _log.info('This device is not verified yet (account key version ${keys.identityVersion})');
      return EncryptionStatus.unverified;
    }
    if (identity.publicKeyBase64 != identityKey) {
      // The identity was reset on another device; what we hold is void.
      _log.warning(
        'The account was reset elsewhere (key version ${keys.identityVersion}): this device must verify again',
      );
      await store.delete(_key('secrets'));
      return EncryptionStatus.unverified;
    }
    final me = keys.devices.where((d) => d.deviceId == account.deviceId).firstOrNull;
    if (me == null || !await isDeviceVerified(identityKey: identityKey, userId: account.userId, device: me)) {
      _log.info('Signing this device again with the account key');
      await _signThisDevice(identity, signer);
    }
    _log.debug('This device is verified (account key version ${keys.identityVersion})');
    return EncryptionStatus.verified;
  }

  Future<void> _signThisDevice(IdentityKeyPair identity, DeviceSigner signer) async {
    // The server only accepts signatures for registered keys (idempotent).
    await api.putDeviceKey(signer.publicKeyBase64);
    final signature = await identity.signDevice(
      userId: account.userId,
      deviceId: account.deviceId,
      mlsSigKey: signer.publicKeyBase64,
    );
    await api.putDeviceSignature(account.deviceId, signature);
  }

  /// Creates a new identity (first setup, or [reset] to replace a lost one)
  /// and returns the recovery key, which the user must see exactly once.
  /// Resetting leaves the user's other devices unverified.
  Future<RecoveryKey> setUp({bool reset = false}) async {
    final secrets = AccountSecrets.generate();
    final identity = await IdentityKeyPair.fromSeed(secrets.identitySeed);
    final signer = await deviceSigner();
    final version = await api.putIdentity(identity.publicKeyBase64, reset: reset);
    _log.info(reset ? 'Reset the account key: now version $version' : 'Set up the account key');
    await store.write(_key('secrets'), secrets.toJson());
    await _signThisDevice(identity, signer);
    return _storeRecoveryKey(secrets, version);
  }

  Future<RecoveryKey> _storeRecoveryKey(AccountSecrets secrets, int identityVersion) async {
    final recoveryKey = RecoveryKey.generate();
    await api.putSecretStorage(await sealSecrets(recoveryKey, account.userId, secrets), identityVersion);
    return recoveryKey;
  }

  /// Verifies this device with the recovery key. Throws
  /// [VerificationException] with a user-facing message on failure.
  Future<void> verifyWithRecoveryKey(RecoveryKey recoveryKey) async {
    final stored = await api.secretStorage();
    if (stored == null) {
      throw const VerificationException(
        'This account has no recovery data on the server. Verify with another device, or reset encryption.',
      );
    }
    final AccountSecrets secrets;
    try {
      secrets = await openSecrets(recoveryKey, account.userId, stored.data);
    } on DecryptionFailed {
      _log.info('Verifying with a recovery key failed: not the right key');
      throw const VerificationException('That recovery key does not belong to this account.');
    }
    await adoptSecrets(secrets, staleMessage: 'The recovery data is out of date. Reset encryption to continue.');
  }

  /// Verifies this device with secrets from the recovery key or from
  /// another device: they must belong to the account's current identity.
  Future<void> adoptSecrets(
    AccountSecrets secrets, {
    String staleMessage = 'Those keys are out of date. Verify again.',
  }) async {
    final identity = await IdentityKeyPair.fromSeed(secrets.identitySeed);
    final keys = await api.userKeys(account.userId);
    if (keys.identityKey != identity.publicKeyBase64) {
      _log.info('Verifying failed: the keys are for an earlier account key (now version ${keys.identityVersion})');
      throw VerificationException(staleMessage);
    }
    await store.write(_key('secrets'), secrets.toJson());
    await _signThisDevice(identity, await deviceSigner());
    _log.info('This device is verified now (account key version ${keys.identityVersion})');
  }

  /// Replaces the recovery key (e.g. the old one was lost). Only on a
  /// verified device; the old key stops working.
  Future<RecoveryKey> newRecoveryKey() async {
    final secrets = await localSecrets();
    if (secrets == null) throw const VerificationException('Verify this device first.');
    final keys = await api.userKeys(account.userId);
    return _storeRecoveryKey(secrets, keys.identityVersion!);
  }

  /// Forgets everything this device holds (on sign-out).
  Future<void> forget() => store.deleteAll(prefix: 'device.${account.deviceId}.');
}
