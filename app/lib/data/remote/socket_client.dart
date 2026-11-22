import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../diagnostics/app_log.dart';
import '../models.dart';
import 'api_client.dart';

const _log = Log('socket');

/// Keeps one authenticated WebSocket open, reconnecting with exponential
/// backoff. Reports live events; the caller does catch-up via REST each time
/// [onReady] fires. Messages and read markers are sent over this socket as
/// requests that the server answers with an ack or nack.
class SocketClient {
  SocketClient({
    required this.uri,
    required this.token,
    required this.onReady,
    required this.onEvent,
    required this.onInbox,
    required this.onRevoked,
    this.onTyping,
    this.onBackup,
    this.onTrust,
    this.onAccountData,
    this.onPresence,
    this.onCall,
  });

  final Uri uri;
  final String token;
  final Future<void> Function() onReady;
  final void Function(SyncEvent event) onEvent;
  final void Function(InboxItem item) onInbox;
  final void Function() onRevoked;
  final void Function(String conv, String user)? onTyping;

  /// Another device added to the key backup.
  final void Function()? onBackup;

  /// Another device of the user verified someone.
  final void Function()? onTrust;

  /// Another device of the user changed the account data called `name`.
  final void Function(String name)? onAccountData;

  /// Who is online: one user's status, or with [all], everyone's who is not
  /// offline. [mode] is the user's own, told to their own devices.
  final void Function(Map<String, Presence> statuses, {required bool all, PresenceMode? mode})? onPresence;

  /// A call in one of the user's conversations changed.
  final void Function(Call call)? onCall;

  final _status = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus _current = ConnectionStatus.connecting;
  WebSocketChannel? _channel;
  Timer? _retryTimer;
  var _attempt = 0;
  var _stopped = false;

  /// The current channel has been authenticated (the server sent "ready").
  var _ready = false;
  var _nextRid = 0;
  final _requests = <String, Completer<Map<String, Object?>>>{};

  static const _requestTimeout = Duration(seconds: 15);

  ConnectionStatus get status => _current;
  Stream<ConnectionStatus> get statusChanges => _status.stream;

  /// Why the last attempt to get online failed, until one succeeds: the
  /// server could not be reached, or catching up after connecting failed.
  String? get problem => _problem;
  Stream<String?> get problemChanges => _problems.stream;
  String? _problem;
  final _problems = StreamController<String?>.broadcast();

  void _setProblem(String? problem) {
    if (problem == _problem || _problems.isClosed) return;
    _problem = problem;
    _problems.add(problem);
  }

  /// One line for the user, with the HTTP status of a server error.
  static String _describe(Object error) {
    final text = switch (error) {
      ApiException(:final status, :final code) when status > 0 => 'HTTP $status $code: $error',
      _ => '$error',
    };
    final line = text.split('\n').first;
    return line.length > 240 ? '${line.substring(0, 237)}...' : line;
  }

  void start() {
    _stopped = false;
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    _ready = false;
    _failRequests();
    await _channel?.sink.close();
    _channel = null;
    await _status.close();
    await _problems.close();
  }

  /// Reconnects immediately, e.g. when the app returns to the foreground.
  void reconnectNow() {
    if (_stopped || _current == ConnectionStatus.online) return;
    _retryTimer?.cancel();
    _attempt = 0;
    _connect();
  }

  /// Sends a message; completes with its seq. Throws [ApiException]: a
  /// network error (status 0) when offline, or the server's rejection.
  Future<int> sendMessage(EncryptedEnvelope envelope) async =>
      (await _request({'type': Frame.send, 'envelope': envelope.toJson()}))['seq'] as int;

  /// Moves the read marker; completes with the server's marker.
  Future<int> markRead(String conv, int upTo) async =>
      (await _request({'type': Frame.read, 'conv': conv, 'upTo': upTo}))['readUpTo'] as int;

