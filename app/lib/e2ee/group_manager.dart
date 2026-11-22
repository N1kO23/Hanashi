import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:openmls/openmls.dart';

import '../data/local/database.dart';
import '../data/remote/api_client.dart';
import '../diagnostics/app_log.dart';
import 'content.dart';
import 'group_state.dart';
import 'key_directory.dart';
import 'mls_service.dart';
import 'primitives.dart';

const _log = Log('groups');

/// "user/device, user/device" for the log.
String _describeLeaves(List<MlsLeaf> leaves) => [for (final l in leaves) '${l.userId}/${l.deviceId}'].join(', ');

/// Sending is refused while a conversation's group holds a device this
/// client does not trust. [reason] is user-facing.
class SendBlocked implements Exception {
  const SendBlocked(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// This device is not verified with the account's current key (it was reset
/// elsewhere): it must not join or change groups until it verifies again,
/// or it would rejoin every group and the others would remove it again,
/// round after round.
class DeviceNotVerified implements Exception {
  const DeviceNotVerified();

  @override
  String toString() => "This device is not verified with the account's current key";
}

/// The conversation's local group is behind the server; retry after syncing.
class StaleGroup implements Exception {
  const StaleGroup();
}

enum LeafProblemKind {
  /// The credential is not `userId/deviceId`.
  invalidCredential,

  /// The user is no longer a member of the conversation.
  notMember,

  /// The device's key is not cross-signed by the user's trusted identity.
  unverified,

  /// Joined by external commit although the user was never in the group.
  suspicious,

  /// The user's identity key changed and the change was not accepted yet.
  identityChanged,

  /// This very device again, beside its own leaf (two members adding it at
  /// once, say). A device has one leaf; another would go on receiving the
  /// group's secrets. (openmls before 0.9.2, GHSA-94v4-rg25-x625, left one
  /// behind after a resync by external commit; Hanashi has had the fix from
  /// 0.9.0 on.)
  staleOwnLeaf,
}

class LeafProblem {
  const LeafProblem(this.leaf, this.kind);

  final MlsLeaf leaf;
  final LeafProblemKind kind;

  /// Routine clean-up (e.g. someone left) rather than a security warning.
  bool get routine => kind == LeafProblemKind.notMember || kind == LeafProblemKind.staleOwnLeaf;

  /// Leaves the client removes on its own; identity changes need the user.
  bool get removable => kind != LeafProblemKind.identityChanged;
}

/// Whether this device should update its own keys in a group: a key that
/// leaked stops being useful after the next update (post-compromise security).
bool keyRotationDue({required DateTime rotatedAt, required int sentSince, required DateTime now}) =>
    sentSince >= 100 || now.difference(rotatedAt) >= const Duration(days: 7);

/// A commit merged here, with the state it leaves the group in.
class _MadeCommit {
  const _MadeCommit(this.result, {this.state, this.sealed});

  final CommitResult result;

  /// Null from a device that does not hold it.
  final GroupState? state;
  final String? sealed;
}

/// Ties the MLS groups to conversations: creating and joining groups,
/// processing commits in order, encrypting and decrypting messages, and
/// keeping every group's members equal to the conversation's verified devices.
///
/// Every method must run on the repository's serial queue so group state is
/// never touched concurrently.
class GroupManager {
  GroupManager({
    required this.mls,
    required this.keys,
    required this.api,
    required this.db,
    required this.me,
    required this.deviceId,
    required this.ownProfileKey,
    required this.refreshContacts,
    this.clock = DateTime.now,
    this.onCommitUnsettled,
    this.onOwnLine,
    this.onRetryLater,
    this.onEpoch,
  });

  final MlsService mls;
  final KeyDirectory keys;
  final ApiClient api;
  final AppDatabase db;
  final String me;
  final String deviceId;

  /// The base64 key that opens the user's profile, for the rosters of groups.
  final Future<String?> Function() ownProfileKey;

  /// Reads the user's contact list again (another device may just have added
  /// someone), before refusing what comes from someone not on it.
  final Future<void> Function() refreshContacts;
  final DateTime Function() clock;

  /// A commit got no clear answer; [reconcile] should run again soon, in case
  /// nothing else makes it.
  final void Function(String conv)? onCommitUnsettled;

  /// A change of members this device made counted, and its line
  /// ([Envelope.memberType]) is to be sent to the group.
  final void Function(Envelope line)? onOwnLine;

  /// [reconcile] should run for a conversation again [after] a while.
  final void Function(String conv, Duration after)? onRetryLater;

  /// The group of a conversation is at an epoch everyone in it agrees on
  /// (another member's commit applied, this device's own counted, or it
  /// joined), or it is gone: a call in it takes its key for that epoch
  /// ([callKey]). Awaited, on the serial queue.
  final Future<void> Function(String conv)? onEpoch;

  /// The MLS exporter label of call keys (see docs/calls.md).
  static const callKeyLabel = 'hanashi-call-v1';

  /// The key of the media of call [callId] at the group's current epoch;
  /// null without the group, or while this device's own commit is
  /// unsettled: its epoch may never be anyone else's.
  Future<({int epoch, Uint8List key})?> callKey(String conv, String callId) async {
    if (!await mls.hasGroup(conv) || await _unsettled(conv) != null) return null;
    return (
      epoch: await mls.epoch(conv),
      key: await mls.exporterSecret(conv, callKeyLabel, context: utf8.encode(callId)),
    );
  }

  Future<void> _epochChanged(String conv) async {
    final callback = onEpoch;
    if (callback == null) return;
    try {
      await callback(conv);
    } catch (e, stack) {
      _log.warning('A call could not take the new epoch of $conv', e, stack);
    }
  }

  /// When this device last joined a conversation's group by itself, and how
  /// many times in a row another device removed it again right after. Past
  /// [_removalsBeforeWaiting], it waits longer and longer before joining
  /// again ([_rejoinNotBefore]), rather than going round with that device for
  /// as long as both run, two commits a turn for everyone in the chat.
  final _selfJoins = <String, ({DateTime at, int removals})>{};
  final _rejoinNotBefore = <String, DateTime>{};
  static const _quickRemoval = Duration(minutes: 2);
  static const _removalsBeforeWaiting = 3;
  static const _longestRejoinWait = Duration(hours: 1);

  /// Conversations whose local group must be rebuilt (it forked or fell behind).
  final needsRecovery = <String>{};

  /// Conversations whose state changed here; the repository looks at their
  /// rosters.
  final stateChanged = <String>{};

  /// Conversations whose newest commit came without their state, for another
  /// member (perhaps this device) to seal it.
  final stateMissing = <String>{};
  final _leafCache = <String, ({int epoch, List<MlsLeaf> leaves})>{};

  Future<List<MlsLeaf>> _leaves(String conv) async {
    final epoch = await mls.epoch(conv);
    final cached = _leafCache[conv];
    if (cached != null && cached.epoch == epoch) return cached.leaves;
    final leaves = await mls.members(conv);
    _leafCache[conv] = (epoch: epoch, leaves: leaves);
    return leaves;
  }

  // Leases and commits

  /// Runs [body] while holding the conversation's commit lease. With [epoch]
  /// (where our group is), throws [StaleGroup] instead of taking the lease if
  /// the conversation moved on: the commits are on their way. A lease whose
  /// commit did not go through is given back, so other devices need not wait
  /// for it to expire.
  ///
  /// While another device holds the lease, throws `lease_held` at once (the
  /// repository retries upkeep a little later), or with [wait], for what the
  /// user is waiting for, tries again for a few seconds.
  Future<T> _withLease<T>(String conv, Future<T> Function(Lease lease) body, {int? epoch, bool wait = false}) async {
    final lease = await _lease(conv, epoch: epoch, wait: wait);
    _log.debug('Lease for $conv at epoch ${lease.epoch}');
    try {
      return await body(lease);
    } catch (e) {
      _log.debug('Giving back the lease for $conv: ${e.runtimeType}: $e');
      await api.releaseLease(conv, lease).catchError((Object _) {});
      rethrow;
    }
  }

  Future<Lease> _lease(String conv, {int? epoch, required bool wait}) async {
    // Nothing goes on top of a commit that may not count.
    if (await _unsettled(conv) != null) throw const StaleGroup();
    for (var attempt = 0; ; attempt++) {
      try {
        return await api.lease(conv, epoch: epoch);
      } on ApiException catch (e) {
        if (e.code == 'epoch_mismatch') {
          _log.debug('No lease for $conv: the conversation moved on from epoch $epoch');
          throw const StaleGroup();
        }
        if (e.code == 'lease_held') _log.debug('No lease for $conv: another device holds it');
        if (!wait || e.code != 'lease_held' || attempt >= 8) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
  }

  /// Makes a commit: merged here at once, carrying what it says about the
  /// group's state, and with that state sealed for the epoch it starts.
  /// [change] makes it a commit that changes the document. Every commit a
  /// member makes goes through here, so none can leave the state behind.
  Future<_MadeCommit> _makeCommit(
    String conv, {
    List<Uint8List> add = const [],
    List<int> remove = const [],
    GroupDocument Function(GroupDocument current)? change,
    Iterable<String> users = const [],
  }) async {
    final held = await heldState(conv);
    GroupState? next = held;
    if (change != null) {
      if (held == null) {
        throw StateError("This group's details have not reached this device yet. Try again in a moment.");
      }
      final document = change(held.document);
      next = GroupState.create(
        title: document.title,
        description: document.description,
        picture: document.picture,
        emojis: document.emojis,
        extra: document.extra,
        roster: held.roster,
      );
    }
    final Uint8List? hash = await next?.hash;
    final claim = hash == null
        ? const CommitClaim.unknown()
        : CommitClaim(change == null ? StateClaimKind.unchanged : StateClaimKind.changed, hash);
    next = next?.withRoster(await _rosterFor(conv, next));
    // Noted before merging: from here on the app may be gone at any moment, and
    // what it finds when it comes back must not look like nothing happened.
    await _noteUnsettled(conv, await mls.epoch(conv), next, changesDocument: change != null, users: users);
    final CommitResult made;
    try {
      made = await mls.commit(conv, add: add, remove: remove, authenticatedData: claim.encode());
    } catch (_) {
      await db.forgetUnsettledCommit(conv);
      rethrow;
    }
    if (next == null) return _MadeCommit(made);
    return _MadeCommit(made, state: next, sealed: await _seal(conv, next));
  }

  /// [state]'s roster for what goes out now: this user's current key, and only
  /// those still members.
  Future<Map<String, String>> _rosterFor(String conv, GroupState state) async {
    final members = (await db.memberIds(conv)).toSet();
    final own = await ownProfileKey();
    return {
      for (final MapEntry(:key, :value) in state.roster.entries)
        if (key != me && (members.isEmpty || members.contains(key))) key: value,
      me: ?own,
    };
  }

  Future<String> _seal(String conv, GroupState state) async =>
      state.seal(await mls.exporterSecret(conv, GroupState.secretLabel), conv: conv, epoch: await mls.epoch(conv));

  /// Sends a commit this device already merged (see [_commitFailed] for when
  /// that does not work out).
  /// Removals and self-updates also renew this device's own keys.
  Future<int> _submit(String conv, Lease lease, _MadeCommit made) async {
    try {
      final seq = await api.commit(
        conv,
        Commit(
          leaseId: lease.id,
          epoch: lease.epoch,
          mls: made.result.commit,
          groupInfo: await mls.groupInfo(conv),
          state: made.sealed,
        ),
      );
      await _commitCounted(conv, seq: seq, ts: clock().millisecondsSinceEpoch);
      _log.debug('Commit to $conv at epoch ${lease.epoch} accepted');
      return seq;
    } on ApiException catch (e) {
      await _commitFailed(conv, lease, e);
      rethrow;
    }
  }

  /// Remembers what a commit leaves to do.
  Future<void> _noteUnsettled(
    String conv,
    int epoch,
    GroupState? state, {
    bool creating = false,
    bool changesDocument = false,
    Iterable<String> users = const [],
    Map<String, Object?>? request,
  }) async {
    await db.noteUnsettledCommit(
      conv,
      epoch: epoch,
      creating: creating,
      document: state == null ? null : base64.encode(state.documentBytes),
      roster: state?.roster,
      changesDocument: changesDocument,
      users: users,
      request: request,
    );
  }

  /// The commit waiting in [db] counted: what it said is now so, whether the
  /// server's answer or the event log is what told us. [seq] and [ts] are where
  /// it is in the timeline.
  Future<void> _commitCounted(String conv, {required int seq, required int ts}) async {
    final row = await db.unsettledCommit(conv);
    if (row == null) return;
    final encoded = row.document;
    if (encoded != null) {
      final state = GroupState(documentBytes: base64.decode(encoded), roster: _parseRoster(row.roster ?? '{}'));
      final before = (await heldState(conv))?.document;
      await db.setGroupState(
        conv,
        hash: base64.encode(await state.hash),
        document: encoded,
        roster: state.roster,
        verified: true,
      );
      stateChanged.add(conv);
      if (row.changesDocument) {
        await db.addGroupChangeLines(conv, seq: seq, ts: ts, by: me, before: before, after: state.document);
      }
    }
    final users = (jsonDecode(row.users) as List).cast<String>();
    if (users.isNotEmpty) await db.addGroupUsers(conv, users);
    // Adding someone does not renew this device's keys.
    if (row.creating || users.isEmpty) await db.noteKeyRotation(conv, clock());
    await db.forgetUnsettledCommit(conv);
    await _epochChanged(conv);
    // Said once it counted, so that everyone in the group then can read it.
    final say = onOwnLine;
    if (say == null) return;
    if (row.creating) {
      if (_requestOf(row)?['directWith'] == null) say(Envelope.member(conv: conv, from: me, change: 'created'));
    } else {
      for (final user in users) {
        say(Envelope.member(conv: conv, from: me, change: 'added', user: user));
      }
    }
  }

  static Map<String, Object?>? _requestOf(UnsettledCommitRow row) =>
      row.request == null ? null : (jsonDecode(row.request!) as Map).cast<String, Object?>();

  /// If the server refused a commit this device already merged, our group has
  /// forked from everyone else's and is rebuilt. Any other trouble (no answer,
  /// or a proxy's while the server restarts) says nothing about whether it went
  /// through, so that is left for the event log to settle.
  Future<void> _commitFailed(String conv, Lease lease, ApiException e) async {
    if (e.isPermanent) {
      _log.warning('The server refused our commit to $conv at epoch ${lease.epoch} (${e.code}): rebuilding the group');
      await recover(conv);
      return;
    }
    _log.info(
      'Commit to $conv at epoch ${lease.epoch}: no clear answer (${e.status} ${e.code}), waiting to see if it counted',
    );
    onCommitUnsettled?.call(conv);
  }

  /// The commit of [conv] waiting to be settled. One noted but never merged (the
  /// group is still at its epoch), or for a group now gone, is over: it was not
  /// sent, or there is nothing left it could change.
  Future<UnsettledCommitRow?> _unsettled(String conv) async {
    final row = await db.unsettledCommit(conv);
    if (row == null) return null;
    final local = await localEpoch(conv);
    if (local != null && (row.creating || local != row.epoch)) return row;
    await db.forgetUnsettledCommit(conv);
    return null;
  }

  /// Sends the request for a new conversation again, as it went the first time:
  /// the server answers a repeat with what the first one made, so this settles
  /// whether it exists, and makes it if it did not. Throws if the server cannot
  /// say.
  Future<ConversationInfo> _askAgain(String conv, UnsettledCommitRow row) async {
    final request = _requestOf(row)!;
    final group = NewGroup.fromJson((request['group'] as Map).cast<String, Object?>());
    return api.createConversation(
      id: conv,
      members: (request['members'] as List).cast<String>(),
      group: group,
      direct: request['directWith'] != null,
    );
  }

  /// Settles a new conversation whose answer never came ([_askAgain]): true if
  /// it is now as asked. Otherwise its group is dropped: refused, or the direct
  /// chat of the two existed already (which comes by its own events).
  Future<bool> _settleNewConversation(String conv, UnsettledCommitRow row) async {
    if (row.request == null) {
      // Noted by a version from before requests were kept: it counted if its
      // conversation got here.
      if ((await db.memberIds(conv)).isNotEmpty) {
        await _commitCounted(conv, seq: 0, ts: clock().millisecondsSinceEpoch);
        return true;
      }
    } else {
      try {
        final info = await _askAgain(conv, row);
        if (info.id == conv) {
          _log.info('Our new conversation $conv is there');
          await db.applyConversation(info);
          await _commitCounted(conv, seq: 0, ts: clock().millisecondsSinceEpoch);
          return true;
        }
      } on ApiException catch (e) {
        if (!e.isPermanent) rethrow;
        _log.info('Our new conversation $conv was refused (${e.code})');
      }
    }
    _log.info('Dropping the group made for $conv');
    await mls.deleteGroup(conv);
    await db.forgetUnsettledCommit(conv);
    return false;
  }

  static String _groupKey(Iterable<String> users, String? title) => jsonEncode([users.toList()..sort(), title]);

  static String _pendingGroupKey(UnsettledCommitRow row) {
    final encoded = row.document;
    final state = encoded == null ? null : GroupState(documentBytes: base64.decode(encoded), roster: const {});
    return _groupKey((jsonDecode(row.users) as List).cast<String>(), state?.document.title);
  }

  static const _recoveredPrefix = 'groups.recovered:';

  /// How long asking again for a group that went through without the user
  /// being told gets that one instead of a new one.
  static const _recoveredFor = Duration(days: 1);

  /// The group the user is asking for if an earlier try of theirs went through,
  /// so that trying again makes no second one. Throws if the server cannot say
  /// yet: then nothing new should be made either.
  Future<String?> _groupAlreadyAsked(Set<String> users, String? title) async {
    final key = _groupKey(users, title);
    final recovered = await db.getValue('$_recoveredPrefix$key');
    if (recovered != null) {
      await db.setValue('$_recoveredPrefix$key', null);
      final (:String id, :int at) = switch (jsonDecode(recovered)) {
        {'id': final String id, 'at': final int at} => (id: id, at: at),
        _ => (id: '', at: 0),
      };
      final fresh = clock().difference(DateTime.fromMillisecondsSinceEpoch(at)) < _recoveredFor;
      if (fresh && (await db.memberIds(id)).isNotEmpty) return id;
    }
    for (final conv in await db.unsettledConversations()) {
      final row = await _unsettled(conv);
      if (row == null || !row.creating || _pendingGroupKey(row) != key) continue;
      if (await _settleNewConversation(conv, row)) return conv;
    }
    return null;
  }

  /// A group the user was told did not work out did: the next time they ask
  /// for it, they get it ([_groupAlreadyAsked]).
  Future<void> _rememberRecovered(UnsettledCommitRow row, String conv) async {
    if (_requestOf(row)?['directWith'] != null) return;
    await db.setValue(
      '$_recoveredPrefix${_pendingGroupKey(row)}',
      jsonEncode({'id': conv, 'at': clock().millisecondsSinceEpoch}),
    );
  }

  /// Whether nothing stands in the way of looking after [conv]'s group, having
  /// found out what can be found out about a commit waiting to be settled.
  ///
  /// The server has moved on from its epoch if a commit went through, whose
  /// event then settles it ([processCommit]). If not, or if no such event is
  /// coming, ours never counted and the group is ahead of everyone's.
  Future<bool> _checkUnsettled(String conv) async {
    final row = await _unsettled(conv);
    if (row == null) return true;
    if (row.creating) {
      if (!await _settleNewConversation(conv, row)) return false;
      await _rememberRecovered(row, conv);
      return true;
    }
    if ((await api.groupInfo(conv)).epoch > row.epoch) {
      final next = await api.sync(await db.cursor());
      if (next.more || next.events.any((e) => e.conv == conv && e.type == EventType.mlsCommit)) return false;
    }
    _log.info('Our commit to $conv at epoch ${row.epoch} never went through: rebuilding the group');
    needsRecovery.add(conv);
    return true;
  }

  // Group state

  /// The document and roster this device holds, if the document is the one the
  /// group's commits pin.
  Future<GroupState?> heldState(String conv) async {
    final row = await db.groupStateRow(conv);
    final (hash, document) = (row?.hash, row?.document);
    if (hash == null || document == null) return null;
    final state = GroupState(documentBytes: base64.decode(document), roster: _parseRoster(row!.roster));
    return base64.encode(await state.hash) == hash ? state : null;
  }

  static Map<String, String> _parseRoster(String json) => (jsonDecode(json) as Map).cast<String, String>();

  /// Opens the state sealed for the group's current epoch; null if it is not.
  Future<GroupState?> _openState(String conv, String sealed) async {
    try {
      return await GroupState.open(
        sealed,
        await mls.exporterSecret(conv, GroupState.secretLabel),
        conv: conv,
        epoch: await mls.epoch(conv),
      );
    } on DecryptionFailed catch (e) {
      _log.warning('The state of $conv sealed for epoch ${await mls.epoch(conv)} does not open: $e');
    } on FormatException catch (e) {
      _log.warning('The state of $conv sealed for epoch ${await mls.epoch(conv)} is malformed: $e');
    }
    return null;
  }

  /// Takes what [opened] holds. Its document counts only if it is the one the
  /// commits pin ([hash]); otherwise what is here keeps showing, and the state
  /// is pending until a member seals the right one. Without any hash yet (a
  /// device just joined), the one who sealed it is believed until the next
  /// commit says otherwise.
  Future<void> _takeState(
    String conv, {
    required String? hash,
    required GroupState? opened,
    required bool verified,
    ({int seq, int ts, String by})? changedBy,
  }) async {
    final row = await db.groupStateRow(conv);
    final before = _tryDocument(row?.document);
    var pinned = hash;
    String? document;
    Map<String, String>? roster;
    GroupDocument? after;
    if (opened != null) {
      final openedHash = base64.encode(await opened.hash);
      pinned ??= openedHash;
      if (openedHash == pinned) {
        document = base64.encode(opened.documentBytes);
        after = opened.document;
      } else {
        _log.warning('The state of $conv does not match what its commits pin: keeping what is here');
      }
      roster = {
        for (final MapEntry(:key, :value)
            in row == null ? const <String, String>{}.entries : _parseRoster(row.roster).entries)
          if (key != me) key: value,
        ...opened.roster,
      };
    }
    await db.setGroupState(conv, hash: pinned, document: document, roster: roster, verified: verified);
    if (changedBy case final change? when after != null) {
      await db.addGroupChangeLines(conv, seq: change.seq, ts: change.ts, by: change.by, before: before, after: after);
    }
    stateChanged.add(conv);
  }

  static GroupDocument? _tryDocument(String? encoded) {
    if (encoded == null) return null;
    try {
      return GroupDocument.fromJson((jsonDecode(utf8.decode(base64.decode(encoded))) as Map).cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  /// What a commit from another device means for the state. Everyone who
  /// applies it sees the same claim, so this is where members agree.
  Future<void> _takeCommitState(SyncEvent event, CommitClaim? claim, {required String by}) async {
    final conv = event.conv;
    final row = await db.groupStateRow(conv);
    var (hash, verified) = (row?.hash, row?.verified ?? false);
    final claimed = claim?.hash == null ? null : base64.encode(claim!.hash!);
    switch (claim?.kind) {
      case StateClaimKind.changed:
        (hash, verified) = (claimed, true);
      case StateClaimKind.unchanged:
        if (hash == null || !verified) {
          // Believed until now only because whoever sealed it said so.
          if (hash != null && hash != claimed) _log.warning('The state of $conv was not what its commits pin');
          (hash, verified) = (claimed, true);
        } else if (hash != claimed) {
          _log.warning('$by changed the state of $conv without saying so: keeping what is here');
        }
      case StateClaimKind.unknown:
        break;
      case null:
        _log.warning('A commit to $conv by $by says nothing about its state');
    }
    final sealed = event.data['state'] as String?;
    if (sealed == null) stateMissing.add(conv);
    await _takeState(
      conv,
      hash: hash,
      opened: sealed == null ? null : await _openState(conv, sealed),
      verified: verified,
      changedBy: claim?.kind == StateClaimKind.changed ? (seq: event.seq, ts: event.ts, by: by) : null,
    );
  }

  /// A member sealed the state for an epoch whose commit came without it.
  Future<void> takeSealedState(SyncEvent event) async {
    final conv = event.conv;
    if (!await mls.hasGroup(conv) || event.data['epoch'] != await mls.epoch(conv)) return;
    stateMissing.remove(conv);
    final row = await db.groupStateRow(conv);
    await _takeState(
      conv,
      hash: row?.hash,
      opened: await _openState(conv, event.data['data'] as String),
      verified: row?.verified ?? false,
    );
  }

  /// A member told the group their profile key: it goes in the roster with the
  /// next commit, for whoever comes next.
  Future<void> noteRosterKey(String conv, String user, String key) async {
    final row = await db.groupStateRow(conv);
    if (row == null) return;
    await db.setGroupState(conv, roster: {..._parseRoster(row.roster), user: key});
  }

  /// Seals the state for the current epoch if its commit came without it and
  /// nobody else has yet.
  Future<void> sealIfMissing(String conv) async {
    stateMissing.remove(conv);
    if (!await mls.hasGroup(conv)) return;
    final held = await heldState(conv);
    if (held == null) return;
    final info = await api.groupInfo(conv);
    final epoch = await mls.epoch(conv);
    if (info.state != null || info.epoch != epoch) return;
    final state = held.withRoster(await _rosterFor(conv, held));
    try {
      await api.putGroupState(conv, epoch: epoch, sealed: await _seal(conv, state));
      _log.debug('Sealed the state of $conv for epoch $epoch');
    } on ApiException catch (e) {
      if (e.code != 'state_exists' && e.code != 'epoch_mismatch') rethrow;
    }
  }

  /// Changes the group's document by a commit, and returns once the server
  /// took it. Throws [StaleGroup] if this device is behind: it then catches up
  /// and tries again on what that commit made of it, so no change gets lost.
  Future<void> changeDocument(String conv, GroupDocument Function(GroupDocument current) change) async {
    if (!await mls.hasGroup(conv)) throw const StaleGroup();
    await _requireVerified('changing $conv');
    await _withLease(conv, epoch: await mls.epoch(conv), wait: true, (lease) async {
      if (await mls.epoch(conv) != lease.epoch) throw const StaleGroup();
      await _submit(conv, lease, await _makeCommit(conv, change: change));
      _leafCache.remove(conv);
    });
  }

  /// Whether someone the user trusts put this device into [leaves]' group: for
  /// a chat of two, the other one; for a group, a contact has to be in it, and
  /// [by], whoever says they brought it there, has to be one too (null: a new
  /// device joining by itself, with nobody bringing it). MLS does not say who
  /// wrote a Welcome, so the server could lie about that, but then one of the
  /// user's contacts is in the group anyway.
  Future<bool> _broughtByContact(List<MlsLeaf> leaves, String? by) async {
    bool allowed(Set<String> trusted) {
      final others = {for (final leaf in leaves) leaf.userId}..remove(me);
      if (others.isEmpty) return true;
      if (others.length == 1) return trusted.contains(others.single);
      return (by == null || by == me || trusted.contains(by)) && others.any(trusted.contains);
    }

    if (allowed(await db.trustedContacts())) return true;
    await refreshContacts();
    return allowed(await db.trustedContacts());
  }

  /// Throws [DeviceNotVerified] unless this device is verified with the
  /// account's current key.
  Future<void> _requireVerified(String doing) async {
    final own = await keys.devicesOf(me);
    if (own.devices[deviceId] != null) return;
    _log.warning(
      'Not $doing: this device is not verified with the account key'
      '${own.identityChanged ? ' (it was reset elsewhere)' : ''}',
    );
    throw const DeviceNotVerified();
  }

  /// Counts this device being removed right after it joined [conv] by itself,
  /// and makes it wait before the next try once that keeps happening.
  Future<void> _noteRemoval(String conv, {required String by}) async {
    final joined = _selfJoins[conv];
    if (joined == null || clock().difference(joined.at) > _quickRemoval) {
      _selfJoins.remove(conv);
      return;
    }
    final removals = joined.removals + 1;
    _selfJoins[conv] = (at: joined.at, removals: removals);
    if (removals < _removalsBeforeWaiting) return;
    final minutes = 1 << (removals - _removalsBeforeWaiting).clamp(0, 6);
    final wait = Duration(minutes: minutes) > _longestRejoinWait ? _longestRejoinWait : Duration(minutes: minutes);
    _rejoinNotBefore[conv] = clock().add(wait);
    _log.warning(
      '$by removed this device from $conv right after it joined, $removals times in a row: joining again in $wait',
    );
    await db.setSecurityIssue(
      conv,
      "Another member's device keeps removing this one from this chat, which it then cannot read. It tries again later.",
    );
    onRetryLater?.call(conv, wait);
  }

  /// Whether [user] is on the user's own contact list, read again if not.
  Future<bool> _onContactList(String user) async {
    if ((await db.trustedContacts()).contains(user)) return true;
    await refreshContacts();
    return (await db.trustedContacts()).contains(user);
  }

  /// Where this device's group of [conv] is; null without one.
  Future<int?> localEpoch(String conv) async => await mls.hasGroup(conv) ? await mls.epoch(conv) : null;

  /// Drops the group of a conversation the user left.
  Future<void> forget(String conv) async {
    _log.info('Forgetting the group of $conv');
    _leafCache.remove(conv);
    needsRecovery.remove(conv);
    await mls.deleteGroup(conv);
    await db.clearGroupState(conv);
    await db.forgetUnsettledCommit(conv);
    await _epochChanged(conv);
  }

  /// Rebuilds a forked or lost group by rejoining with an external commit.
  Future<void> recover(String conv) async {
    _log.info('Rebuilding the group of $conv: deleting it and joining again');
    _leafCache.remove(conv);
    await mls.deleteGroup(conv);
    needsRecovery.remove(conv);
    await db.forgetUnsettledCommit(conv);
    await joinExternally(conv);
  }

  // Creating and joining

  /// Claims key packages for the verified devices of [users] (except this
  /// one) to add them to a group. Fails if another user has no device that
  /// can be added: they could never join safely later.
  Future<Map<String, Uint8List>> _claimPackages(Iterable<String> users) async {
    final devicesByUser = {
      for (final user in users) user: (await keys.devicesOf(user)).devices.keys.where((d) => d != deviceId).toList(),
    };
    final packages = await api.claimKeyPackages([for (final devices in devicesByUser.values) ...devices]);
    if (_log.detailed) {
      final found = [
        for (final MapEntry(key: user, value: devices) in devicesByUser.entries)
          '$user ${devices.where(packages.containsKey).length}/${devices.length}',
      ];
      _log.debug('Key packages: ${found.join(', ')}');
    }
    for (final MapEntry(key: user, value: devices) in devicesByUser.entries) {
      if (user != me && !devices.any(packages.containsKey)) {
        throw StateError('$user has not set up encryption on any device yet.');
      }
    }
    return packages;
  }

  /// Checks freshly added leaves before anything is sent to the server.
  Future<void> _requireTrustedLeaves(String conv) async {
    _leafCache.remove(conv);
    final problems = (await leafProblems(conv)).where((p) => !p.routine);
    if (problems.isNotEmpty) {
      throw StateError('A key package did not match a verified device (${problems.first.leaf}).');
    }
  }

  /// Creates a group with [members] and its [title], or the direct chat with
  /// [directWith], a contact. Returns the conversation ID, which is an existing
  /// one if the direct chat existed already.
  Future<String> createConversation({List<String> members = const [], String? title, String? directWith}) async {
    final id = newUlid();
    final others = directWith == null ? members : [directWith];
    final users = {me, ...others};
    if (directWith == null) {
      final asked = await _groupAlreadyAsked(users, title);
      if (asked != null) return asked;
    }
    final packages = await _claimPackages(users);
    await mls.createGroup(id);
    var mayHaveCounted = false;
    try {
      final own = await ownProfileKey();
      final state = GroupState.create(title: title, roster: {me: ?own});
      final made = await mls.commit(
        id,
        add: packages.values.toList(),
        authenticatedData: CommitClaim(StateClaimKind.changed, await state.hash).encode(),
      );
      final welcome = made.welcome!;
      // Members are checked against the server's member list, which does not
      // exist yet; only the device keys matter here.
      await _requireTrustedLeaves(id);
      final group = NewGroup(
        epoch: await mls.epoch(id),
        groupInfo: await mls.groupInfo(id),
        state: await _seal(id, state),
        welcomes: [for (final device in packages.keys) Welcome(device: device, data: welcome)],
      );
      await _noteUnsettled(
        id,
        0,
        state,
        creating: true,
        users: users,
        request: {'members': others, 'directWith': ?directWith, 'group': group.toJson()},
      );
      ConversationInfo info;
      try {
        info = await api.createConversation(id: id, members: others, group: group, direct: directWith != null);
      } on ApiException catch (e) {
        if (e.isPermanent) rethrow;
        _log.info('New conversation $id: no clear answer (${e.status} ${e.code}), asking again');
        try {
          info = await _askAgain(id, (await db.unsettledCommit(id))!);
        } on ApiException catch (again) {
          if (again.isPermanent) rethrow;
          // Settled later ([_checkUnsettled]); until then its group is not
          // thrown away, with the state only this device knows.
          mayHaveCounted = true;
          onCommitUnsettled?.call(id);
          rethrow;
        }
      }
      if (info.id != id) {
        // The direct chat already existed; use it instead.
        await db.forgetUnsettledCommit(id);
        await mls.deleteGroup(id);
        await db.unrefuseConversation(info.id);
        await db.applyConversation(info);
        if (!await mls.hasGroup(info.id)) await joinExternally(info.id, wait: true);
        return info.id;
      }
      await db.applyConversation(info);
      // Chosen by us, so their devices that join later are expected.
      await _commitCounted(id, seq: 0, ts: clock().millisecondsSinceEpoch);
      _log.info('Created $id with ${users.length} people, ${packages.length} other devices');
      return id;
    } catch (_) {
      if (!mayHaveCounted) {
        await db.forgetUnsettledCommit(id);
        await mls.deleteGroup(id);
      }
      rethrow;
    }
  }

  /// Adds [userId] to a group conversation.
  Future<void> addUser(String conv, String userId) async {
    final packages = await _claimPackages([userId]);
    await _withLease(conv, epoch: await mls.epoch(conv), wait: true, (lease) async {
      if (await mls.epoch(conv) != lease.epoch) throw const StaleGroup();
      final made = await _makeCommit(conv, add: packages.values.toList(), users: [userId]);
      final welcome = made.result.welcome!;
      final welcomes = [for (final device in packages.keys) Welcome(device: device, data: welcome)];
      try {
        await _requireTrustedLeaves(conv);
      } catch (_) {
        await recover(conv); // Undo the local merge.
        rethrow;
      }
      try {
        final info = await api.addMember(
          conv,
          userId,
          Commit(
            leaseId: lease.id,
            epoch: lease.epoch,
            mls: made.result.commit,
            groupInfo: await mls.groupInfo(conv),
            state: made.sealed,
            welcomes: welcomes,
          ),
        );
        await db.applyConversation(info);
        await _commitCounted(conv, seq: 0, ts: clock().millisecondsSinceEpoch);
        _log.info('Added $userId to $conv with ${packages.length} devices');
      } on ApiException catch (e) {
        await _commitFailed(conv, lease, e);
        rethrow;
      }
    });
  }

  /// Joins a conversation's group by external commit (a new device, or one
  /// whose group was lost). [wait] as for [_withLease].
  Future<void> joinExternally(String conv, {bool wait = false}) async {
    if (await mls.hasGroup(conv)) return;
    await _requireVerified('joining $conv');
    await _withLease(conv, wait: wait, (lease) async {
      final info = await api.groupInfo(conv);
      if (info.epoch != lease.epoch) {
        _log.warning('Cannot join $conv: its group info is at epoch ${info.epoch}, the conversation at ${lease.epoch}');
        throw const StaleGroup();
      }
      _log.info('Joining $conv by external commit at epoch ${info.epoch}');
      // A new device cannot read what came before, and waits for another
      // member to seal it. So does one rebuilding its group, which may have
      // missed a change: it only goes on showing what it knew. With nobody
      // else in the chat there is nobody to wait for, or to have changed it.
      final others = (await db.memberIds(conv)).any((member) => member != me);
      var held = others ? null : await heldState(conv);
      // Noted before merging, like every commit ([_makeCommit]).
      await db.noteUnsettledCommit(conv, epoch: lease.epoch);
      final join = await mls.externalJoin(
        info.data,
        authenticatedData: held == null
            ? const CommitClaim.unknown().encode()
            : CommitClaim(StateClaimKind.unchanged, await held.hash).encode(),
      );
      // Nothing was sent yet, and if this is no group of the user's, nothing is.
      _leafCache.remove(conv);
      final leaves = await _leaves(conv);
      final own = leaves.any((l) => l.userId == me && l.deviceId != deviceId);
      if (!own && !(await db.groupUsersOf(conv)).contains(me) && !await _broughtByContact(leaves, null)) {
        _log.warning('Not joining $conv: nobody the user trusts is in it');
        await mls.deleteGroup(conv);
        await db.forgetUnsettledCommit(conv);
        _leafCache.remove(conv);
        await db.refuseConversation(conv);
        await api.releaseLease(conv, lease).catchError((Object _) {});
        return;
      }
      if (held != null) {
        held = held.withRoster(await _rosterFor(conv, held));
      } else {
        await db.unpinGroupState(conv);
      }
      try {
        await api.commit(
          conv,
          Commit(
            leaseId: lease.id,
            epoch: lease.epoch,
            mls: join.commit,
            // Not join.groupInfo: openmls returns that without the MLS
            // message header, and the next device to join could not read it.
            groupInfo: await mls.groupInfo(conv),
            state: held == null ? null : await _seal(conv, held),
          ),
        );
      } catch (e) {
        _log.info('Joining $conv failed: $e');
        await mls.deleteGroup(conv);
        await db.forgetUnsettledCommit(conv);
        rethrow;
      }
      await db.forgetUnsettledCommit(conv);
      _log.info('Joined $conv at epoch ${lease.epoch + 1}');
      final previous = _selfJoins[conv];
      _selfJoins[conv] = (at: clock(), removals: previous?.removals ?? 0);
      // The GroupInfo was signed by a member; trust who it says is in the group.
      await db.addGroupUsers(conv, {for (final leaf in await _leaves(conv)) leaf.userId});
      if (held != null) await db.setGroupState(conv, roster: held.roster);
      await db.noteKeyRotation(conv, clock());
    });
    await _epochChanged(conv);
  }

  /// Joins from a Welcome found in the device inbox.
  Future<void> processWelcome(InboxItem item) async {
    final conv = item.data['conv'] as String;
    if (await mls.hasGroup(conv)) {
      _log.debug('Welcome to $conv from ${item.fromUser}/${item.fromDevice}: in its group already');
      return;
    }
    try {
      await mls.joinFromWelcome(conv, base64.decode(item.data['data'] as String));
    } on WelcomeToAnotherGroup catch (e) {
      _log.warning('Refusing a Welcome from ${item.fromUser}/${item.fromDevice}: $e');
      return;
    } catch (e) {
      _log.info(
        'Welcome to $conv (epoch ${item.data['epoch']}) from ${item.fromUser}/${item.fromDevice} not usable: $e',
      );
      return; // Stale (e.g. the device rejoined already); external join covers it.
    }
    _leafCache.remove(conv);
    if (!await _broughtByContact(await _leaves(conv), item.fromUser)) {
      _log.warning('Refusing the Welcome to $conv from ${item.fromUser}: not someone the user trusts');
      await mls.deleteGroup(conv);
      _leafCache.remove(conv);
      await db.refuseConversation(conv);
      return;
    }
    await db.unrefuseConversation(conv);
    _log.info(
      'Joined $conv from a Welcome by ${item.fromUser}/${item.fromDevice}: epoch ${await mls.epoch(conv)}, '
      'the Welcome was for ${item.data['epoch']}',
    );
    await db.addGroupUsers(conv, {for (final leaf in await _leaves(conv)) leaf.userId});
    await db.noteKeyRotation(conv, clock());
    // A new start in this group: what this device knew from an earlier time
    // in it does not count.
    await db.clearGroupState(conv);
    final sealed = item.data['state'] as String?;
    if (sealed == null) {
      stateMissing.add(conv);
    } else {
      await _takeState(conv, hash: null, opened: await _openState(conv, sealed), verified: false);
    }
    await _epochChanged(conv);
  }

  /// Takes a Welcome for [conv] that is waiting in the inbox: one can arrive
  /// after the event that made us look (e.g. pushed during catch-up), and
  /// joining from it keeps the messages sent since then readable.
  Future<void> _joinFromInbox(String conv) async {
    final welcomes = [
      for (final item in await api.inbox())
        if (item.type == InboxType.welcome && item.data['conv'] == conv) item,
    ];
    if (welcomes.isEmpty) return;
    for (final item in welcomes) {
      await processWelcome(item);
    }
    await api.ackInbox([for (final item in welcomes) item.id]);
  }

  // Processing events

  /// Applies a commit event in order. Our own commits were merged already.
  Future<void> processCommit(SyncEvent event) async {
    final conv = event.conv;
    final from = '${event.data['from']}/${event.data['device']}';
    final unsettled = await _unsettled(conv);
    if (unsettled != null && !unsettled.creating && event.data['epoch'] == unsettled.epoch) {
      // The first commit the log shows at an epoch is the one that counted.
      if (event.data['device'] == deviceId) {
        _log.info('Our commit to $conv at epoch ${unsettled.epoch} went through after all');
        await _commitCounted(conv, seq: event.seq, ts: event.ts);
      } else {
        _log.info('Commit ${event.seq} by $from counted at epoch ${unsettled.epoch}, not ours: rebuilding the group');
        await db.forgetUnsettledCommit(conv);
        needsRecovery.add(conv);
      }
      return;
    }
    if (event.data['device'] == deviceId) return;
    if (!await mls.hasGroup(conv)) {
      _log.debug('Commit ${event.seq} to $conv by $from: no group here');
      return;
    }
    final local = await mls.epoch(conv);
    final epoch = event.data['epoch'] as int;
    if (epoch < local) {
      _log.debug('Commit ${event.seq} to $conv by $from: epoch $epoch, from before we joined at $local');
      return; // From before we joined.
    }
    if (epoch > local) {
      _log.warning('Missed a commit to $conv: commit ${event.seq} by $from is at epoch $epoch, this device at $local');
      needsRecovery.add(conv); // We missed a commit.
      return;
    }
    final before = await _leaves(conv);
    final message = base64.decode(event.data['mls'] as String);
    final ProcessedMessageInspectResult result;
    try {
      result = await mls.process(conv, message);
    } catch (e) {
      _log.warning('Could not apply commit ${event.seq} to $conv by $from at epoch $epoch', e);
      needsRecovery.add(conv);
      return;
    }
    _leafCache.remove(conv);
    if (result.stagedCommitInfo?.selfRemoved ?? false) {
      _log.info('Removed from the group of $conv by $from at epoch $epoch');
      await mls.deleteGroup(conv);
      await db.clearGroupState(conv);
      await _noteRemoval(conv, by: from);
      await _epochChanged(conv);
      return;
    }
    final after = await _leaves(conv);
    if (result.senderIndex == null) {
      // External join: only users already seen in the group may add devices,
      // and in a chat of two (as MLS has it, not the server), the other one if
      // the user's own contact list has them, as for a Welcome
      // ([_broughtByContact]). A device that never saw them in it (it joined
      // while they had none there) would otherwise keep them out for good.
      final known = await db.groupUsersOf(conv);
      bool isNew(MlsLeaf leaf) => !before.any((b) => b.index == leaf.index && b.signatureKey == leaf.signatureKey);
      final unknown = {
        for (final leaf in after)
          if (isNew(leaf) && !known.contains(leaf.userId)) leaf.userId,
      };
      final others = {for (final leaf in after) leaf.userId}..remove(me);
      if (unknown.length == 1 && others.length == 1 && unknown.single == others.single) {
        if (await _onContactList(others.single)) known.add(others.single);
      }
      for (final leaf in after) {
        if (isNew(leaf) && !known.contains(leaf.userId)) {
          _log.warning('${leaf.userId}/${leaf.deviceId} joined $conv by itself, though ${leaf.userId} was never in it');
          await db.addSuspiciousLeaf(conv, leaf.signatureKey);
        }
      }
    }
    if (_log.detailed) {
      _log.debug(
        'Applied commit ${event.seq} to $conv by $from: epoch ${epoch + 1}, '
        '${result.senderIndex == null ? 'joined by itself, ' : ''}devices ${_describeLeaves(after)}',
      );
    }
    final suspicious = await db.suspiciousLeavesOf(conv);
    await db.addGroupUsers(conv, {
      for (final leaf in after)
        if (!suspicious.contains(leaf.signatureKey)) leaf.userId,
    });
    // Processing it vouched for what it says.
    CommitClaim? claim;
    try {
      claim = CommitClaim.tryParse(MlsService.authenticatedData(message));
    } on FormatException {
      claim = null;
    }
    final committer = before.where((l) => l.index == result.senderIndex).firstOrNull;
    await _takeCommitState(event, claim, by: committer?.userId ?? event.data['from'] as String);
    await _epochChanged(conv);
  }

  /// The local form of a message event: decrypted, or a placeholder that
  /// keeps the encrypted envelope for later.
  Future<ReceivedMessage> decrypt(SyncEvent event) async {
    final EncryptedEnvelope wire;
    try {
      wire = EncryptedEnvelope.fromJson(event.data);
    } on FormatException {
      return ReceivedMessage(envelope: _placeholder(event.data));
    }
    final raw = jsonEncode(event.data);
    if (wire.device == deviceId) {
      return ReceivedMessage(envelope: _placeholderFor(wire), wire: raw, own: true);
    }
    final opened = await _open(wire, log: _log.info);
    if (opened == null) {
      return ReceivedMessage(envelope: _placeholderFor(wire), wire: raw);
    }
    return ReceivedMessage(envelope: opened.envelope, contentKey: opened.contentKey);
  }

  /// Retries messages stored as placeholders (e.g. after joining a group).
  Future<int> retryUndecrypted(String conv) async {
    if (!await mls.hasGroup(conv)) return 0;
    var fixed = 0, waiting = 0;
    for (final row in await db.undecrypted(conv)) {
      final EncryptedEnvelope wire;
      try {
        wire = EncryptedEnvelope.fromJson((jsonDecode(row.wire!) as Map).cast<String, Object?>());
      } on FormatException catch (e) {
        // One message this device cannot make sense of stays a placeholder;
        // it must not keep the group's upkeep from the rest.
        _log.warning('Message ${row.id} in $conv waits for keys but is not a message this version reads: $e');
        continue;
      }
      if (wire.device == deviceId) continue;
      waiting++;
      final opened = await _open(wire, log: _log.debug);
      if (opened == null) continue;
      await db.setDecrypted(row.id, opened.envelope, opened.contentKey);
      fixed++;
    }
    if (waiting > 0) _log.debug('Retried $waiting messages waiting for keys in $conv: read $fixed');
    return fixed;
  }

  /// The message, or null (saying why with [log]) if this device cannot
  /// read it (yet).
  Future<({Envelope envelope, String contentKey})?> _open(
    EncryptedEnvelope wire, {
    required void Function(String message) log,
  }) async {
    final what = 'Cannot read ${wire.id} from ${wire.from}/${wire.device} in ${wire.conv} (epoch ${wire.epoch})';
    try {
      if (!await mls.hasGroup(wire.conv)) {
        log('$what: this device is not in its group');
        return null;
      }
      final result = await mls.process(wire.conv, wire.mls);
      if (result.messageType != ProcessedMessageType.application) {
        log('$what: it is a ${result.messageType.name}, not a message');
        return null;
      }
      // The MLS sender must be the device the header names.
      final sender = (await _leaves(wire.conv)).where((l) => l.index == result.senderIndex).firstOrNull;
      if (sender == null || sender.userId != wire.from || sender.deviceId != wire.device) {
        _log.warning('$what: the group says ${sender?.userId}/${sender?.deviceId} sent it');
        return null;
      }
      final contentKey = ContentKey.fromBytes(result.applicationMessage!);
      return (envelope: await openMessage(wire, contentKey), contentKey: base64.encode(contentKey.toBytes()));
    } catch (e) {
      log('$what, here at epoch ${await localEpoch(wire.conv)}: $e');
      return null;
    }
  }

  static Envelope _placeholderFor(EncryptedEnvelope wire) => Envelope(
    id: wire.id,
    conv: wire.conv,
    from: wire.from,
    ts: wire.ts,
    type: Envelope.encryptedType,
    body: const {},
  );

  static Envelope _placeholder(Map<String, Object?> data) => Envelope(
    id: data['id'] as String? ?? newUlid(),
    conv: data['conv'] as String? ?? '',
    from: data['from'] as String? ?? '',
    ts: data['ts'] as int? ?? 0,
    type: Envelope.encryptedType,
    body: const {},
  );

  // Sending

  /// Encrypts [message] for its conversation. Throws [SendBlocked] while the
  /// group holds a device this client does not trust.
  Future<({EncryptedEnvelope wire, String contentKey})> encrypt(
    Envelope message, {
    String type = EncryptedEnvelope.chat,
  }) async {
    final conv = message.conv;
    if (!await mls.hasGroup(conv)) throw const StaleGroup();
    final problems = await leafProblems(conv);
    if (problems.isNotEmpty) throw SendBlocked(describe(problems));
    final header = EncryptedEnvelope(
      id: message.id,
      conv: conv,
      from: me,
      device: deviceId,
      ts: message.ts,
      epoch: 0,
      mls: Uint8List(0),
      ct: Uint8List(0),
    );
    final sealed = await sealContent({'type': message.type, 'body': message.body}, header.contentAad);
    final mlsMessage = await mls.encrypt(conv, sealed.contentKey.toBytes(), aad: utf8.encode(message.id));
    return (
      wire: EncryptedEnvelope(
        id: message.id,
        conv: conv,
        from: me,
        device: deviceId,
        ts: message.ts,
        epoch: await mls.epoch(conv),
        mls: mlsMessage,
        ct: sealed.ct,
        type: type,
      ),
      contentKey: base64.encode(sealed.contentKey.toBytes()),
    );
  }

  // Keeping groups in shape

  /// Every leaf this client does not accept.
  Future<List<LeafProblem>> leafProblems(String conv) async {
    final members = (await db.memberIds(conv)).toSet();
    final suspicious = await db.suspiciousLeavesOf(conv);
    final ownIndex = await mls.ownIndex(conv);
    final problems = <LeafProblem>[];
    for (final leaf in await _leaves(conv)) {
      if (leaf.userId.isEmpty) {
        problems.add(LeafProblem(leaf, LeafProblemKind.invalidCredential));
      } else if (leaf.userId == me && leaf.deviceId == deviceId && leaf.index != ownIndex) {
        problems.add(LeafProblem(leaf, LeafProblemKind.staleOwnLeaf));
      } else if (suspicious.contains(leaf.signatureKey)) {
        problems.add(LeafProblem(leaf, LeafProblemKind.suspicious));
      } else if (members.isNotEmpty && !members.contains(leaf.userId)) {
        problems.add(LeafProblem(leaf, LeafProblemKind.notMember));
      } else {
        final trusted = await keys.devicesOf(leaf.userId);
        if (trusted.identityChanged) {
          problems.add(LeafProblem(leaf, LeafProblemKind.identityChanged));
        } else if (trusted.devices[leaf.deviceId] != leaf.signatureKey) {
          problems.add(LeafProblem(leaf, LeafProblemKind.unverified));
        }
      }
    }
    return problems;
  }

  static String describe(List<LeafProblem> problems) {
    final first = problems.firstWhere((p) => !p.routine, orElse: () => problems.first);
    return switch (first.kind) {
      LeafProblemKind.identityChanged => "${first.leaf.userId}'s security key changed. Review it before sending.",
      LeafProblemKind.notMember => 'Updating who can read this chat...',
      _ => 'An unverified device was found in this chat and is being removed.',
    };
  }

  /// Makes the group match the conversation: joins it if this device is not
  /// in it, removes leaves it does not accept, and records what still blocks
  /// sending for the UI.
  Future<void> reconcile(String conv) async {
    await _requireVerified('keeping up $conv');
    if (!await _checkUnsettled(conv)) return;
    if (needsRecovery.contains(conv)) await recover(conv);
    if (!await mls.hasGroup(conv)) {
      if (_rejoinNotBefore[conv] case final notBefore? when clock().isBefore(notBefore)) return;
      await _joinFromInbox(conv);
      await joinExternally(conv);
      if (!await mls.hasGroup(conv)) return;
    }
    var problems = await leafProblems(conv);
    final removable = problems
        .where((p) => p.removable && (p.leaf.deviceId != deviceId || p.kind == LeafProblemKind.staleOwnLeaf))
        .toList();
    if (problems.isNotEmpty) {
      _log.info(
        '$conv at epoch ${await mls.epoch(conv)}: '
        '${[for (final p in problems) '${p.leaf.userId}/${p.leaf.deviceId} ${p.kind.name}'].join(', ')}'
        '${removable.isEmpty ? '' : '; removing ${removable.length}'}',
      );
    }
    if (removable.isNotEmpty) {
      await _withLease(conv, epoch: await mls.epoch(conv), (lease) async {
        if (await mls.epoch(conv) != lease.epoch) throw const StaleGroup();
        final made = await _makeCommit(conv, remove: [for (final p in removable) p.leaf.index]);
        await _submit(conv, lease, made);
      });
      _leafCache.remove(conv);
      await db.clearSuspiciousLeaves(conv, {for (final leaf in await _leaves(conv)) leaf.signatureKey});
      problems = await leafProblems(conv);
    }
    final security = problems.where((p) => !p.routine).toList();
    await db.setSecurityIssue(conv, security.isEmpty ? null : describe(security));
  }

  /// Updates this device's keys in [conv] if they were used long enough
  /// (see [keyRotationDue]).
  Future<void> rotateKeysIfDue(String conv) async {
    if (!await mls.hasGroup(conv)) return;
    final now = clock();
    final state = await db.keyRotation(conv);
    if (state == null) return db.noteKeyRotation(conv, now);
    final rotatedAt = DateTime.fromMillisecondsSinceEpoch(state.rotatedAt);
    if (!keyRotationDue(rotatedAt: rotatedAt, sentSince: state.sentSince, now: now)) {
      return;
    }
    await _requireVerified('updating keys in $conv');
    _log.info("Updating this device's keys in $conv");
    await _withLease(conv, epoch: await mls.epoch(conv), (lease) async {
      if (await mls.epoch(conv) != lease.epoch) throw const StaleGroup();
      await _submit(conv, lease, await _makeCommit(conv));
    });
    _leafCache.remove(conv);
  }

  /// Keeps enough key packages on the server for others to add this device.
  Future<void> ensureKeyPackages() async {
    final status = await api.keyPackageCount();
    if (status.count >= 10 && status.lastResort) return;
    _log.info('Uploading key packages: ${status.count} left${status.lastResort ? '' : ', no last-resort one'}');
    await api.uploadKeyPackages(
      status.count >= 10 ? const [] : await mls.createKeyPackages(20 - status.count),
      lastResort: status.lastResort ? null : await mls.createLastResortKeyPackage(),
    );
  }
}
