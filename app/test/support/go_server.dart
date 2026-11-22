import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Runs the real Go server (`server/`) for integration tests.
///
/// MariaDB comes from `$HANASHI_TEST_DSN` (a DSN without a database, e.g.
/// `root:pw@tcp(127.0.0.1:3306)/`) or from the `hanashi-test-mariadb`
/// container that the Go tests also use (see server/internal/testdb), which
/// is started if needed and left running. Each server gets its own database.
class GoServer {
  GoServer._(this._binary, this._dsn, this._database, this.dataDir, this.port, this.host, this._environment);

  final String _binary;
  final String _dsn;
  final String _database;
  final Directory dataDir;
  final int port;

  /// The host of its users' IDs.
  final String host;

  /// More of its settings.
  final Map<String, String> _environment;
  Process? _process;
  final _log = StringBuffer();

  String get url => 'http://127.0.0.1:$port';

  static const _container = 'hanashi-test-mariadb';
  static const _rootPassword = 'hanashi-test';
  static Future<String>? _built;
  static Future<String>? _sqlBuilt;
  static Future<String>? _adminDsn;

  static Future<GoServer> start({
    String host = 'test.local',
    Map<String, String> environment = const {},
    int? port,
  }) async {
    final binary = await (_built ??= _build());
    final admin = await (_adminDsn ??= _startDatabase());
    final database = 'hanashi_dart_${Random().nextInt(1 << 32).toRadixString(16)}';
    final (base, params) = switch (admin.split('?')) {
      [final b] => (b, ''),
      [final b, final p] => (b, '?$p'),
      _ => throw ArgumentError('Unexpected DSN $admin'),
    };
    final server = GoServer._(
      binary,
      '${base.endsWith('/') ? base : '$base/'}$database$params',
      database,
      await Directory.systemTemp.createTemp('hanashi_go_'),
      port ?? await _freePort(),
      host,
      environment,
    );
    await server.restart();
    return server;
  }

  /// Two servers, of `a.test` and `b.test`, that federate with each other.
  static Future<(GoServer, GoServer)> pair() async {
    final [a, b] = await federating(['a.test', 'b.test']);
    return (a, b);
  }

  /// A server of each of [hosts], all federating with each other.
  static Future<List<GoServer>> federating(List<String> hosts) async {
    final ports = [for (final _ in hosts) await _freePort()];
    final environment = {
      'HANASHI_FEDERATION': 'on',
      'HANASHI_FEDERATION_SERVERS': hosts.join(','),
      'HANASHI_FEDERATION_RESOLVE': [for (final (i, host) in hosts.indexed) '$host=http://127.0.0.1:${ports[i]}']
          .join(','),
    };
    return [for (final (i, host) in hosts.indexed) await start(host: host, environment: environment, port: ports[i])];
  }

  static Future<int> _freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// Starts (or starts again, keeping the database and media) the process.
  Future<void> restart({int? minClient}) async {
    await stop();
    _process = await Process.start(
      _binary,
      [],
      environment: {
        'HANASHI_DB_DSN': _dsn,
        'HANASHI_DB_CREATE': 'true',
        'HANASHI_HOST': host,
        'HANASHI_BIND': '127.0.0.1',
        'HANASHI_PORT': '$port',
        'HANASHI_DATA_DIR': dataDir.path,
        // Test push services listen on loopback.
        'HANASHI_PUSH_ALLOW_PRIVATE': 'true',
        'HANASHI_KLIPY_API_KEY': 'test-klipy-key',
        'HANASHI_MIN_CLIENT': ?minClient?.toString(),
        ..._environment,
      },
    );
    _process!.stdout.transform(const SystemEncoding().decoder).listen(_log.write);
    _process!.stderr.transform(const SystemEncoding().decoder).listen(_log.write);
    final client = HttpClient();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (true) {
        try {
          final response = await (await client.getUrl(Uri.parse('$url/server'))).close();
          await response.drain<void>();
          if (response.statusCode == 200) return;
        } on SocketException {
          // Not listening yet.
        }
        if (DateTime.now().isAfter(deadline)) throw StateError('The server did not start:\n$_log');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  /// Waits until the server has logged [text]: for what it does by itself,
  /// which no app sees.
  Future<void> logged(String text, {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!_log.toString().contains(text)) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('$host never logged "$text":\n$_log');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Runs [statements] on the server's database: for tests that play a
  /// server that misbehaves, which its API cannot be made to do.
  Future<void> sql(List<String> statements) async {
    final binary = await (_sqlBuilt ??= _build(package: './internal/testdb/sqlexec', name: 'sqlexec'));
    final result = await Process.run(binary, [_dsn, ...statements]);
    if (result.exitCode != 0) throw StateError('SQL failed:\n${result.stderr}');
  }

  /// Stops the server and removes its data and database.
  Future<void> dispose() async {
    await stop();
    await dataDir.delete(recursive: true);
    if (Platform.environment['HANASHI_TEST_DSN'] == null) {
      await Process.run('docker', [
        'exec',
        _container,
        'mariadb',
        '-uroot',
        '-p$_rootPassword',
        '-e',
        'DROP DATABASE IF EXISTS $_database',
      ]);
    }
  }

  static Directory _repoRoot() {
    for (Directory? dir = Directory.current; dir != null; dir = dir.parent) {
      if (File('${dir.path}/server/go.mod').existsSync()) return dir;
      if (dir.parent.path == dir.path) break;
    }
    throw StateError('Cannot find the repository root from ${Directory.current.path}');
  }

  static Future<String> _build({String package = './cmd/hanashi-server', String name = 'hanashi-server'}) async {
    final out = await Directory.systemTemp.createTemp('hanashi_bin_');
    final binary = '${out.path}/$name';
    final result = await Process.run('go', [
      'build',
      '-o',
      binary,
      package,
    ], workingDirectory: '${_repoRoot().path}/server');
    if (result.exitCode != 0) throw StateError('go build failed:\n${result.stderr}');
    return binary;
  }

  static Future<String> _startDatabase() async {
    final dsn = Platform.environment['HANASHI_TEST_DSN'];
    if (dsn != null && dsn.isNotEmpty) return dsn;
    final result = await Process.run('docker', [
      'run',
      '-d',
      '--rm',
      '--name',
      _container,
      '-e',
      'MARIADB_ROOT_PASSWORD=$_rootPassword',
      '-p',
      '127.0.0.1:33306:3306',
      '--tmpfs',
      '/var/lib/mysql',
      'mariadb:11.8',
    ]);
    if (result.exitCode != 0 && !'${result.stderr}'.contains('is already in use')) {
      throw StateError('Could not start MariaDB (set HANASHI_TEST_DSN or install Docker):\n${result.stderr}');
    }
    // The server itself retries until the database accepts connections.
    return 'root:$_rootPassword@tcp(127.0.0.1:33306)/';
  }
}
