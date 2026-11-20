import 'envelope.dart';
import 'ulid.dart';

/// Types of [SyncEvent]. Every change a device needs to mirror is one event.
abstract final class EventType {
  /// `data` is an [Envelope].
  static const message = 'message';

  /// `data`: `{"conversation": ConversationInfo, "by": userId}`.
  static const conversationCreated = 'conversation_created';

  /// `data`: `{"conversation": ConversationInfo, "user": userId, "by": userId}`.
  /// The added user receives it too and learns about the conversation from it.
  static const memberAdded = 'member_added';

  /// `data`: `{"conversation": ConversationInfo, "user": userId}`. The removed
  /// user receives it as well, and should drop the conversation locally.
  static const memberRemoved = 'member_removed';

  /// `data`: `{"user": userId, "upTo": seq}`. Only delivered to that user's
  /// own devices; keeps read state (unread badges) in sync between them.
  static const readMarker = 'read_marker';

  /// `data`: `{"user": userId}`. User-level (empty `conv`): the user's
  /// identity or device keys changed; refetch `GET /keys/users/{user}`.
  static const deviceKeysChanged = 'device_keys_changed';

  /// `data`: `{"user": userId, "version"}`. User-level (empty `conv`): the
  /// user published a new profile; fetch `GET /users/{user}/profile`.
  static const profileChanged = 'profile_changed';

  /// `data`: `{"user": userId, "state"}`. User-level (empty `conv`): how this
  /// user and that one stand now (see [ContactState]).
  static const contactChanged = 'contact_changed';

  /// `data`: `{"epoch", "mls", "from", "device", "state"?}`: an MLS commit that
  /// every member device processes in order, with the group's state sealed
  /// for the epoch it starts.
  static const mlsCommit = 'mls_commit';

  /// `data`: `{"epoch", "data", "from", "device"}`: a member sealed the group's
  /// state for an epoch whose commit came without it.
  static const groupState = 'group_state';

  /// `data` is an `EncryptedEnvelope` of type `mls.control`: for members'
  /// devices to act on, not part of the conversation's history.
  static const control = 'control';
}

/// Types of device inbox items.
abstract final class InboxType {
  /// `data`: `{"conv", "epoch", "data"}` with a base64 MLS Welcome.
  static const welcome = 'mls.welcome';
}

/// One entry of the server's event log. [seq] is global and strictly
/// increasing; a device stores the highest seq it has applied as its cursor.
/// Seqs of events in conversations the user is not part of are skipped, so
/// gaps are normal.
class SyncEvent {
  const SyncEvent({
    required this.seq,
    required this.type,
    required this.conv,
    required this.ts,
    required this.data,
  });

  final int seq;
  final String type;
  final String conv;

  /// Server clock, milliseconds since the Unix epoch.
  final int ts;
  final Map<String, Object?> data;

  factory SyncEvent.fromJson(Map<String, Object?> json) => SyncEvent(
    seq: json['seq'] as int,
    type: json['type'] as String,
    conv: json['conv'] as String,
    ts: json['ts'] as int,
    data: (json['data'] as Map).cast<String, Object?>(),
  );

  Map<String, Object?> toJson() => {
    'seq': seq,
    'type': type,
    'conv': conv,
    'ts': ts,
    'data': data,
  };

  Envelope get envelope => Envelope.fromJson(data);

  ConversationInfo? get conversation {
    final c = data['conversation'];
    return c == null
        ? null
        : ConversationInfo.fromJson((c as Map).cast<String, Object?>());
  }
}

class MemberInfo {
  const MemberInfo({required this.id});

  final String id;

  factory MemberInfo.fromJson(Map<String, Object?> json) => MemberInfo(id: json['id'] as String);

  Map<String, Object?> toJson() => {'id': id};
}

/// How the server sees a conversation: who is in it. What it is called, its
/// members know from its sealed state.
class ConversationInfo {
  const ConversationInfo({required this.id, required this.isDirect, required this.members});

  final String id;
  final bool isDirect;
  final List<MemberInfo> members;

