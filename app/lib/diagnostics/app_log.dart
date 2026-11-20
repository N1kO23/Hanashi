import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// How much goes into the app's log, from least to most.
enum LogLevel {
  error('E'),
  warning('W'),
  info('I'),
  debug('D');

  const LogLevel(this.letter);

  /// Marks the level in each line.
  final String letter;

  /// The level called [name]; [info] for anything else.
  static LogLevel parse(String? name) => values.asNameMap()[name?.trim()] ?? info;
}

/// What the app did, to find out what went wrong: connections, requests,
/// syncing, the encryption groups, and why a message could not be sent or
/// read. Lines name users, chats, devices and messages by their IDs; never
/// message contents, keys, passwords or tokens.
///
/// Kept in memory, and once [useDirectory] is called also in a file there,
/// with the one before it (so at most twice [maxFileBytes]). The level is kept
/// beside it, so it outlives signing out, and engines started for a push use
/// it too. Debug builds also print the lines.
class AppLog {
  AppLog._();

  static final instance = AppLog._();

  static const fileName = 'hanashi.log';
  static const levelFileName = 'log-level.txt';
  static const maxFileBytes = 1 << 20;

  /// Lines kept in memory, for a log without a file (e.g. in tests).
  static const _kept = 2000;

  /// Lines more detailed than this are left out.
  LogLevel get level => _level;
  var _level = LogLevel.info;

  /// Print each line too: in debug builds, but not in tests.
  bool echo = kDebugMode && !Platform.environment.containsKey('FLUTTER_TEST');

  final _recent = ListQueue<String>();
  final _pending = <String>[];
  Directory? _dir;
  Timer? _flushTimer;
  Future<void> _writing = Future.value();

  File? get _file => _dir == null ? null : File('${_dir!.path}/$fileName');
  File? get _previous => _dir == null ? null : File('${_dir!.path}/$fileName.1');

  /// Keeps the log in [dir] (see [useDirectory]), with the errors nothing
  /// else caught.
  void start(Directory dir) {
    useDirectory(dir);
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      add(LogLevel.error, 'app', 'Uncaught: ${details.exceptionAsString()}', null, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      add(LogLevel.error, 'app', 'Uncaught', error, stack);
      return false;
    };
  }

  /// Keeps the log in [dir] from now on, at the level saved there.
  void useDirectory(Directory dir) {
    _dir = dir;
    try {
      _level = LogLevel.parse(File('${dir.path}/$levelFileName').readAsStringSync());
    } on FileSystemException {
      // Never changed: the default.
    }
  }

  /// Sets and saves the level.
  Future<void> setLevel(LogLevel level) async {
    _level = level;
    final dir = _dir;
    if (dir != null) await File('${dir.path}/$levelFileName').writeAsString(level.name);
  }

  /// Lines at [lineLevel] are kept.
  bool keeps(LogLevel lineLevel) => lineLevel.index <= _level.index;

  void add(LogLevel lineLevel, String tag, String message, [Object? error, StackTrace? stack]) {
    if (!keeps(lineLevel)) return;
    final now = DateTime.now().toIso8601String();
    final line = StringBuffer('${now.substring(0, 10)} ${now.substring(11, 23)} ${lineLevel.letter} $tag: $message');
    if (error != null) line.write(': $error');
    if (stack != null) line.write('\n${'$stack'.trimRight()}');
    final text = line.toString();
    if (echo) debugPrint(text);
    _recent.add(text);
    while (_recent.length > _kept) {
      _recent.removeFirst();
    }
    if (_dir == null) return;
    _pending.add(text);
    _flushTimer ??= Timer(const Duration(seconds: 1), flush);
  }

  /// Writes the lines not in the file yet.
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = _file, previous = _previous;
    if (file == null || previous == null || _pending.isEmpty) return _writing;
    final text = '${_pending.join('\n')}\n';
    _pending.clear();
    return _writing = _writing.then((_) async {
      try {
        if (await file.exists() && await file.length() > maxFileBytes) await file.rename(previous.path);
        await file.writeAsString(text, mode: FileMode.append, flush: true);
      } on FileSystemException catch (e) {
        if (echo) debugPrint('Writing the log failed: $e');
      }
    });
  }

  /// The whole log, oldest line first.
  Future<String> read() async {
    final file = _file, previous = _previous;
    if (file == null || previous == null) return _recent.map((line) => '$line\n').join();
    await flush();
    final parts = <String>[];
    for (final f in [previous, file]) {
      try {
        // A line another engine was writing may end mid-character.
        parts.add(utf8.decode(await f.readAsBytes(), allowMalformed: true));
      } on FileSystemException {
        // Not written yet.
      }
    }
    return parts.join();
  }

  Future<void> clear() async {
    _recent.clear();
    _pending.clear();
    if (_dir == null) return;
    await flush();
    for (final f in [_previous, _file]) {
      try {
        await f?.delete();
      } on FileSystemException {
        // Not there.
      }
    }
  }

  /// Back to how it starts, for tests.
  @visibleForTesting
  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _recent.clear();
    _pending.clear();
    _dir = null;
    _level = LogLevel.info;
  }
}

/// The lines of one part of the app, e.g. `const _log = Log('sync');`.
class Log {
  const Log(this.tag);

  final String tag;

  /// [debug] lines are kept: check before putting together costly ones.
  bool get detailed => AppLog.instance.keeps(LogLevel.debug);

  void debug(String message) => AppLog.instance.add(LogLevel.debug, tag, message);

  void info(String message) => AppLog.instance.add(LogLevel.info, tag, message);

  void warning(String message, [Object? error, StackTrace? stack]) =>
      AppLog.instance.add(LogLevel.warning, tag, message, error, stack);

  void error(String message, [Object? error, StackTrace? stack]) =>
      AppLog.instance.add(LogLevel.error, tag, message, error, stack);
}
