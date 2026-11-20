import 'dart:convert';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';

import '../diagnostics/app_log.dart';
import 'encryption_identity.dart';

const _log = Log('mls');

/// One member device (leaf) of a group.
class MlsLeaf {
  const MlsLeaf({required this.index, required this.userId, required this.deviceId, required this.signatureKey});

  final int index;
  final String userId;
  final String deviceId;

  /// Base64 Ed25519 key the leaf signs with; must match the device's
  /// cross-signed record.
  final String signatureKey;

  /// Leaves whose credential is not `userId/deviceId` are invalid by design.
  static MlsLeaf? parse(MlsMemberInfo member) {
    final identity = utf8.decode(MlsCredential.deserialize(bytes: member.credential).identity(), allowMalformed: true);
    final slash = identity.lastIndexOf('/');
    if (slash <= 0) return null;
    return MlsLeaf(
      index: member.index,
      userId: identity.substring(0, slash),
      deviceId: identity.substring(slash + 1),
      signatureKey: base64.encode(member.signatureKey),
    );
  }

  @override
  String toString() => '$userId/$deviceId#$index';
}

/// This device's MLS state: one group per conversation (group ID = the
/// conversation ID), kept in an encrypted database by openmls.
class MlsService {
  MlsService._(this._engine, this._signer, this._identity);

  final MlsEngine _engine;
  final DeviceSigner _signer;
  final Uint8List _identity;

  static final _capabilities = MlsCapabilities(
    versions: Uint16List.fromList([1]),
    // Only the IANA suite we use; openmls would otherwise advertise
    // experimental post-quantum ones.
    ciphersuites: Uint16List.fromList([1]),
    extensions: Uint16List(0),
    proposals: Uint16List(0),
    credentials: Uint16List(0),
  );

  static MlsGroupConfig get config {
    final defaults = MlsGroupConfig.defaultConfig(ciphersuite: mlsCiphersuite);
    return MlsGroupConfig(
      ciphersuite: mlsCiphersuite,
      wireFormatPolicy: MlsWireFormatPolicy.ciphertext,
      // GroupInfo carries the tree, so external joiners need nothing else.
      useRatchetTreeExtension: true,
      // Messages sent just before a commit still decrypt after it.
      maxPastEpochs: 5,
      paddingSize: defaults.paddingSize,
      senderRatchetMaxOutOfOrder: defaults.senderRatchetMaxOutOfOrder,
      senderRatchetMaxForwardDistance: defaults.senderRatchetMaxForwardDistance,
      numberOfResumptionPsks: defaults.numberOfResumptionPsks,
    );
  }

  /// Opens (or creates) the device's MLS database. [dbPath] ':memory:' is for tests.
  static Future<MlsService> open({
    required String dbPath,
    required Uint8List dbKey,
    required DeviceSigner signer,
    required String userId,
    required String deviceId,
  }) async {
    final engine = await MlsEngine.create(dbPath: dbPath, encryptionKey: dbKey);
    return MlsService._(engine, signer, utf8.encode('$userId/$deviceId'));
  }

  Future<void> close() => _engine.close();

  static List<int> _gid(String conv) => utf8.encode(conv);

  Future<String> _keyPackage({required bool lastResort}) async {
    final result = await _engine.createKeyPackageWithOptions(
      ciphersuite: mlsCiphersuite,
      signerBytes: _signer.signerBytes,
      credentialIdentity: _identity,
      signerPublicKey: _signer.publicKey,
      options: KeyPackageOptions(lastResort: lastResort, capabilities: _capabilities),
    );
    return base64.encode(result.keyPackageBytes);
  }

  Future<List<String>> createKeyPackages(int count) async => [
    for (var i = 0; i < count; i++) await _keyPackage(lastResort: false),
  ];

  Future<String> createLastResortKeyPackage() => _keyPackage(lastResort: true);

  Future<bool> hasGroup(String conv) async {
    try {
      return await _engine.groupIsActive(groupIdBytes: _gid(conv));
    } catch (e) {
      // Usually there is none; anything else should show in a detailed log.
      _log.debug('No group for $conv: $e');
      return false;
    }
  }

  Future<int> epoch(String conv) async => (await _engine.groupEpoch(groupIdBytes: _gid(conv))).toInt();

  Future<void> createGroup(String conv) => _engine.createGroupWithBuilder(
    config: config,
    signerBytes: _signer.signerBytes,
    credentialIdentity: _identity,
    signerPublicKey: _signer.publicKey,
    groupId: Uint8List.fromList(_gid(conv)),
    capabilities: _capabilities,
  );