  factory ConversationInfo.fromJson(Map<String, Object?> json) => ConversationInfo(
    id: json['id'] as String,
    isDirect: json['isDirect'] as bool,
    members: [
      for (final m in json['members'] as List) MemberInfo.fromJson((m as Map).cast<String, Object?>()),
    ],
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'isDirect': isDirect,
    'members': [for (final m in members) m.toJson()],
  };
}

/// How a user stands with someone else, in `GET /contacts`. Being declined or
/// blocked looks to the one asking just like [outgoing].
enum ContactState {
  none,
  accepted,

  /// The user asked them.
  outgoing,

  /// They asked the user.
  incoming,

  /// The user blocked them.
  blocked;

  /// States added later count as none.
  static ContactState parse(Object? value) => values.firstWhere((s) => s.name == value, orElse: () => none);
}

/// One line of `GET /contacts`.
class ContactInfo {
  const ContactInfo({required this.user, required this.state, this.since = 0});

  final String user;
  final ContactState state;

  /// Server time, milliseconds since the epoch.
  final int since;

  factory ContactInfo.fromJson(Map<String, Object?> json) => ContactInfo(
    user: json['user'] as String,
    state: ContactState.parse(json['state']),
    since: json['since'] as int? ?? 0,
  );
}

/// Result of `GET /sync?since=<cursor>`.
class SyncPage {
  const SyncPage({
    required this.events,
    required this.cursor,
    required this.more,
  });

  final List<SyncEvent> events;

  /// Cursor to store after applying [events].
  final int cursor;

  /// More events are waiting; request again with the new [cursor].
  final bool more;

  factory SyncPage.fromJson(Map<String, Object?> json) => SyncPage(
    events: [
      for (final e in json['events'] as List)
        SyncEvent.fromJson((e as Map).cast<String, Object?>()),
    ],
    cursor: json['cursor'] as int,
    more: json['more'] as bool,
  );

  Map<String, Object?> toJson() => {
    'events': [for (final e in events) e.toJson()],
    'cursor': cursor,
    'more': more,
  };
}

/// One conversation in a [SyncSnapshot].
class ConversationSnapshot {
  const ConversationSnapshot({
    required this.conversation,
    required this.readUpTo,
    required this.messages,
    required this.moreHistory,
  });

  final ConversationInfo conversation;
  final int readUpTo;

  /// The latest messages, oldest first.
  final List<SyncEvent> messages;

  /// Older messages exist; fetch them with `GET /conversations/{id}/messages?before=`.
  final bool moreHistory;

  factory ConversationSnapshot.fromJson(Map<String, Object?> json) =>
      ConversationSnapshot(
        conversation: ConversationInfo.fromJson(
          (json['conversation'] as Map).cast<String, Object?>(),
        ),
        readUpTo: json['readUpTo'] as int,
        messages: [
          for (final e in json['messages'] as List)
            SyncEvent.fromJson((e as Map).cast<String, Object?>()),
        ],
        moreHistory: json['moreHistory'] as bool,
      );

  Map<String, Object?> toJson() => {
    'conversation': conversation.toJson(),
    'readUpTo': readUpTo,
    'messages': [for (final e in messages) e.toJson()],
    'moreHistory': moreHistory,
  };
}

/// Result of `GET /sync` without a cursor: everything a fresh device needs.
class SyncSnapshot {
  const SyncSnapshot({required this.cursor, required this.conversations});

  final int cursor;
  final List<ConversationSnapshot> conversations;

  factory SyncSnapshot.fromJson(Map<String, Object?> json) => SyncSnapshot(
    cursor: json['cursor'] as int,
    conversations: [
      for (final c in json['conversations'] as List)
        ConversationSnapshot.fromJson((c as Map).cast<String, Object?>()),
    ],
  );

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    'conversations': [for (final c in conversations) c.toJson()],
  };
}

/// Result of `GET /conversations/{id}/messages?before=<seq>`.
class HistoryPage {
  const HistoryPage({required this.messages, required this.more});

  /// Oldest first.
  final List<SyncEvent> messages;
  final bool more;

  factory HistoryPage.fromJson(Map<String, Object?> json) => HistoryPage(
    messages: [
      for (final e in json['messages'] as List)
        SyncEvent.fromJson((e as Map).cast<String, Object?>()),
    ],
    more: json['more'] as bool,
  );

