import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/diagnostics/app_log.dart';

void main() {
  final log = AppLog.instance;
  const sync = Log('sync');
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_log_'));
  tearDown(() {
    log.reset();
    dir.deleteSync(recursive: true);
  });

  test('keeps lines up to its level, with time, level and part of the app', () async {
    sync.debug('not kept at the default level');
    sync.info('Online');
    sync.warning('Upkeep failed', StateError('gone'), StackTrace.fromString('#0 here'));
    final lines = (await log.read()).trimRight().split('\n');
    expect(lines, hasLength(3));
    expect(lines[0], matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} I sync: Online$')));
    expect(lines[1], endsWith(' W sync: Upkeep failed: Bad state: gone'));
    expect(lines[2], '#0 here');
    expect(sync.detailed, isFalse);

    await log.setLevel(LogLevel.debug);
    sync.debug('Event 5: message');
    expect(await log.read(), contains('D sync: Event 5: message'));
    await log.setLevel(LogLevel.warning);
    sync.info('left out');
    expect(await log.read(), isNot(contains('left out')));
  });

  test('in a file that turns over at its size, with the level beside it', () async {
    log.useDirectory(dir);
    await log.setLevel(LogLevel.debug);
    final file = File('${dir.path}/${AppLog.fileName}');
    final line = 'x' * 2000;
    for (var i = 0; i < 700; i++) {
      sync.debug('$i $line');
      if (i % 100 == 99) await log.flush();
    }
    await log.flush();
    expect(File('${file.path}.1').existsSync(), isTrue, reason: 'turned over after 1 MB');
    expect(file.lengthSync(), lessThan(AppLog.maxFileBytes));
    // Oldest first, across both files.
    final lines = (await log.read()).trimRight().split('\n');
    expect(lines.first, contains('D sync: 0 '));
    expect(lines.last, contains('D sync: 699 '));
    expect(lines, hasLength(700));

    // Like the next start of the app, or an engine started for a push.
    log.reset();
    expect(log.level, LogLevel.info);
    log.useDirectory(dir);
    expect(log.level, LogLevel.debug);
    expect(await log.read(), contains('D sync: 699 '));

    await log.clear();
    expect(await log.read(), isEmpty);
    expect(file.existsSync() || File('${file.path}.1').existsSync(), isFalse);
  });

  test('levels are read leniently', () {
    expect(LogLevel.parse('debug\n'), LogLevel.debug);
    expect(LogLevel.parse('warning'), LogLevel.warning);
    expect(LogLevel.parse('loud'), LogLevel.info);
    expect(LogLevel.parse(null), LogLevel.info);
  });
}
