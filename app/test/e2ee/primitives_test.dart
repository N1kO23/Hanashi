import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/primitives.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

void main() {
  group('AEAD', () {
    test('round-trips and binds the associated data', () async {
      final key = randomBytes(32);
      final sealed = await aeadSeal(key, utf8.encode('hello'), aad: utf8.encode('msg-1'));
      expect(utf8.decode(await aeadOpen(key, sealed, aad: utf8.encode('msg-1'))), 'hello');
      await expectLater(aeadOpen(key, sealed, aad: utf8.encode('msg-2')), throwsA(isA<DecryptionFailed>()));
      await expectLater(aeadOpen(randomBytes(32), sealed, aad: utf8.encode('msg-1')), throwsA(isA<DecryptionFailed>()));
      final tampered = [...sealed]..[20] ^= 1;
      await expectLater(aeadOpen(key, tampered, aad: utf8.encode('msg-1')), throwsA(isA<DecryptionFailed>()));
    });

    test('uses a fresh nonce each time', () async {
      final key = randomBytes(32);
      expect(await aeadSeal(key, [1, 2, 3]), isNot(await aeadSeal(key, [1, 2, 3])));
    });
  });

  group('RecoveryKey', () {
    test('encodes to grouped base32 and parses back', () async {
      final key = RecoveryKey.generate();
      final text = await key.encode();
      expect(text, matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4} ){13}[0-9A-HJKMNP-TV-Z]{3}$')));
      expect((await RecoveryKey.parse(text)).bytes, key.bytes);
      // Forgiving input: lower case, dashes, no spaces, O for 0.
      final sloppy = text.toLowerCase().replaceAll(' ', '-').replaceAll('0', 'o');
      expect((await RecoveryKey.parse(sloppy)).bytes, key.bytes);
    });

    test('rejects typos', () async {
      final text = await RecoveryKey.generate().encode();
      final typo = text.replaceRange(0, 1, text[0] == 'A' ? 'B' : 'A');
      await expectLater(RecoveryKey.parse(typo), throwsFormatException);
      await expectLater(RecoveryKey.parse(text.substring(5)), throwsFormatException);
      await expectLater(RecoveryKey.parse('${text}U'), throwsFormatException);
    });
  });

  group('secret storage', () {
    test('opens only with the right recovery key and user', () async {
      final recovery = RecoveryKey.generate();
      final secrets = AccountSecrets.generate();
      final blob = await sealSecrets(recovery, 'a@x', secrets);
      expect(blob, isNot(contains(base64.encode(secrets.identitySeed))));
      final opened = await openSecrets(recovery, 'a@x', blob);
      expect(opened.identitySeed, secrets.identitySeed);
      expect(opened.backupSecret, secrets.backupSecret);
      await expectLater(openSecrets(RecoveryKey.generate(), 'a@x', blob), throwsA(isA<DecryptionFailed>()));
      // A blob copied to another account does not open there.
      await expectLater(openSecrets(recovery, 'b@x', blob), throwsA(isA<DecryptionFailed>()));
    });
  });

  group('identity', () {
    test('device signatures verify only for the signed record', () async {
      final identity = await IdentityKeyPair.fromSeed(randomBytes(32));
      final device = DeviceKeyInfo(
        deviceId: '01JB2Y8Q3M7W2V6T0Q9X4C5D6E',
        mlsSigKey: base64.encode(randomBytes(32)),
        signature: await identity.signDevice(userId: 'a@x', deviceId: '01JB2Y8Q3M7W2V6T0Q9X4C5D6E', mlsSigKey: ''),
      );
      // Signed for a different key than the device presents.
      expect(await isDeviceVerified(identityKey: identity.publicKeyBase64, userId: 'a@x', device: device), isFalse);

      final good = DeviceKeyInfo(
        deviceId: device.deviceId,
        mlsSigKey: device.mlsSigKey,
        signature: await identity.signDevice(userId: 'a@x', deviceId: device.deviceId, mlsSigKey: device.mlsSigKey),
      );
      expect(await isDeviceVerified(identityKey: identity.publicKeyBase64, userId: 'a@x', device: good), isTrue);
      expect(await isDeviceVerified(identityKey: identity.publicKeyBase64, userId: 'b@x', device: good), isFalse);
      final other = await IdentityKeyPair.fromSeed(randomBytes(32));
      expect(await isDeviceVerified(identityKey: other.publicKeyBase64, userId: 'a@x', device: good), isFalse);
    });

    test('the same seed gives the same identity', () async {
      final seed = randomBytes(32);
      expect((await IdentityKeyPair.fromSeed(seed)).publicKey, (await IdentityKeyPair.fromSeed(seed)).publicKey);
      expect(await identityFingerprint((await IdentityKeyPair.fromSeed(seed)).publicKeyBase64), hasLength(39));
    });
  });
}