  Map<String, Object?> toJson() => {
    'messages': [for (final e in messages) e.toJson()],
    'more': more,
  };
}

/// Result of register and login.
class AuthResult {
  const AuthResult({
    required this.userId,
    required this.token,
    required this.deviceId,
  });

  final String userId;

  /// Bearer token for this device only.
  final String token;
  final String deviceId;

  factory AuthResult.fromJson(Map<String, Object?> json) => AuthResult(
    userId: json['userId'] as String,
    token: json['token'] as String,
    deviceId: json['deviceId'] as String,
  );

  Map<String, Object?> toJson() => {
    'userId': userId,
    'token': token,
    'deviceId': deviceId,
  };
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
    required this.current,
  });

  final String id;
  final String name;
  final String platform;
  final int createdAt;
  final int lastSeenAt;

  /// The device making the request.
  final bool current;

  factory DeviceInfo.fromJson(Map<String, Object?> json) => DeviceInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String,
    createdAt: json['createdAt'] as int,
    lastSeenAt: json['lastSeenAt'] as int,
    current: json['current'] as bool,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'createdAt': createdAt,
    'lastSeenAt': lastSeenAt,
    'current': current,
  };
}

/// What this app can do, as a number: servers refuse apps below their
/// [ServerInfo.minClient]. Not the app's version; see `docs/protocol.md`.
const clientLevel = 5;

/// The HTTP header that says [clientLevel].
const clientLevelHeader = 'x-hanashi-client';

/// Public server information from `GET /server`, shown on the login screen.
class ServerInfo {
  const ServerInfo({
    required this.host,
    required this.version,
    required this.registration,
    required this.maxUploadBytes,
    this.minClient = 0,
    this.vapidKey,
  });

  /// The host part of user IDs on this server.
  final String host;
  final String version;

  /// `open`, `invite` or `closed`.
  final String registration;
  final int maxUploadBytes;

  /// The lowest [clientLevel] this server takes.
  final int minClient;

  /// The server's Web Push (VAPID) key that push subscriptions are made
  /// for: base64url of a P-256 point. Null on servers without push.
  final String? vapidKey;

  factory ServerInfo.fromJson(Map<String, Object?> json) => ServerInfo(
    host: json['host'] as String,
    version: json['version'] as String,
    registration: json['registration'] as String,
    maxUploadBytes: json['maxUploadBytes'] as int,
    minClient: json['minClient'] as int? ?? 0,
    vapidKey: switch (json['vapidKey']) {
      final String key when key.isNotEmpty => key,
      _ => null,
    },
  );

  Map<String, Object?> toJson() => {
    'host': host,
    'version': version,
    'registration': registration,
    'maxUploadBytes': maxUploadBytes,
    'minClient': minClient,
    'vapidKey': ?vapidKey,
  };
}

/// Services the server's operator set up for its users
/// (`GET /integrations`, signed in only).
class Integrations {
  const Integrations({this.klipyApiKey, this.calls = false, this.video = false});

  /// KLIPY's API key for GIF search. Apps call KLIPY with it themselves:
  /// KLIPY does not allow calls through a server.
  final String? klipyApiKey;

  /// The server carries voice calls (see [Call]).
  final bool calls;

  /// Calls may carry cameras and shared screens too, and a call of two may
  /// be a video call ([Call.video]).
  final bool video;

  factory Integrations.fromJson(Map<String, Object?> json) => Integrations(
    klipyApiKey: switch (json['klipyApiKey']) {
      final String key when key.isNotEmpty => key,
      _ => null,
    },
    calls: json['calls'] == true,
    video: json['video'] == true,
  );

  Map<String, Object?> toJson() => {
    'klipyApiKey': ?klipyApiKey,
    if (calls) 'calls': true,
    if (video) 'video': true,
  };
}

/// Why a [Call] ended.
abstract final class CallEnd {
  /// Everyone hung up.
  static const ended = 'ended';

  /// The one a call of two rang said no.
  static const declined = 'declined';

  /// Nobody answered a call of two in time.
  static const missed = 'missed';

  /// Whoever started a call of two hung up before an answer.
  static const cancelled = 'cancelled';