  Future<Map<String, Object?>> _request(Map<String, Object?> frame) {
    final channel = _channel;
    if (channel == null || !_ready) {
      return Future.error(const ApiException(0, 'offline', 'Not connected'));
    }
    final rid = '${++_nextRid}';
    final completer = Completer<Map<String, Object?>>();
    _requests[rid] = completer;
    channel.sink.add(jsonEncode({...frame, 'rid': rid}));
    return completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        _requests.remove(rid);
        throw const ApiException(0, 'timeout', 'The server took too long to answer');
      },
    );
  }

  /// Fails every request still waiting for an answer, e.g. on disconnect.
  void _failRequests() {
    final pending = [..._requests.values];
    _requests.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(const ApiException(0, 'network', 'The connection was lost'));
    }
  }

  void sendTyping(String conv) {
    if (_current == ConnectionStatus.online) {
      _channel?.sink.add(jsonEncode({'type': Frame.typing, 'conv': conv}));
    }
  }

  /// Tells the server whether this device is in use; with [active] null,
  /// asks for everyone's status again.
  void sendPresence({bool? active}) {
    if (!_ready) return;
    _channel?.sink.add(jsonEncode({'type': Frame.presence, if (active != null) 'state': active ? 'active' : 'idle'}));
  }

  void _setStatus(ConnectionStatus status) {
    if (status == _current || _status.isClosed) return;
    _current = status;
    _status.add(status);
  }

  Future<void> _connect() async {
    if (_stopped) return;
    _setStatus(_attempt == 0 ? ConnectionStatus.connecting : ConnectionStatus.offline);
    _log.debug('Connecting to $uri');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    try {
      await channel.ready;
    } catch (e) {
      _log.info('Cannot reach the server: ${_describe(e)}');
      _setProblem('Cannot reach the server: ${_describe(e)}');
      _scheduleRetry(channel);
      return;
    }
    if (_stopped) return;
    channel.sink.add(jsonEncode({'type': Frame.auth, 'token': token, 'client': clientLevel}));
    channel.stream.listen(
      (raw) => _onFrame(channel, raw),
      onDone: () => _scheduleRetry(channel),
      onError: (Object _) => _scheduleRetry(channel),
      cancelOnError: true,
    );
  }

  Future<void> _onFrame(WebSocketChannel channel, Object? raw) async {
    final Map<String, Object?> frame;
    try {
      frame = (jsonDecode(raw as String) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    switch (frame['type']) {
      case Frame.ready:
        _attempt = 0;
        _ready = true;
        _log.info('Connected; catching up');
        try {
          await onReady();
          if (identical(channel, _channel)) {
            _log.info('Online');
            _setStatus(ConnectionStatus.online);
            _setProblem(null);
          }
        } catch (e, stack) {
          // Catch-up failed; drop the connection and try again later. Said
          // where the user can see it, and logged in full.
          _log.warning('Catching up after connecting failed', e, stack);
          _setProblem('Could not sync: ${_describe(e)}');
          await channel.sink.close();
        }
      case Frame.event:
        onEvent(SyncEvent.fromJson((frame['event'] as Map).cast<String, Object?>()));
      case Frame.ack:
        _requests.remove(frame['rid'])?.complete(frame);
      case Frame.nack:
        _log.debug('Request ${frame['rid']} refused: ${frame['status']} ${frame['error']} ${frame['message'] ?? ''}');
        _requests
            .remove(frame['rid'])
            ?.completeError(
              ApiException(
                frame['status'] as int? ?? 400,
                frame['error'] as String? ?? 'error',
                frame['message'] as String?,
              ),
            );
      case Frame.inbox:
        onInbox(InboxItem.fromJson((frame['item'] as Map).cast<String, Object?>()));
      case Frame.typing:
        onTyping?.call(frame['conv'] as String, frame['user'] as String);
      case Frame.backup:
        onBackup?.call();
      case Frame.trust:
        onTrust?.call();
      case Frame.accountData:
        if (frame['name'] case final String name) onAccountData?.call(name);
      case Frame.presence:
        final mode = frame['mode'] == null ? null : PresenceMode.parse(frame['mode']);
        if (frame['statuses'] case final Map statuses) {
          onPresence?.call(
            {for (final MapEntry(:key, :value) in statuses.entries) key as String: Presence.parse(value)},
            all: true,
            mode: mode,
          );
        } else if (frame['user'] case final String user) {
          onPresence?.call({user: Presence.parse(frame['status'])}, all: false, mode: mode);
        }
      case Frame.call:
        if (frame['call'] case final Map call) {
          try {
            onCall?.call(Call.fromJson(call.cast<String, Object?>()));
          } on FormatException catch (e) {
            _log.warning('A call frame that makes no sense: $e');
          }
        }
      case Frame.error:
        _log.warning('The server ended the session: ${frame['error']}');
        if (frame['error'] == 'client_too_old') {
          // Nothing but an update changes this, and nothing is lost meanwhile.
          _stopped = true;
          _setProblem('This version of the app is too old for this server. Update it to reconnect.');
          _setStatus(ConnectionStatus.updateRequired);
        } else if (frame['error'] == 'unauthorized' || frame['error'] == 'session_revoked') {
          _stopped = true;
          onRevoked();
        }
    }
  }

  void _scheduleRetry(WebSocketChannel channel) {
    if (!identical(channel, _channel) || _stopped) return;
    _channel = null;
    _ready = false;
    _failRequests();
    _setStatus(ConnectionStatus.offline);
    // 1s, 2s, 4s ... capped at 30s, with jitter so devices don't stampede.
    final seconds = min(30, 1 << min(_attempt, 5));
    _log.info(
      'Disconnected (${channel.closeCode ?? 'no close code'} ${channel.closeReason ?? ''}), again in ${seconds}s',
    );
    _attempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: seconds * 1000 + Random().nextInt(500)), _connect);
  }
}
