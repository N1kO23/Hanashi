import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage for long-term secrets (login token, identity key, MLS keys):
/// the platform keychain (Keychain, Android Keystore, Secret Service on
/// Linux, Credential Manager on Windows).
abstract interface class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Removes every entry with [prefix].
  Future<void> deleteAll({String prefix = ''});
}

class PlatformSecureStore implements SecureStore {
  PlatformSecureStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _namespace = 'hanashi.';

  /// Whether the keyring can be used. On Linux it may be missing (no Secret
  /// Service, e.g. a window manager without GNOME Keyring or KWallet) or stay
  /// locked; the other platforms always have one.
  Future<bool> isAvailable() async {
    if (!Platform.isLinux) return true;
    try {
      await _storage.read(key: '${_namespace}available');
      return true;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> read(String key) => _storage.read(key: '$_namespace$key');

  @override
  Future<void> write(String key, String value) => _storage.write(key: '$_namespace$key', value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: '$_namespace$key');

  @override
  Future<void> deleteAll({String prefix = ''}) async {
    for (final key in (await _storage.readAll()).keys) {
      if (key.startsWith('$_namespace$prefix')) await _storage.delete(key: key);
    }
  }
}

/// Secrets in a file only the user can read, for a desktop without a keyring
/// when the user chooses so. The file is not encrypted: whoever can read the
/// user's files can read it.
class FileSecureStore implements SecureStore {
  FileSecureStore(Directory dir) : file = File('${dir.path}/secrets.json');

  final File file;
  Map<String, String>? _values;
  Future<void> _saving = Future.value();

  /// The user chose this store (on an earlier start).
  Future<bool> exists() => file.exists();

  /// Starts using a file, empty for now.
  Future<void> create() => _save(_values = {});

  Future<Map<String, String>> entries() async => {...await _load()};

  /// Deletes the file: the user moved the keys elsewhere.
  Future<void> remove() async {
    await _saving;
    _values = {};
    if (await file.exists()) await file.delete();
  }

  Future<Map<String, String>> _load() async =>
      _values ??= await file.exists() ? (jsonDecode(await file.readAsString()) as Map).cast<String, String>() : {};

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) async => _save((await _load())..[key] = value);

  @override
  Future<void> delete(String key) async => _save((await _load())..remove(key));

  @override
  Future<void> deleteAll({String prefix = ''}) async =>
      _save((await _load())..removeWhere((k, _) => k.startsWith(prefix)));

  /// Replaces the file in one step, readable only by the user from the start.
  Future<void> _save(Map<String, String> values) {
    final json = jsonEncode(values);
    return _saving = _saving.then((_) async {
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsString('');
      if (!Platform.isWindows) await Process.run('chmod', ['600', part.path]);
      await part.writeAsString(json, flush: true);
      await part.rename(file.path);
    });
  }
}

/// The app's store: the keyring, or a file until the keys move into a
/// keyring that became available ([moveTo]), without restarting the app.
class SwitchableSecureStore implements SecureStore {
  SwitchableSecureStore(this._current);

  SecureStore _current;
  SecureStore get current => _current;

  @override
  Future<String?> read(String key) => _current.read(key);

  @override
  Future<void> write(String key, String value) => _current.write(key, value);

  @override
  Future<void> delete(String key) => _current.delete(key);

  @override
  Future<void> deleteAll({String prefix = ''}) => _current.deleteAll(prefix: prefix);

  /// Copies the keys from the file into [keyring], uses it from now on and
  /// deletes the file.
  Future<void> moveTo(SecureStore keyring) async {
    final file = _current;
    if (file is! FileSecureStore) return;
    for (final MapEntry(:key, :value) in (await file.entries()).entries) {
      await keyring.write(key, value);
    }
    _current = keyring;
    await file.remove();
  }
}

/// For tests and demo mode: never touches the user's keychain.
class MemorySecureStore implements SecureStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll({String prefix = ''}) async => values.removeWhere((k, _) => k.startsWith(prefix));
}