  /// Nobody got into the call.
  static const failed = 'failed';
}

/// A conversation's voice call, as the server says (`GET /calls`, the `call`
/// frame). The audio goes through the server's LiveKit, end-to-end encrypted
/// by the apps; the server knows who is in the call, not what is said.
class Call {
  const Call({
    required this.id,
    required this.conv,
    required this.direct,
    required this.startedBy,
    required this.startedDevice,
    required this.startedAt,
    required this.version,
    this.video = false,
    this.ringUntil,
    this.answeredAt,
    this.endedAt,
    this.reason,
    this.participants = const [],
  });

  final String id;
  final String conv;

  /// The call of a chat of two, which rings.
  final bool direct;

  /// Started as a video call: its devices start with their cameras on.
  final bool video;
  final String startedBy;
  final String startedDevice;
  final DateTime startedAt;

  /// When a call of two nobody answered is missed.
  final DateTime? ringUntil;
  final DateTime? answeredAt;
  final DateTime? endedAt;

  /// Why it ended: one of [CallEnd]'s, or another of a later version.
  final String? reason;

  /// Goes up with every change: the latest is the one with the highest.
  final int version;

  /// The devices in the call.
  final List<CallParticipant> participants;

  bool get active => endedAt == null;

  /// The users with a device in the call.
  Set<String> get users => {for (final p in participants) p.user};

  /// Ringing for the one a call of two rings: going on, and not answered.
  bool get unanswered => direct && active && answeredAt == null;

  /// Throws [FormatException] for one that is malformed.
  factory Call.fromJson(Map<String, Object?> json) {
    DateTime? time(String key) => switch (json[key]) {
      final int ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms),
      null || 0 => null,
      final other => throw FormatException('call.$key must be a time', other),
    };
    final (id, conv, startedBy, startedDevice) = (json['id'], json['conv'], json['startedBy'], json['startedDevice']);
    if (id is! String || !isUlid(id)) throw FormatException('call.id must be a ULID', id);
    if (conv is! String || conv.isEmpty) throw FormatException('call.conv must be a string', conv);
    if (startedBy is! String || startedDevice is! String) throw const FormatException('call needs who started it');
    final started = time('startedAt');
    if (started == null) throw const FormatException('call.startedAt must be a time');
    final participants = json['participants'];
    return Call(
      id: id,
      conv: conv,
      direct: json['direct'] == true,
      video: json['video'] == true,
      startedBy: startedBy,
      startedDevice: startedDevice,
      startedAt: started,
      ringUntil: time('ringUntil'),
      answeredAt: time('answeredAt'),
      endedAt: time('endedAt'),
      reason: json['reason'] is String ? json['reason'] as String : null,
      version: json['version'] is int ? json['version'] as int : 0,
      participants: [
        for (final p in participants is List ? participants : const [])
          if (p is Map) CallParticipant.fromJson(p.cast<String, Object?>()),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'conv': conv,
    'direct': direct,
    if (video) 'video': true,
    'startedBy': startedBy,
    'startedDevice': startedDevice,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'ringUntil': ?ringUntil?.millisecondsSinceEpoch,
    'answeredAt': ?answeredAt?.millisecondsSinceEpoch,
    'endedAt': ?endedAt?.millisecondsSinceEpoch,
    'reason': ?reason,
    'version': version,
    'participants': [for (final p in participants) p.toJson()],
  };
}

/// A device of a user in a [Call].
class CallParticipant {
  const CallParticipant({required this.user, required this.device, required this.joinedAt});

  final String user;
  final String device;
  final DateTime joinedAt;

  factory CallParticipant.fromJson(Map<String, Object?> json) {
    final (user, device, joinedAt) = (json['user'], json['device'], json['joinedAt']);
    if (user is! String || device is! String || joinedAt is! int) {
      throw const FormatException('call participant needs user, device and joinedAt');
    }
    return CallParticipant(user: user, device: device, joinedAt: DateTime.fromMillisecondsSinceEpoch(joinedAt));
  }

