import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/app_storage.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hanashi_db_');
    file = File('${dir.path}/${AppStorage.databaseName}.sqlite');
  });

  tearDown(() => dir.delete(recursive: true));

  AppDatabase open(String key) => AppStorage.openDatabase(key: key, directory: dir);

  String header() => utf8.decode(file.readAsBytesSync().take(15).toList(), allowMalformed: true);

  /// Whether the file can be read without a key, as any SQLite could.
  bool readableWithoutKey() {
    final db = sqlite3.open(file.path);
    try {
      db.select('SELECT count(*) FROM sqlite_master');
      return true;
    } on SqliteException {
      return false;
    } finally {
      db.close();
    }
  }

  final key = base64.encode(List.filled(32, 7));
  final otherKey = base64.encode(List.filled(32, 9));

  test('an unencrypted one, which the app never makes, starts over as one its key does not open', () async {
    final plain = AppDatabase(NativeDatabase(file));
    await plain.setValue('notify.enabled', 'false');
    await plain.close();
    expect(header(), 'SQLite format 3');

    final db = open(key);
    expect(await db.getValue('notify.enabled'), isNull);
    await db.close();
    expect(readableWithoutKey(), isFalse);
  });

  test('a new database is encrypted from the start', () async {
    final db = open(key);
    await db.setValue('notify.preview', 'false');
    await db.close();
    expect(readableWithoutKey(), isFalse);
  });

  test('one its key does not open, the key being gone, starts over', () async {
    final db = open(key);
    await db.setValue('notify.preview', 'false');
    await db.close();

    final fresh = open(otherKey);
    expect(await fresh.getValue('notify.preview'), isNull);
    await fresh.setValue('notify.enabled', 'false');
    await fresh.close();
    final again = open(otherKey);
    expect(await again.getValue('notify.enabled'), 'false');
    await again.close();
  });

  test('the key is made once, at random, and kept', () async {
    final store = MemorySecureStore();
    final first = await AppStorage.databaseKey(store);
    expect(base64.decode(first), hasLength(32));
    expect(await AppStorage.databaseKey(store), first);
    expect(await AppStorage.databaseKey(MemorySecureStore()), isNot(first));
  });
}