  /// Adds and removes devices and renews this device's own keys, in one commit
  /// that carries [authenticatedData]; merged locally at once (see the contract
  /// test).
  Future<CommitResult> commit(
    String conv, {
    List<Uint8List> add = const [],
    List<int> remove = const [],
    required Uint8List authenticatedData,
  }) => _engine.flexibleCommit(
    groupIdBytes: _gid(conv),
    signerBytes: _signer.signerBytes,
    options: FlexibleCommitOptions(
      addKeyPackages: add,
      removeIndices: Uint32List.fromList(remove),
      forceSelfUpdate: true,
      consumePendingProposals: true,
      aad: authenticatedData,
      // [groupInfo] exports it, with the message header.
      createGroupInfo: false,
      useRatchetTreeExtension: true,
    ),
  );

  /// The authenticated data of a PublicMessage or PrivateMessage (RFC 9420): in
  /// the clear in both, and vouched for only once the message was processed.
  /// Throws [FormatException] for anything else.
  static Uint8List authenticatedData(Uint8List message) {
    var at = 2; // The version.
    int u8() {
      if (at >= message.length) throw const FormatException('Truncated message');
      return message[at++];
    }

    Uint8List vector() {
      final first = u8();
      var length = first & 0x3F;
      for (var i = 1; i < 1 << (first >> 6); i++) {
        length = (length << 8) | u8();
      }
      if (at + length > message.length) throw const FormatException('Truncated message');
      return message.sublist(at, at += length);
    }

    final wireFormat = (u8() << 8) | u8();
    vector(); // The group ID.
    at += 8; // The epoch.
    if (wireFormat == 2) {
      u8(); // The content type.
      return vector();
    }
    if (wireFormat != 1) throw FormatException('Wire format $wireFormat');
    final sender = u8();
    if (sender == 1 || sender == 2) at += 4; // A member or external sender's index.
    return vector();
  }

  /// A secret of the group's current epoch: for sealing its state (with the
  /// conversation ID as [context]), or for a call's media (with the call's).
  Future<Uint8List> exporterSecret(String conv, String label, {List<int>? context}) => _engine.exportSecret(
    groupIdBytes: _gid(conv),
    label: label,
    context: context == null ? _gid(conv) : Uint8List.fromList(context),
    keyLength: 32,
  );

  /// [groupInfo] as an MLS message, the form [externalJoin] reads. Earlier
  /// versions uploaded the GroupInfo of their external joins without the
  /// message header (version mls10, wire format mls_group_info); this puts it
  /// back. (A bare GroupInfo starts with its version and ciphersuite, 1 and 1
  /// here, so the two cannot be confused.)
  static Uint8List groupInfoMessage(Uint8List groupInfo) =>
      groupInfo.length >= 4 && groupInfo[0] == 0 && groupInfo[1] == 1 && groupInfo[2] == 0 && groupInfo[3] == 4
      ? groupInfo
      : Uint8List.fromList([0, 1, 0, 4, ...groupInfo]);

  Future<Uint8List> groupInfo(String conv) =>
      _engine.exportGroupInfo(groupIdBytes: _gid(conv), signerBytes: _signer.signerBytes);

  /// Joins from a Welcome; returns the conversation ID.
  Future<String> joinFromWelcome(Uint8List welcome) async {
    final result = await _engine.joinGroupFromWelcome(
      config: config,
      welcomeBytes: welcome,
      signerBytes: _signer.signerBytes,
    );
    return utf8.decode(result.groupId);
  }

  /// Joins (or rejoins, replacing this device's stale leaf) by external commit.
  Future<ExternalJoinResult> externalJoin(Uint8List groupInfo, {required Uint8List authenticatedData}) =>
      _engine.joinGroupExternalCommitV2(
        config: config,
        groupInfoBytes: groupInfoMessage(groupInfo),
        signerBytes: _signer.signerBytes,
        credentialIdentity: _identity,
        signerPublicKey: _signer.publicKey,
        aad: authenticatedData,
        skipLifetimeValidation: false,
      );

  Future<Uint8List> encrypt(String conv, List<int> payload, {required List<int> aad}) async => (await _engine.createMessage(
    groupIdBytes: _gid(conv),
    signerBytes: _signer.signerBytes,
    message: payload,
    aad: Uint8List.fromList(aad),
  )).ciphertext;

  /// Decrypts an application message or merges a commit.
  Future<ProcessedMessageInspectResult> process(String conv, Uint8List message) =>
      _engine.processMessageWithInspect(groupIdBytes: _gid(conv), messageBytes: message);

  /// Current leaves; unparseable credentials come back with an empty user.
  Future<List<MlsLeaf>> members(String conv) async => [
    for (final m in await _engine.groupMembers(groupIdBytes: _gid(conv)))
      MlsLeaf.parse(m) ??
          MlsLeaf(index: m.index, userId: '', deviceId: '', signatureKey: base64.encode(m.signatureKey)),
  ];

  /// This device's leaf.
  Future<int> ownIndex(String conv) => _engine.groupOwnIndex(groupIdBytes: _gid(conv));

  Future<void> deleteGroup(String conv) async {
    try {
      await _engine.deleteGroup(groupIdBytes: _gid(conv));
    } catch (_) {
      // Already gone.
    }
  }
}
