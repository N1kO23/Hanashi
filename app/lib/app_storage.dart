import 'dart:convert';
import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart';

import 'data/local/database.dart';
import 'diagnostics/app_log.dart';
import 'e2ee/primitives.dart';
import 'e2ee/secure_store.dart';

const _log = Log('storage');

/// Where the app keeps its data. The app and a headless push engine (on
/// Android) must open exactly the same state.
class AppStorage {
  const AppStorage({required this.mediaDir, required this.supportDir});

  /// Downloaded and sent media.
  final Directory mediaDir;

  /// The local database, the MLS state and other app data.
  final Directory supportDir;

  static Future<AppStorage> resolve() async => AppStorage(
    mediaDir: Directory('${(await getApplicationCacheDirectory()).path}/media'),
    supportDir: await getApplicationSupportDirectory(),
  );

  /// The local database, in the app's data directory (or [directory], for
  /// tests), encrypted with [key] (see [databaseKey]). Every engine in the
  /// process shares one database isolate, so changes made by a push engine
  /// show up in the app at once.
  static AppDatabase openDatabase({required String key, Directory? directory}) =>
      AppDatabase(driftDatabase(name: databaseName, native: _options(key, directory)));

  /// drift sends these to the database's isolate, functions included, so
  /// they hold nothing but [key] and [directory].
  static DriftNativeOptions _options(String key, Directory? directory) => DriftNativeOptions(
    shareAcrossIsolates: true,
    // Called only while no engine has the database open.
    databaseDirectory: () async {
      final dir = directory ?? await _supportDirectory();
      prepareDatabase(File('${dir.path}/$databaseName.sqlite'), key);
      return dir;
    },
    setup: (db) => unlockDatabase(db, key),
    // Tests have no platform to ask; SQLite's own default does there.
    tempDirectoryPath: directory == null ? null : () async => null,
  );

  static const databaseName = 'hanashi';

  static Future<Directory> _supportDirectory() => getApplicationSupportDirectory();

  /// The local database's key, made the first time: 32 random bytes, in
  /// base64. It is kept with the device's other secrets, in the keyring or
  /// in the file the user chose instead, and stays when the user signs out,
  /// as the database does (emptied).
  static Future<String> databaseKey(SecureStore store) async {
    final stored = await store.read(_databaseKeyName);
    if (stored != null) return stored;
    final key = base64.encode(randomBytes(32));
    await store.write(_databaseKeyName, key);
    return key;
  }

  static const _databaseKeyName = 'database.key';

  /// Opens [db] with [key]: the first thing done on each connection. The
  /// database is encrypted by SQLite3MultipleCiphers, with ChaCha20-Poly1305
  /// (named, as the library's default could change).
  static void unlockDatabase(CommonDatabase db, String key) {
    db.execute("PRAGMA cipher = 'chacha20'");
    db.execute("PRAGMA key = '${_checked(key)}'");
  }

  /// Readies [file] for [key]. One [key] cannot open is deleted: its key
  /// went with the device's other secrets, so none of it can be read again,
  /// and the app starts over as after signing in (the chats come back from
  /// the server).
  static void prepareDatabase(File file, String key) {
    if (!file.existsSync()) return;
    final db = sqlite3.open(file.path);
    var unreadable = false;
    try {
      unlockDatabase(db, key);
      db.select('SELECT count(*) FROM sqlite_master');
    } on SqliteException catch (e) {
      if (e.resultCode != SqlError.SQLITE_NOTADB) rethrow;
      unreadable = true;
    } finally {
      db.close();
    }
    if (unreadable) {
      _log.warning('The local database does not open with its key, which is gone: starting over');
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        final part = File('${file.path}$suffix');
        if (part.existsSync()) part.deleteSync();
      }
    }
  }

  /// Keys are base64, so nothing in them ends the SQL string.
  static String _checked(String key) =>
      RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(key) ? key : throw ArgumentError('Not a database key');
}

/// The device's MLS database in [dir]; in memory without one (tests).
String mlsDbPath(Directory? dir, String deviceId) => dir == null ? ':memory:' : '${dir.path}/mls-$deviceId.db';

/// Where the sticker packs the user keeps are, extracted (see `StickerPackStore`).
Directory stickerPacksDir(Directory supportDir) => Directory('${supportDir.path}/sticker_packs');
