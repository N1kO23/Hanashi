// Pins the openmls behaviours Hanashi's design depends on (see
// docs/protocol.md, "Encrypted conversations"). If an upgrade of the package
// changes one of these, this test fails before anything else does.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/encryption_identity.dart' show DeviceSigner;
import 'package:hanashi/e2ee/mls_service.dart';
import 'package:openmls/openmls.dart';

const _suite = MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519;
final _caps = MlsCapabilities(
  versions: Uint16List.fromList([1]),
  ciphersuites: Uint16List.fromList([1]),
  extensions: Uint16List(0),
  proposals: Uint16List(0),
  credentials: Uint16List(0),
);

class _Device {
  _Device(this.name, this.engine, this.signer, this.publicKey);

  final String name;
  final MlsEngine engine;
  final Uint8List signer;
  final Uint8List publicKey;

  static Future<_Device> create(String name) async {
    final engine = await MlsEngine.create(dbPath: ':memory:', encryptionKey: Uint8List(32));
    final keys = MlsSignatureKeyPair.generate(ciphersuite: _suite);
    final signer = serializeSigner(ciphersuite: _suite, privateKey: keys.privateKey(), publicKey: keys.publicKey());
    return _Device(name, engine, signer, keys.publicKey());
  }

  Future<Uint8List> keyPackage() async => (await engine.createKeyPackageWithOptions(
    ciphersuite: _suite,
    signerBytes: signer,
    credentialIdentity: utf8.encode(name),
    signerPublicKey: publicKey,
    options: KeyPackageOptions(lastResort: false, capabilities: _caps),
  )).keyPackageBytes;

  Future<String> read(List<int> gid, Uint8List message) async =>
      utf8.decode((await engine.processMessage(groupIdBytes: gid, messageBytes: message)).applicationMessage!);

  Future<Uint8List> write(List<int> gid, String text) async =>
      (await engine.createMessage(groupIdBytes: gid, signerBytes: signer, message: utf8.encode(text))).ciphertext;

  Future<List<String>> members(List<int> gid) async => [
    for (final m in await engine.groupMembers(groupIdBytes: gid))
      utf8.decode(MlsCredential.deserialize(bytes: m.credential).identity()),
  ];
}

/// The authenticated data of a PublicMessage or PrivateMessage (RFC 9420): in
/// the clear in both, and covered by what checks the message.
Uint8List _authenticatedData(Uint8List message) {
  var at = 2; // The version.
  int u8() => message[at++];
  int u16() => (u8() << 8) | u8();
  Uint8List vector() {
    final first = u8();
    var length = first & 0x3F;
    for (var i = 1; i < 1 << (first >> 6); i++) {
      length = (length << 8) | u8();
    }
    return message.sublist(at, at += length);
  }

  final wireFormat = u16();
  vector(); // The group ID.
  at += 8; // The epoch.
  if (wireFormat == 2) {
    u8(); // The content type.
    return vector();
  }
  expect(wireFormat, 1);
  final sender = u8();
  if (sender == 1 || sender == 2) at += 4; // A member or external sender's index.
  return vector();
}

/// [message] with a bit flipped inside [part].
Uint8List _tampered(Uint8List message, Uint8List part) {
  for (var i = 0; i + part.length <= message.length; i++) {
    if (listEquals(message.sublist(i, i + part.length), part)) {
      return Uint8List.fromList(message)..[i + part.length ~/ 2] ^= 1;
    }
  }
  fail('$part is not in the message');
}

