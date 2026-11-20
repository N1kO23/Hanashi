import 'dart:convert';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'padding.dart';
import 'primitives.dart';

/// What a group's commits are sealed with and vouch for: its [GroupDocument],
/// and the profile keys of its members, so that someone just added knows both
/// without any of the group's messages.
///
/// The document's hash goes into each commit's authenticated data (see
/// [CommitClaim]), so every member who applies a commit agrees on it. The
/// [roster] needs no such thing: a key from it is taken only if it opens the
/// signed record of whoever it is said to belong to.
class GroupState {
  GroupState({required this.documentBytes, this.roster = const {}});

  /// The document exactly as hashed.
  final Uint8List documentBytes;

  /// User ID -> base64 profile key.
  final Map<String, String> roster;

  /// [title], [description], [picture] and [emojis] with a new salt, keeping
  /// [extra] from later versions.
  static GroupState create({
    String? title,
    String? description,
    MediaRef? picture,
    Map<String, MediaRef> emojis = const {},
    Map<String, Object?> extra = const {},
    Map<String, String> roster = const {},
  }) => GroupState(
    documentBytes: utf8.encode(
      jsonEncode(
        GroupDocument(
          salt: base64.encode(randomBytes(32)),
          title: title,
          description: description,
          picture: picture,
          emojis: emojis,
          extra: extra,
        ).toJson(),
      ),
    ),
    roster: roster,
  );

  /// Throws [FormatException] for one that is malformed.
  GroupDocument get document {
    final json = jsonDecode(utf8.decode(documentBytes));
    if (json is! Map) throw const FormatException('Not a group document');
    return GroupDocument.fromJson(json.cast<String, Object?>());
  }

  Future<Uint8List> get hash => sha256(documentBytes);

  GroupState withRoster(Map<String, String> roster) => GroupState(documentBytes: documentBytes, roster: roster);

  static const secretLabel = 'hanashi-state-v1';

  static List<int> _aad(String conv, int epoch) => utf8.encode('$secretLabel|$conv|$epoch');

  /// Sealed with the group's exporter secret for [epoch] (base64): only those
  /// who are members in that epoch can open it, and it moves on with every
  /// commit, so someone removed cannot read what comes later.
  Future<String> seal(List<int> secret, {required String conv, required int epoch}) async => base64.encode(
    await aeadSeal(
      secret,
      encodePaddedJson({'doc': base64.encode(documentBytes), 'roster': roster}),
      aad: _aad(conv, epoch),
    ),
  );

  /// Throws [DecryptionFailed] if it was not sealed for this conversation and
  /// epoch, [FormatException] for anything malformed.
  static Future<GroupState> open(String sealed, List<int> secret, {required String conv, required int epoch}) async {
    final json = jsonDecode(utf8.decode(await aeadOpen(secret, base64.decode(sealed), aad: _aad(conv, epoch))));
    final doc = json is Map ? json['doc'] : null;
    final roster = json is Map ? json['roster'] : null;
    if (doc is! String || roster is! Map) throw const FormatException('Not a group state');
    final state = GroupState(
      documentBytes: base64.decode(doc),
      roster: {
        for (final MapEntry(:key, :value) in roster.entries)
          if (key is String && value is String) key: value,
      },
    );
    state.document; // Throws if malformed.
    return state;
  }
}

/// What a commit says about the group's document.
enum StateClaimKind {
  /// It stays what it was.
  unchanged,

  /// This commit changes it.
  changed,

  /// The committer does not hold it: a device joining by itself cannot read
  /// what came before.
  unknown,
}

/// A commit's authenticated data: `version | kind | SHA-256(document)`. MLS
/// signs it and includes it in the transcript of the group, so a commit that
/// says anything else is refused, and all who apply a commit see the same.
class CommitClaim {
  const CommitClaim(this.kind, this.hash);

  const CommitClaim.unknown() : kind = StateClaimKind.unknown, hash = null;

  final StateClaimKind kind;
  final Uint8List? hash;

  static const _version = 1;
  static const _length = 2 + 32;

  Uint8List encode() => Uint8List.fromList([_version, kind.index, ...(hash ?? Uint8List(32))]);

  /// Null for anything else than what [encode] makes.
  static CommitClaim? tryParse(Uint8List data) {
    if (data.length != _length || data[0] != _version || data[1] >= StateClaimKind.values.length) return null;
    final kind = StateClaimKind.values[data[1]];
    return CommitClaim(kind, kind == StateClaimKind.unknown ? null : data.sublist(2));
  }
}
