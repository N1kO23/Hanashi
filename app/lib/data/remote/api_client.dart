import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../diagnostics/app_log.dart';

const _log = Log('api');

/// An error response from the server, or a network failure ([status] 0).
class ApiException implements Exception {
  const ApiException(this.status, this.code, [this.message]);

  final int status;
  final String code;
  final String? message;

  bool get isNetworkError => status == 0;
  bool get isUnauthorized => status == 401;

  /// The request itself was rejected and retrying it unchanged cannot succeed.
  bool get isPermanent =>
      status >= 400 &&
      status < 500 &&
      status != 401 &&
      status != 408 &&
      status != 429 &&
      !isClientTooOld;

  /// The server looked at nothing but this app's level, so whatever was asked
  /// was neither done nor refused: it can be done after updating the app.
  bool get isClientTooOld => code == 'client_too_old';

  @override
  String toString() =>
      message ??
      (isNetworkError ? 'Cannot reach the server' : 'Server error ($code)');
}

/// Typed client for the server's REST API (see `docs/protocol.md`).
class ApiClient {
  ApiClient(String baseUrl, {this.token, http.Client? client})
    : baseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl,
      _http = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _http;

  static const _timeout = Duration(seconds: 20);

  void close() => _http.close();

  Map<String, String> get _headers => {
    clientLevelHeader: '$clientLevel',
    if (token != null) 'authorization': 'Bearer $token',
  };

  /// Where to download [hash]; [host] is the server that has it, if not this
  /// one (see [MediaRef.host]).
  Uri mediaUri(String hash, {String? host}) =>
      Uri.parse('$baseUrl/media/$hash${host == null ? '' : '?host=${Uri.encodeQueryComponent(host)}'}');

