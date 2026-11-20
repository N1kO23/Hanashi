import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/group_state.dart';
import 'package:hanashi/e2ee/primitives.dart';
import 'package:hanashi/e2ee/profile_record.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

void main() {
  group('profile records', () {
    const user = 'kumiko@test.local';
    const document = ProfileDocument(displayName: 'Kumiko', extra: {'pronouns': 'she/her'});
    late IdentityKeyPair signer;
    late Uint8List key;

    setUp(() async {
      signer = await IdentityKeyPair.fromSeed(randomBytes(32));
      key = randomBytes(32);
    });

    Future<ProfileRecord> seal({int version = 5}) =>
        ProfileRecord.seal(document, user: user, version: version, key: key, signer: signer);

    test('open with the key, signed by the identity key, keeping what later versions add', () async {
      final record = await seal();
      expect(await record.isSignedBy(signer.publicKeyBase64), isTrue);
      final opened = await record.open(key);
      expect((opened.displayName, opened.extra['pronouns']), ('Kumiko', 'she/her'));
      final again = ProfileRecord.fromJson({...record.toJson(), 'user': user}, user: user);
      expect((await again.open(key)).displayName, 'Kumiko');
    });

    test('another key does not open it, and the ciphertext hides what is in it', () async {
      final record = await seal();
      await expectLater(record.open(randomBytes(32)), throwsA(isA<DecryptionFailed>()));
      expect(utf8.decode(record.ct, allowMalformed: true), isNot(contains('Kumiko')));
    });

    test('the signature covers who, which version and what', () async {
      final record = await seal();
      final other = await IdentityKeyPair.fromSeed(randomBytes(32));
      expect(await record.isSignedBy(other.publicKeyBase64), isFalse);
      final sealedByOther = await ProfileRecord.seal(document, user: user, version: 5, key: key, signer: other);
      expect(await sealedByOther.isSignedBy(signer.publicKeyBase64), isFalse);
      for (final forged in [
        ProfileRecord(user: 'naoko@test.local', version: 5, ct: record.ct, signature: record.signature),
        ProfileRecord(user: user, version: 6, ct: record.ct, signature: record.signature),
        ProfileRecord(user: user, version: 5, ct: Uint8List.fromList([...record.ct, 0]), signature: record.signature),
      ]) {
        expect(await forged.isSignedBy(signer.publicKeyBase64), isFalse);
      }
    });

    test('the version is bound to the ciphertext too', () async {
      final record = await seal();
      final moved = ProfileRecord(user: user, version: 6, ct: record.ct, signature: record.signature);
      await expectLater(moved.open(key), throwsA(isA<DecryptionFailed>()));
    });

    test('a record is taken only as the one asked for', () async {
      final json = {...(await seal()).toJson(), 'user': user};
      expect(() => ProfileRecord.fromJson(json, user: 'naoko@test.local'), throwsFormatException);
      expect(() => ProfileRecord.fromJson({'user': user}, user: user), throwsFormatException);
    });
  });

  group('group state', () {
    const conv = '01JB2Y7Z0000000000000000AB';
    final secret = randomBytes(32);

    test('opens only for its conversation and epoch, with its secret', () async {
      final state = GroupState.create(title: 'Club', roster: {'a@b': 'a2V5'});
      final sealed = await state.seal(secret, conv: conv, epoch: 4);
      final opened = await GroupState.open(sealed, secret, conv: conv, epoch: 4);
      expect(opened.document.title, 'Club');
      expect(opened.roster, {'a@b': 'a2V5'});
      expect(opened.documentBytes, state.documentBytes);
      for (final attempt in [
        () => GroupState.open(sealed, secret, conv: conv, epoch: 5),
        () => GroupState.open(sealed, secret, conv: '01JB2Y7Z0000000000000000AC', epoch: 4),
        () => GroupState.open(sealed, randomBytes(32), conv: conv, epoch: 4),
      ]) {
        await expectLater(attempt(), throwsA(isA<DecryptionFailed>()));
      }
      expect(utf8.decode(base64.decode(sealed), allowMalformed: true), isNot(contains('Club')));
    });

    test('the hash pins the document, not the roster; the same title never hashes the same', () async {
      final state = GroupState.create(title: 'Club', roster: {'a@b': 'a2V5'});
      expect(await state.withRoster(const {}).hash, await state.hash);
      // Without the salt, the server could test guesses of a title against it.
      expect(await GroupState.create(title: 'Club').hash, isNot(await state.hash));
    });

    test('a document from a later version keeps what it does not know', () async {
      const later = GroupDocument(salt: 'c2FsdA==', title: 'Club', extra: {'rules': 'none'});
      final state = GroupState(documentBytes: utf8.encode(jsonEncode(later.toJson())));
      expect(state.document.extra['rules'], 'none');
      final changed = GroupState.create(title: 'Club Room', extra: state.document.extra);
      expect((changed.document.title, changed.document.extra['rules']), ('Club Room', 'none'));
    });

    test('commit claims round-trip, and nothing else parses as one', () async {
      final hash = await sha256(utf8.encode('document'));
      for (final kind in [StateClaimKind.unchanged, StateClaimKind.changed]) {
        final parsed = CommitClaim.tryParse(CommitClaim(kind, hash).encode())!;
        expect(parsed.kind, kind);
        expect(parsed.hash, hash);
      }
      final unknown = CommitClaim.tryParse(const CommitClaim.unknown().encode())!;
      expect((unknown.kind, unknown.hash), (StateClaimKind.unknown, null));

      final good = CommitClaim(StateClaimKind.changed, hash).encode();
      for (final bad in [
        Uint8List(0),
        good.sublist(1),
        Uint8List.fromList([...good, 0]),
        Uint8List.fromList([2, ...good.sublist(1)]),
        Uint8List.fromList([1, 9, ...good.sublist(2)]),
      ]) {
        expect(CommitClaim.tryParse(bad), isNull);
      }
    });
  });
}