void main() {
  late MlsGroupConfig config;
  final gid = utf8.encode('conv-1');
  late _Device alice, bob, alice2;

  setUpAll(() async {
    await Openmls.init();
    final defaults = MlsGroupConfig.defaultConfig(ciphersuite: _suite);
    config = MlsGroupConfig(
      ciphersuite: _suite,
      wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
      useRatchetTreeExtension: true,
      maxPastEpochs: 5,
      paddingSize: defaults.paddingSize,
      senderRatchetMaxOutOfOrder: defaults.senderRatchetMaxOutOfOrder,
      senderRatchetMaxForwardDistance: defaults.senderRatchetMaxForwardDistance,
      numberOfResumptionPsks: defaults.numberOfResumptionPsks,
    );
  });

  setUp(() async {
    alice = await _Device.create('alice/d1');
    bob = await _Device.create('bob/d1');
    alice2 = await _Device.create('alice/d2');
    await alice.engine.createGroupWithBuilder(
      config: config,
      signerBytes: alice.signer,
      credentialIdentity: utf8.encode(alice.name),
      signerPublicKey: alice.publicKey,
      groupId: Uint8List.fromList(gid),
      capabilities: _caps,
    );
    final add = await alice.engine.addMembers(
      groupIdBytes: gid,
      signerBytes: alice.signer,
      keyPackagesBytes: [await bob.keyPackage()],
    );
    await bob.engine.joinGroupFromWelcome(config: config, welcomeBytes: add.welcome, signerBytes: bob.signer);
  });

  test('welcome join and application messages; own messages cannot be read back', () async {
    final m = await alice.write(gid, 'hello');
    expect(mlsMessageExtractEpoch(messageBytes: m), BigInt.one);
    expect(await bob.read(gid, m), 'hello');
    await expectLater(alice.read(gid, m), throwsA(anything));
  });

  test('external join is a commit without a member sender; members are inspectable', () async {
    final groupInfo = await bob.engine.exportGroupInfo(groupIdBytes: gid, signerBytes: bob.signer);
    final join = await alice2.engine.joinGroupExternalCommit(
      config: config,
      groupInfoBytes: groupInfo,
      signerBytes: alice2.signer,
      credentialIdentity: utf8.encode(alice2.name),
      signerPublicKey: alice2.publicKey,
    );
    for (final d in [alice, bob]) {
      final result = await d.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: join.commit);
      expect(result.messageType, ProcessedMessageType.stagedCommit);
      expect(result.senderIndex, isNull, reason: 'external commits have no member sender');
    }
    expect(await bob.members(gid), ['alice/d1', 'bob/d1', 'alice/d2']);
    final leaf = (await bob.engine.groupMembers(groupIdBytes: gid)).last;
    expect(leaf.signatureKey, alice2.publicKey);
    expect(await alice.read(gid, await alice2.write(gid, 'from d2')), 'from d2');
  });

  test('only an exported GroupInfo joins: the one a commit returns lacks the message header', () async {
    Future<ExternalJoinResult> join(_Device device, Uint8List groupInfo) => device.engine.joinGroupExternalCommit(
      config: config,
      groupInfoBytes: groupInfo,
      signerBytes: device.signer,
      credentialIdentity: utf8.encode(device.name),
      signerPublicKey: device.publicKey,
    );
    final bare = (await join(
      alice2,
      await bob.engine.exportGroupInfo(groupIdBytes: gid, signerBytes: bob.signer),
    )).groupInfo!;
    final bob2 = await _Device.create('bob/d2');
    await expectLater(join(bob2, bare), throwsA(predicate((e) => '$e'.contains('Failed to deserialize group info'))));
    // An MLS message: version mls10 (1), wire format mls_group_info (4).
    expect((await join(bob2, Uint8List.fromList([0, 1, 0, 4, ...bare]))).commit, isNotEmpty);
    final exported = await alice2.engine.exportGroupInfo(groupIdBytes: gid, signerBytes: alice2.signer);
    expect(exported.sublist(0, 4), [0, 1, 0, 4]);
    // What MlsService does with what it is given.
    expect(MlsService.groupInfoMessage(exported), exported);
    expect(MlsService.groupInfoMessage(bare), [0, 1, 0, 4, ...bare]);
  });

  test('messages from the previous epoch still decrypt after a commit', () async {
    final late = await bob.write(gid, 'late');
    final update = await alice.engine.selfUpdate(groupIdBytes: gid, signerBytes: alice.signer);
    await bob.engine.processMessage(groupIdBytes: gid, messageBytes: update.commit);
    // Alice is in epoch 2 now but keeps epoch 1's secrets (maxPastEpochs).
    expect(await alice.engine.groupEpoch(groupIdBytes: gid), BigInt.two);
    expect(await alice.read(gid, late), 'late');
  });

  test('commits merge on creation: a losing committer forks and recovers by rejoining', () async {
    final winner = await alice.engine.selfUpdate(groupIdBytes: gid, signerBytes: alice.signer);
    await bob.engine.selfUpdate(groupIdBytes: gid, signerBytes: bob.signer); // Rejected by the server.
    await expectLater(bob.engine.processMessage(groupIdBytes: gid, messageBytes: winner.commit), throwsA(anything));

    await bob.engine.deleteGroup(groupIdBytes: gid);
    final groupInfo = await alice.engine.exportGroupInfo(groupIdBytes: gid, signerBytes: alice.signer);
    final rejoin = await bob.engine.joinGroupExternalCommit(
      config: config,
      groupInfoBytes: groupInfo,
      signerBytes: bob.signer,
      credentialIdentity: utf8.encode(bob.name),
      signerPublicKey: bob.publicKey,
    );
    final result = await alice.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: rejoin.commit);
    expect(result.stagedCommitInfo!.removeIndices, [1], reason: 'the stale leaf is replaced');
    expect(await alice.members(gid), ['alice/d1', 'bob/d1']);
    expect(await alice.read(gid, await bob.write(gid, 'back')), 'back');
  });

  test('a removed device cannot read later messages', () async {
    final remove = await alice.engine.removeMembers(groupIdBytes: gid, signerBytes: alice.signer, memberIndices: [1]);
    final result = await bob.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: remove.commit);
    expect(result.stagedCommitInfo!.selfRemoved, isTrue);
    expect(await bob.engine.groupIsActive(groupIdBytes: gid), isFalse);
    await expectLater(bob.read(gid, await alice.write(gid, 'secret')), throwsA(anything));
  });

  test('a Welcome to a group this device is in is refused, and the group stays as it was', () async {
    // Someone else makes a group of their own under the same ID, and invites Bob to it.
    final mallory = await _Device.create('mallory/d1');
    await mallory.engine.createGroupWithBuilder(
      config: config,
      signerBytes: mallory.signer,
      credentialIdentity: utf8.encode(mallory.name),
      signerPublicKey: mallory.publicKey,
      groupId: Uint8List.fromList(gid),
      capabilities: _caps,
    );
    final add = await mallory.engine.addMembers(
      groupIdBytes: gid,
      signerBytes: mallory.signer,
      keyPackagesBytes: [await bob.keyPackage()],
    );
    await expectLater(
      bob.engine.joinGroupFromWelcome(config: config, welcomeBytes: add.welcome, signerBytes: bob.signer),
      throwsA(anything),
    );
    expect(await bob.members(gid), ['alice/d1', 'bob/d1']);
    expect(await bob.read(gid, await alice.write(gid, 'still ours')), 'still ours');
  });

  test('the app joins a Welcome only to the conversation it came for', () async {
    final keys = MlsSignatureKeyPair.generate(ciphersuite: _suite);
    final carol = await MlsService.open(
      dbPath: ':memory:',
      dbKey: Uint8List(32),
      signer: DeviceSigner(
        signerBytes: serializeSigner(ciphersuite: _suite, privateKey: keys.privateKey(), publicKey: keys.publicKey()),
        publicKey: keys.publicKey(),
      ),
      userId: 'carol',
      deviceId: 'd1',
    );
    addTearDown(carol.close);
    final add = await alice.engine.addMembers(
      groupIdBytes: gid,
      signerBytes: alice.signer,
      keyPackagesBytes: [base64.decode((await carol.createKeyPackages(1)).single)],
    );
    // The server says it is to conv-2; the Welcome itself names conv-1.
    await expectLater(carol.joinFromWelcome('conv-2', add.welcome), throwsA(isA<WelcomeToAnotherGroup>()));
    expect((await carol.hasGroup('conv-1'), await carol.hasGroup('conv-2')), (false, false));
    await carol.joinFromWelcome('conv-1', add.welcome);
    expect(await carol.hasGroup('conv-1'), isTrue);
  });

  group('what a commit can vouch for', () {
    final data = Uint8List.fromList(List.generate(33, (i) => 0xA0 + i));

    FlexibleCommitOptions commit({List<Uint8List> add = const [], List<int> remove = const []}) =>
        FlexibleCommitOptions(
          addKeyPackages: add,
          removeIndices: Uint32List.fromList(remove),
          forceSelfUpdate: true,
          consumePendingProposals: true,
          aad: data,
          createGroupInfo: false,
          useRatchetTreeExtension: true,
        );

    Future<Uint8List> secret(_Device device) =>
        device.engine.exportSecret(groupIdBytes: gid, label: 'test', context: gid, keyLength: 32);

    test('a commit carries authenticated data; changing it gets the commit refused', () async {
      final made = await alice.engine.flexibleCommit(groupIdBytes: gid, signerBytes: alice.signer, options: commit());
      expect(_authenticatedData(made.commit), data);
      await expectLater(
        bob.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: _tampered(made.commit, data)),
        throwsA(anything),
      );
      // Refusing it left the group as it was: the real one still applies.
      final result = await bob.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: made.commit);
      expect(result.senderIndex, 0);
      expect(await secret(bob), await secret(alice));
      // And the data was for that commit alone.
      final next = await alice.write(gid, 'after');
      expect(_authenticatedData(next), isEmpty);
    });

    test('commits adding or removing members carry it too; a Welcome shares the epoch secret', () async {
      final carol = await _Device.create('carol/d1');
      final add = await alice.engine.flexibleCommit(
        groupIdBytes: gid,
        signerBytes: alice.signer,
        options: commit(add: [await carol.keyPackage()]),
      );
      expect(_authenticatedData(add.commit), data);
      await bob.engine.processMessage(groupIdBytes: gid, messageBytes: add.commit);
      await carol.engine.joinGroupFromWelcome(config: config, welcomeBytes: add.welcome!, signerBytes: carol.signer);
      expect(await secret(bob), await secret(alice));
      expect(await secret(carol), await secret(alice));

      final remove = await alice.engine.flexibleCommit(
        groupIdBytes: gid,
        signerBytes: alice.signer,
        options: commit(remove: [1]),
      );
      expect(_authenticatedData(remove.commit), data);
    });

    test('external commits carry it too; changing it gets them refused', () async {
      final join = await alice2.engine.joinGroupExternalCommitV2(
        config: config,
        groupInfoBytes: await bob.engine.exportGroupInfo(groupIdBytes: gid, signerBytes: bob.signer),
        signerBytes: alice2.signer,
        credentialIdentity: utf8.encode(alice2.name),
        signerPublicKey: alice2.publicKey,
        aad: data,
        skipLifetimeValidation: false,
      );
      expect(_authenticatedData(join.commit), data);
      await expectLater(
        alice.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: _tampered(join.commit, data)),
        throwsA(anything),
      );
      final result = await alice.engine.processMessageWithInspect(groupIdBytes: gid, messageBytes: join.commit);
      expect(result.senderIndex, isNull);
      expect(await secret(alice2), await secret(alice));
    });
  });
}