  Uri get webSocketUri {
    final uri = Uri.parse('$baseUrl/ws');
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('$baseUrl$path').replace(queryParameters: query),
    )..headers.addAll(_headers);
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final took = Stopwatch()..start();
    // Paths and queries hold IDs only; bodies and the token are left out.
    final what = '$method $path${query == null ? '' : ' $query'}';
    try {
      final result = _decode(
        await _guard(
          () async => http.Response.fromStream(
            await _http.send(request).timeout(_timeout),
          ),
        ),
      );
      _log.debug('$what: 200 (${took.elapsedMilliseconds} ms)');
      return result;
    } on ApiException catch (e) {
      final line =
          '$what: ${e.status} ${e.code} (${took.elapsedMilliseconds} ms)';
      if (e.status >= 500) {
        _log.warning(line, e);
      } else {
        _log.debug('$line: $e');
      }
      rethrow;
    }
  }

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SocketException catch (e) {
      throw ApiException(
        0,
        'network',
        'Cannot reach the server (${e.osError?.message ?? e.message})',
      );
    } on http.ClientException catch (e) {
      throw ApiException(
        0,
        'network',
        'Cannot reach the server (${e.message})',
      );
    } on HttpException catch (e) {
      throw ApiException(0, 'network', 'Connection problem (${e.message})');
    } on TimeoutException {
      throw const ApiException(
        0,
        'timeout',
        'The server took too long to answer',
      );
    }
  }

  static Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> body = const {};
    try {
      if (response.body.isNotEmpty)
        body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } on FormatException {
      throw ApiException(
        response.statusCode,
        'bad_response',
        'Unexpected response from the server',
      );
    }
    if (response.statusCode != 200) {
      throw ApiException(
        response.statusCode,
        body['error'] as String? ?? 'error',
        body['message'] as String?,
      );
    }
    return body;
  }

  Future<ServerInfo> serverInfo() async =>
      ServerInfo.fromJson(await _send('GET', '/server'));

  /// Services such as GIF search; none on servers older than them.
  Future<Integrations> integrations() async {
    try {
      return Integrations.fromJson(await _send('GET', '/integrations'));
    } on ApiException catch (e) {
      if (e.status == 404) return const Integrations();
      rethrow;
    }
  }

  /// Joins the conversation's voice call, or starts one with [id] (so that
  /// a retry finds it again): see `docs/calls.md`.
  Future<CallJoin> joinCall(String id, String conv, {bool video = false}) async => CallJoin.fromJson(
    await _send('POST', '/calls', body: {'id': id, 'conv': conv, if (video) 'video': true}),
  );

  /// Says no to a call of two that rings this user.
  Future<Call> declineCall(String id) async =>
      Call.fromJson((await _send('POST', '/calls/$id/decline', body: const {}))['call']! as Map<String, Object?>);

  /// Hangs this device up.
  Future<Call> leaveCall(String id) async =>
      Call.fromJson((await _send('POST', '/calls/$id/leave', body: const {}))['call']! as Map<String, Object?>);

  /// The calls of the user's conversations going on, or ended in the last
  /// day. Malformed ones are left out.
  Future<List<Call>> calls() async {
    final list = (await _send('GET', '/calls'))['calls'];
    return [
      for (final json in list is List ? list : const [])
        if (json is Map) ?_tryCall(json.cast<String, Object?>()),
    ];
  }

  static Call? _tryCall(Map<String, Object?> json) {
    try {
      return Call.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  Future<AuthResult> register({
    required String name,
    required String password,
    required String deviceName,
    required String platform,
    String? inviteCode,
  }) async => AuthResult.fromJson(
    await _send(
      'POST',
      '/auth/register',
      body: {
        'name': name,
        'password': password,
        'deviceName': deviceName,
        'platform': platform,
        'inviteCode': ?inviteCode,
      },
    ),
  );

  Future<AuthResult> login({
    required String name,
    required String password,
    required String deviceName,
    required String platform,
  }) async => AuthResult.fromJson(
    await _send(
      'POST',
      '/auth/login',
      body: {
        'name': name,
        'password': password,
        'deviceName': deviceName,
        'platform': platform,
      },
    ),
  );

  Future<void> logout() => _send('POST', '/auth/logout', body: const {});

  Future<List<DeviceInfo>> devices() async => [
    for (final d in (await _send('GET', '/devices'))['devices'] as List)
      DeviceInfo.fromJson((d as Map).cast<String, Object?>()),
  ];

  Future<void> revokeDevice(String id) => _send('DELETE', '/devices/$id');

  Future<SyncSnapshot> snapshot() async =>
      SyncSnapshot.fromJson(await _send('GET', '/sync'));

  Future<SyncPage> sync(int since) async => SyncPage.fromJson(
    await _send('GET', '/sync', query: {'since': '$since'}),
  );

  Future<HistoryPage> history(
    String conv, {
    int? before,
    int limit = 50,
  }) async => HistoryPage.fromJson(
    await _send(
      'GET',
      '/conversations/$conv/messages',
      query: {'before': ?before?.toString(), 'limit': '$limit'},
    ),
  );

  /// Returns the message's seq. Safe to retry: the server deduplicates by ULID.
  /// For scripts and bots; apps send over the WebSocket.
  Future<int> postMessage(EncryptedEnvelope envelope) async =>
      (await _send('POST', '/messages', body: envelope.toJson()))['seq'] as int;

  Future<void> markRead(String conv, int upTo) =>
      _send('POST', '/conversations/$conv/read', body: {'upTo': upTo});

  /// Creates a group of the user and their contacts, whose MLS group the
  /// caller already made ([id] is the group ID).
  /// Creates a group of the user and [members], or with [direct], the direct
  /// chat of the user and the one member; if the two have one already, that
  /// one comes back instead.
  Future<ConversationInfo> createConversation({
    required String id,
    required List<String> members,
    required NewGroup group,
    bool direct = false,
  }) async => ConversationInfo.fromJson(
    await _send(
      'POST',
      '/conversations',
      body: {
        'id': id,
        'members': members,
        if (direct) 'direct': true,
        'mls': group.toJson(),
      },
    ),
  );

  // Contacts

  Future<List<ContactInfo>> contacts() async => [
    for (final c in (await _send('GET', '/contacts'))['contacts'] as List)
      ContactInfo.fromJson((c as Map).cast<String, Object?>()),
  ];

  /// Asks [userId] to become a contact; how the two stand now. [ContactState.incoming]:
  /// they asked first, and the caller answers instead.
  Future<ContactState> requestContact(String userId) async =>
      ContactState.parse(
        (await _send(
          'POST',
          '/contacts/requests',
          body: {'user': userId},
        ))['state'],
      );

  /// Says yes to [userId]: the two become contacts. Their direct chat is a step
  /// of its own ([createConversation]).
  Future<void> acceptContact(String userId) => _send(
    'POST',
    '/contacts/requests/${Uri.encodeComponent(userId)}/accept',
    body: const {},
  );

  Future<void> declineContact(String userId) => _send(
    'POST',
    '/contacts/requests/${Uri.encodeComponent(userId)}/decline',
    body: const {},
  );

  Future<void> cancelContactRequest(String userId) =>
      _send('DELETE', '/contacts/requests/${Uri.encodeComponent(userId)}');

  Future<void> removeContact(String userId) =>
      _send('DELETE', '/contacts/${Uri.encodeComponent(userId)}');

  Future<void> blockContact(String userId) =>
      _send('PUT', '/blocked/${Uri.encodeComponent(userId)}', body: const {});

  Future<void> unblockContact(String userId) =>
      _send('DELETE', '/blocked/${Uri.encodeComponent(userId)}');

  // Profiles

  /// [userId]'s record, as JSON; null if they have none or this user may not
  /// see it.
  Future<Map<String, Object?>?> profile(String userId) async {
    try {
      return await _send(
        'GET',
        '/users/${Uri.encodeComponent(userId)}/profile',
      );
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Fails with `stale_version` unless it is newer than the one stored.
  Future<void> putProfile(Map<String, Object?> record) =>
      _send('PUT', '/profile', body: record);

  /// Adds [userId] together with the commit adding their devices.
  Future<ConversationInfo> addMember(
    String conv,
    String userId,
    Commit commit,
  ) async => ConversationInfo.fromJson(
    await _send(
      'POST',
      '/conversations/$conv/members',
      body: {'user': userId, 'commit': commit.toJson()},
    ),
  );

  // MLS delivery

  /// With [epoch] (where this device's group is), refused with
  /// `epoch_mismatch` instead if the conversation moved on.
  Future<Lease> lease(String conv, {int? epoch}) async => Lease.fromJson(
    await _send('POST', '/conversations/$conv/lease', body: {'epoch': ?epoch}),
  );

  Future<void> releaseLease(String conv, Lease lease) =>
      _send('DELETE', '/conversations/$conv/lease/${lease.id}');

  Future<int> commit(String conv, Commit commit) async =>
      (await _send(
            'POST',
            '/conversations/$conv/commits',
            body: commit.toJson(),
          ))['seq']
          as int;

  Future<({int epoch, Uint8List data, String? state})> groupInfo(
    String conv,
  ) async {
    final json = await _send('GET', '/conversations/$conv/group-info');
    return (
      epoch: json['epoch'] as int,
      data: base64.decode(json['data'] as String),
      state: json['state'] as String?,
    );
  }

  /// Hands in the group's state sealed for [epoch], whose commit came without
  /// it. Fails with `state_exists` if another member was faster.
  Future<void> putGroupState(
    String conv, {
    required int epoch,
    required String sealed,
  }) => _send(
    'PUT',
    '/conversations/$conv/state',
    body: {'epoch': epoch, 'data': sealed},
  );

  Future<({int count, bool lastResort})> keyPackageCount() async {
    final json = await _send('GET', '/keys/packages/count');
    return (
      count: json['count'] as int,
      lastResort: json['lastResort'] as bool,
    );
  }

  Future<void> uploadKeyPackages(List<String> packages, {String? lastResort}) =>
      _send(
        'POST',
        '/keys/packages',
        body: {'packages': packages, 'lastResort': ?lastResort},
      );

  /// One key package per device that has any left.
  Future<Map<String, Uint8List>> claimKeyPackages(
    List<String> deviceIds,
  ) async {
    if (deviceIds.isEmpty) return const {};
    final json = await _send(
      'POST',
      '/keys/packages/claim',
      body: {'devices': deviceIds},
    );
    return {
      for (final e in (json['packages'] as Map).cast<String, Object?>().entries)
        e.key: base64.decode(e.value as String),
    };
  }

  Future<List<InboxItem>> inbox() async => [
    for (final item in (await _send('GET', '/inbox'))['items'] as List)
      InboxItem.fromJson((item as Map).cast<String, Object?>()),
  ];

  Future<void> ackInbox(List<int> ids) =>
      _send('POST', '/inbox/ack', body: {'ids': ids});

  /// Tells the server where to wake this device (a Web Push endpoint) and
  /// the keys (base64url) to encrypt for it.
  Future<void> putPushSubscription({
    required String endpoint,
    String? p256dh,
    String? auth,
  }) => _send(
    'PUT',
    '/push/subscription',
    body: {
      'endpoint': endpoint,
      if (p256dh != null && auth != null)
        'keys': {'p256dh': p256dh, 'auth': auth},
    },
  );

  Future<void> deletePushSubscription() =>
      _send('DELETE', '/push/subscription');

  /// Sends a verification message to device inboxes: all devices of a user
  /// (without `device`), or one. Only to one's own devices or to contacts.
  Future<int> sendToDevices({
    required List<({String user, String? device})> to,
    required String type,
    required Map<String, Object?> data,
  }) async =>
      (await _send(
            'POST',
            '/inbox/send',
            body: {
              'to': [
                for (final t in to) {'user': t.user, 'device': ?t.device},
              ],
              'type': type,
              'data': data,
            },
          ))['delivered']
          as int;

  /// The user's signed statements about whom they verified, by user.
  Future<Map<String, String>> attestations() async =>
      ((await _send('GET', '/keys/attestations'))['attestations'] as Map)
          .cast<String, String>();

  Future<void> putAttestation(String userId, String data) => _send(
    'PUT',
    '/keys/attestations/${Uri.encodeComponent(userId)}',
    body: {'data': data},
  );

  Future<void> deleteAttestation(String userId) =>
      _send('DELETE', '/keys/attestations/${Uri.encodeComponent(userId)}');

  /// Leaves a group conversation.
  Future<void> leaveConversation(String conv) => _send(
    'POST',
    '/conversations/${Uri.encodeComponent(conv)}/leave',
    body: {},
  );

  /// Stores encrypted content keys (message ID -> entry) in the account's
  /// key backup; [identityVersion] is the identity they were made for.
  /// Returns how many the server accepted.
  Future<int> putKeyBackup({
    required int identityVersion,
    required Map<String, String> entries,
  }) async =>
      (await _send(
            'POST',
            '/keys/backup',
            body: {
              'identityVersion': identityVersion,
              'entries': [
                for (final MapEntry(:key, :value) in entries.entries)
                  {'id': key, 'data': value},
              ],
            },
          ))['accepted']
          as int;

  /// How the user appears to others (see [PresenceMode]).
  Future<void> setPresenceMode(PresenceMode mode) =>
      _send('PUT', '/presence', body: {'mode': mode.name});

  /// How the user chose to appear, for a device without a connection to hear it on.
  Future<PresenceMode> presenceMode() async =>
      PresenceMode.parse((await _send('GET', '/presence'))['mode']);

  /// Backup entries for [messageIds] (at most 500); messages without one are left out.
  Future<Map<String, String>> queryKeyBackup(List<String> messageIds) async =>
      ((await _send(
                'POST',
                '/keys/backup/query',
                body: {'ids': messageIds},
              ))['entries']
              as Map)
          .cast<String, String>();

  /// Up to 500 backup entries for [conv]'s messages after seq [after], oldest first.
  Future<({List<({String id, int seq, String data})> entries, bool more})>
  conversationKeyBackup(String conv, {int after = 0}) async {
    final page = await _send(
      'GET',
      '/keys/backup',
      query: {'conv': conv, 'after': '$after'},
    );
    return (
      entries: [
        for (final e in (page['entries'] as List).cast<Map<String, Object?>>())
          (
            id: e['id'] as String,
            seq: e['seq'] as int,
            data: e['data'] as String,
          ),
      ],
      more: page['more'] as bool,
    );
  }

  Future<MemberInfo> user(String id) async => MemberInfo.fromJson(
    await _send('GET', '/users/${Uri.encodeComponent(id)}'),
  );

  /// Drops the server's copies of the user's own messages among [ids] (they
  /// were deleted for everyone); returns how many went.
  Future<int> deleteMessages(List<String> ids) async =>
      (await _send('POST', '/messages/delete', body: {'ids': ids}))['deleted']
          as int;

  // Key directory

  /// Publishes this account's identity key; returns its version. A different
  /// key than the current one needs [reset].
  Future<int> putIdentity(String identityKey, {bool reset = false}) async =>
      (await _send(
            'PUT',
            '/keys/identity',
            body: {'identityKey': identityKey, 'reset': reset},
          ))['identityVersion']
          as int;

  /// Registers this device's MLS signature key (base64).
  Future<void> putDeviceKey(String mlsSigKey) =>
      _send('PUT', '/keys/device', body: {'mlsSigKey': mlsSigKey});

  Future<void> putDeviceSignature(String deviceId, String signature) => _send(
    'PUT',
    '/keys/devices/$deviceId/signature',
    body: {'signature': signature},
  );

  Future<UserKeys> userKeys(String userId) async => UserKeys.fromJson(
    await _send('GET', '/keys/users/${Uri.encodeComponent(userId)}'),
  );

  /// One of the user's account data blobs (encrypted by their devices), with
  /// its version; null if there is none.
  Future<({String data, int version})?> accountData(String name) async {
    try {
      final json = await _send(
        'GET',
        '/account-data/${Uri.encodeComponent(name)}',
      );
      return (data: json['data'] as String, version: json['version'] as int);
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Fails with `version_conflict` unless the blob is still at [version] (0:
  /// there is none yet). Use [AccountData], which retries.
  Future<void> putAccountData(
    String name,
    String data, {
    required int version,
  }) => _send(
    'PUT',
    '/account-data/${Uri.encodeComponent(name)}',
    body: {'data': data, 'version': version},
  );

  /// The secrets blob sealed with the recovery key; null if none is stored.
  Future<({String data, int identityVersion})?> secretStorage() async {
    try {
      final json = await _send('GET', '/keys/secret-storage');
      return (
        data: json['data'] as String,
        identityVersion: json['identityVersion'] as int,
      );
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<void> putSecretStorage(String data, int identityVersion) => _send(
    'PUT',
    '/keys/secret-storage',
    body: {'data': data, 'identityVersion': identityVersion},
  );

  /// Starts downloading a media blob, which this server fetches from [host]'s
  /// first if it is another's. The caller consumes the body stream.
  Future<http.StreamedResponse> openMedia(String hash, {String? host}) async {
    final request = http.Request('GET', mediaUri(hash, host: host))
      ..headers.addAll(_headers);
    final response = await _guard(() => _http.send(request).timeout(_timeout));
    _log.debug('GET /media/$hash: ${response.statusCode}');
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ApiException(
        response.statusCode,
        'media_unavailable',
        'The file is not available',
      );
    }
    return response;
  }

  /// Uploads a file; the server stores it under its SHA-256 and deduplicates.
  Future<String> uploadFile(File file, String mime) async {
    final request = http.StreamedRequest('POST', Uri.parse('$baseUrl/media'))
      ..headers.addAll(_headers)
      ..headers['content-type'] = mime
      ..contentLength = await file.length();
    final response = _guard(
      () async => http.Response.fromStream(await _http.send(request)),
    );
    await file.openRead().forEach(request.sink.add);
    await request.sink.close();
    final hash = _decode(await response)['hash'] as String;
    _log.debug('POST /media: $hash (${request.contentLength} bytes)');
    return hash;
  }
}

class Lease {
  const Lease({required this.id, required this.epoch});

  final String id;
  final int epoch;

  factory Lease.fromJson(Map<String, Object?> json) =>
      Lease(id: json['leaseId'] as String, epoch: json['epoch'] as int);
}

class Welcome {
  const Welcome({required this.device, required this.data});

  final String device;
  final Uint8List data;

  Map<String, Object?> toJson() => {
    'device': device,
    'data': base64.encode(data),
  };

  factory Welcome.fromJson(Map<String, Object?> json) => Welcome(
    device: json['device'] as String,
    data: base64.decode(json['data'] as String),
  );
}

/// An MLS group its creator made, for the server to store with its conversation.
class NewGroup {
  const NewGroup({
    required this.epoch,
    required this.groupInfo,
    this.state,
    this.welcomes = const [],
  });

  final int epoch;
  final Uint8List groupInfo;

  /// The group's state sealed for [epoch].
  final String? state;
  final List<Welcome> welcomes;

  Map<String, Object?> toJson() => {
    'epoch': epoch,
    'groupInfo': base64.encode(groupInfo),
    'state': ?state,
    'welcomes': [for (final w in welcomes) w.toJson()],
  };

  factory NewGroup.fromJson(Map<String, Object?> json) => NewGroup(
    epoch: json['epoch'] as int,
    groupInfo: base64.decode(json['groupInfo'] as String),
    state: json['state'] as String?,
    welcomes: [
      for (final w in json['welcomes'] as List)
        Welcome.fromJson((w as Map).cast<String, Object?>()),
    ],
  );
}

/// An MLS commit for the server to order, made under [leaseId] at [epoch].
class Commit {
  const Commit({
    required this.leaseId,
    required this.epoch,
    required this.mls,
    required this.groupInfo,
    this.state,
    this.welcomes = const [],
  });

  final String leaseId;
  final int epoch;
  final Uint8List mls;
  final Uint8List groupInfo;

  /// The group's state sealed for the epoch this commit starts; null from a
  /// device that does not hold it.
  final String? state;
  final List<Welcome> welcomes;

  Map<String, Object?> toJson() => {
    'leaseId': leaseId,
    'epoch': epoch,
    'mls': base64.encode(mls),
    'groupInfo': base64.encode(groupInfo),
    'state': ?state,
    'welcomes': [for (final w in welcomes) w.toJson()],
  };
}

class InboxItem {
  const InboxItem({
    required this.id,
    required this.type,
    required this.fromUser,
    required this.fromDevice,
    required this.data,
    this.createdAt = 0,
  });

  final int id;
  final String type;
  final String fromUser;
  final String fromDevice;
  final Map<String, Object?> data;

  /// Server time, milliseconds since the epoch.
  final int createdAt;

  factory InboxItem.fromJson(Map<String, Object?> json) => InboxItem(
    id: json['id'] as int,
    type: json['type'] as String,
    fromUser: json['fromUser'] as String,
    fromDevice: json['fromDevice'] as String,
    data: (json['data'] as Map).cast<String, Object?>(),
    createdAt: json['createdAt'] as int? ?? 0,
  );
}
