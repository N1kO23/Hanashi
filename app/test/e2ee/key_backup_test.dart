import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/content.dart';
import 'package:hanashi/e2ee/key_backup.dart';
import 'package:hanashi/e2ee/primitives.dart';

void main() {
  test('backup entries open only with the same secret and for the same message', () async {
    final secret = randomBytes(32);
    final cipher = await KeyBackupCipher.forSecret(secret);
    final key = ContentKey(key: randomBytes(32), ctHash: randomBytes(32));

    final entry = await cipher.seal('01JB2Y8Q3M7W2V6T0Q9X4C5D6E', key);
    final opened = await (await KeyBackupCipher.forSecret(secret)).open('01JB2Y8Q3M7W2V6T0Q9X4C5D6E', entry);
    expect(opened.key, key.key);
    expect(opened.ctHash, key.ctHash);

    // Moved to another message by the server: refused.
    expect(() => cipher.open('01JB2Y8Q3M7W2V6T0Q9X4C5D6F', entry), throwsA(isA<DecryptionFailed>()));
    // Another account's (or an earlier identity's) secret.
    final other = await KeyBackupCipher.forSecret(randomBytes(32));
    expect(() => other.open('01JB2Y8Q3M7W2V6T0Q9X4C5D6E', entry), throwsA(isA<DecryptionFailed>()));
    expect(() => cipher.open('01JB2Y8Q3M7W2V6T0Q9X4C5D6E', 'not base64!'), throwsA(isA<DecryptionFailed>()));
  });
}
