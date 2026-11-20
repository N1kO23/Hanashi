import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi/data/remote/socket_client.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

/// A WebSocket endpoint that says "ready" to anyone who authenticates.
Future<HttpServer> _readyServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.transform(WebSocketTransformer()).listen((socket) {
    socket.listen((_) => socket.add(jsonEncode({'type': 'ready'})));
  });
  return server;
}

void main() {
  SocketClient client(Uri uri, Future<void> Function() onReady) => SocketClient(
    uri: uri,
    token: 't',
    onReady: onReady,
    onEvent: (_) {},
    onInbox: (_) {},
    onRevoked: () {},
  );

  Future<String?> problem(SocketClient socket, bool Function(String? p) test) =>
      socket.problemChanges.firstWhere(test).timeout(const Duration(seconds: 10));

  test('a sync that fails after connecting says why, and clears once it works', () async {
    final server = await _readyServer();
    addTearDown(server.close);
    var fail = true;
    final socket = client(Uri.parse('ws://127.0.0.1:${server.port}/ws'), () async {
      // An older server without an endpoint the app needs, say.
      if (fail) throw const ApiException(404, 'not_found', 'No such route');
    });
    addTearDown(socket.stop);
    final failed = problem(socket, (p) => p != null);
    socket.start();
    expect(await failed, 'Could not sync: HTTP 404 not_found: No such route');
    expect(socket.status, isNot(ConnectionStatus.online));

    fail = false;
    final cleared = problem(socket, (p) => p == null);
    socket.reconnectNow();
    await cleared;
    expect(socket.status, ConnectionStatus.online);
  });

  test('a server that needs a newer app is told the level, says so and is not tried again', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final auths = <Map<String, Object?>>[];
    server.transform(WebSocketTransformer()).listen((socket) {
      socket.listen((frame) {
        auths.add((jsonDecode(frame as String) as Map).cast());
        socket.add(jsonEncode({'type': 'error', 'error': 'client_too_old'}));
        socket.close(4002, 'client_too_old');
      });
    });
    var revoked = false;
    final socket = SocketClient(
      uri: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      token: 't',
      onReady: () async {},
      onEvent: (_) {},
      onInbox: (_) {},
      onRevoked: () => revoked = true,
    );
    addTearDown(socket.stop);
    final told = socket.statusChanges.firstWhere((s) => s == ConnectionStatus.updateRequired);
    socket.start();
    await told.timeout(const Duration(seconds: 10));
    expect(socket.problem, contains('too old'));
    expect(auths.single['client'], clientLevel);
    expect(revoked, isFalse, reason: 'needing an update must not sign anyone out');

    await Future<void>.delayed(const Duration(milliseconds: 2500));
    socket.reconnectNow();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(auths, hasLength(1), reason: 'only an update changes the answer');
    expect(socket.status, ConnectionStatus.updateRequired);
  });

  test('an unreachable server says so', () async {
    // A port nobody listens on.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final socket = client(Uri.parse('ws://127.0.0.1:$port/ws'), () async {});
    addTearDown(socket.stop);
    final reported = problem(socket, (p) => p != null);
    socket.start();
    expect(await reported, startsWith('Cannot reach the server: '));
  });
}
