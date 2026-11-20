// Encryption identity against the real Go server: setup, recovery-key
// verification of new devices, new recovery keys and resets.
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/account.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi/e2ee/encryption_identity.dart';
import 'package:hanashi/e2ee/primitives.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:openmls/openmls.dart';

import '../support/go_server.dart';

Future<EncryptionIdentity> device(GoServer server, String name, {bool register = false}) async {
  final anonymous = ApiClient(server.url);
  final auth = register
      ? await anonymous.register(name: name, password: 'password123', deviceName: 'test', platform: 'test')
      : await anonymous.login(name: name, password: 'password123', deviceName: 'test', platform: 'test');
  anonymous.close();
  final api = ApiClient(server.url, token: auth.token);
  addTearDown(api.close);
  return EncryptionIdentity(
    api: api,
    account: Account(
      serverUrl: server.url,
      userId: auth.userId,
      displayName: name,
      token: auth.token,
      deviceId: auth.deviceId,
    ),
    store: MemorySecureStore(),
  );
}

Future<bool> verifiedOnServer(EncryptionIdentity d) async {
  final keys = await d.api.userKeys(d.account.userId);
  final me = keys.devices.singleWhere((x) => x.deviceId == d.account.deviceId);
  return isDeviceVerified(identityKey: keys.identityKey!, userId: d.account.userId, device: me);
}

void main() {
  late GoServer server;
  setUpAll(() async {
    await Openmls.init();
    server = await GoServer.start();
  });
  tearDownAll(() => server.dispose());

  test('first device sets up; later devices verify with the recovery key', () async {
    final phone = await device(server, 'alice', register: true);
    expect(await phone.status(), EncryptionStatus.needsSetup);
    final recoveryKey = await phone.setUp();
    expect(await phone.status(), EncryptionStatus.verified);
    expect(await verifiedOnServer(phone), isTrue);

    final laptop = await device(server, 'alice');
    expect(await laptop.status(), EncryptionStatus.unverified);
    expect(await verifiedOnServer(laptop), isFalse);

    await expectLater(
      laptop.verifyWithRecoveryKey(RecoveryKey.generate()),
      throwsA(isA<VerificationException>()),
    );
    await laptop.verifyWithRecoveryKey(await RecoveryKey.parse(await recoveryKey.encode()));
    expect(await laptop.status(), EncryptionStatus.verified);
    expect(await verifiedOnServer(laptop), isTrue);
    expect((await laptop.localSecrets())!.backupSecret, (await phone.localSecrets())!.backupSecret);
  });

  test('a new recovery key replaces the old one', () async {
    final phone = await device(server, 'bob', register: true);
    final first = await phone.setUp();
    final second = await phone.newRecoveryKey();
    final laptop = await device(server, 'bob');
    await expectLater(laptop.verifyWithRecoveryKey(first), throwsA(isA<VerificationException>()));
    await laptop.verifyWithRecoveryKey(second);
    expect(await laptop.status(), EncryptionStatus.verified);
  });

  test('resetting on one device un-verifies the others', () async {
    final phone = await device(server, 'carol', register: true);
    final oldKey = await phone.setUp();
    final laptop = await device(server, 'carol');
    await laptop.verifyWithRecoveryKey(oldKey);

    final newKey = await laptop.setUp(reset: true);
    expect(await laptop.status(), EncryptionStatus.verified);
    expect(await phone.status(), EncryptionStatus.unverified);
    expect(await phone.localSecrets(), isNull);
    await expectLater(phone.verifyWithRecoveryKey(oldKey), throwsA(isA<VerificationException>()));
    await phone.verifyWithRecoveryKey(newKey);
    expect(await phone.status(), EncryptionStatus.verified);
  });

  test('setting up again without reset is refused', () async {
    final phone = await device(server, 'dave', register: true);
    await phone.setUp();
    final laptop = await device(server, 'dave');
    await expectLater(laptop.setUp(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'identity_exists')));
  });
}