  Map<String, Object?> toJson() => {'user': user, 'device': device, 'joinedAt': joinedAt.millisecondsSinceEpoch};
}

/// The answer to joining or starting a call (`POST /calls`): the call, and
/// where and with what to get into its LiveKit room.
class CallJoin {
  const CallJoin({required this.call, required this.url, required this.token});

  final Call call;
  final String url;
  final String token;

  factory CallJoin.fromJson(Map<String, Object?> json) {
    final livekit = json['livekit'];
    final call = json['call'];
    if (call is! Map || livekit is! Map || livekit['url'] is! String || livekit['token'] is! String) {
      throw const FormatException('call join needs the call, and livekit url and token');
    }
    return CallJoin(
      call: Call.fromJson(call.cast<String, Object?>()),
      url: livekit['url'] as String,
      token: livekit['token'] as String,
    );
  }
}

/// WebSocket frame types. Every frame is a JSON object with a `type` field.
abstract final class Frame {
  /// Client -> server, first frame: `{"type":"auth","token":"...","client":clientLevel}`.
  static const auth = 'auth';

  /// Server -> client after successful auth: `{"type":"ready"}`. Events
  /// committed after this frame are pushed live; the client then catches up
  /// on anything older with `GET /sync`.
  static const ready = 'ready';

  /// Server -> client: `{"type":"event","event":SyncEvent}`.
  static const event = 'event';

  /// Client -> server: `{"type":"send","rid":"...","envelope":Envelope}`.
  /// Answered with an [ack] carrying `"seq"`, or a [nack].
  static const send = 'send';

  /// Client -> server: `{"type":"read","rid":"...","conv":"...","upTo":seq}`.
  /// Answered with an [ack] carrying `"readUpTo"`, or a [nack].
  static const read = 'read';

  /// Server -> client: success for the request with the same `"rid"`.
  static const ack = 'ack';

  /// Server -> client: `{"type":"nack","rid":"...","error":code,"status":httpStatus,"message"?}`.
  static const nack = 'nack';

  /// Both directions: `{"type":"typing","conv":"..."}` (server adds "user").
  /// Ephemeral; never stored or synced.
  static const typing = 'typing';

  /// Server -> client before closing: `{"type":"error","error":"..."}`.
  static const error = 'error';

  /// Client -> server: `{"type":"commit","rid","conv","commit":{leaseId, epoch, mls, groupInfo, state, welcomes}}`.
  static const commit = 'commit';

  /// Server -> client: `{"type":"inbox","item":{id, type, fromUser, fromDevice, data}}`.
  static const inbox = 'inbox';

  /// Server -> client: `{"type":"backup"}`. The account's key backup gained
  /// entries (from another device), so waiting messages may be readable now.
  static const backup = 'backup';

  /// Server -> client: `{"type":"trust"}`. The user's attestations (whom
  /// they verified) changed on another device.
  static const trust = 'trust';

  /// Server -> client: `{"type":"account_data","name":"..."}`. Another device
  /// of the user changed one of their account data blobs.
  static const accountData = 'account_data';

  /// Server -> client: a user's [Presence], `{"type":"presence","user","status"}`
  /// (with their [PresenceMode] as `"mode"` for the user's own devices), or
  /// everyone's who is not offline, `{"type":"presence","statuses":{user: status},"mode"}`.
  /// Client -> server: `{"type":"presence","state":"active"|"idle"}`, whether
  /// the device is in use, or without `"state"`, a request for everyone's again.
  static const presence = 'presence';

  /// Server -> client: `{"type":"call","call":Call}`. A call in one of the
  /// user's conversations changed. Live only: apps ask `GET /calls` when they
  /// connect.
  static const call = 'call';
}

/// What others see of a user right now. Never stored; sent live only.
enum Presence {
  online,
  idle,
  focus,
  offline;

  /// Statuses added later show as offline.
  static Presence parse(Object? value) => values.firstWhere((p) => p.name == value, orElse: () => offline);
}

/// How a user chose to appear: [auto] is online while one of their devices
/// is in use and idle otherwise; [invisible] is offline to everyone else.
enum PresenceMode {
  auto,
  focus,
  invisible;

  static PresenceMode parse(Object? value) => values.firstWhere((m) => m.name == value, orElse: () => auto);
}
