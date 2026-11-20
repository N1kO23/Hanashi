import 'dart:convert';
import 'dart:io';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../ui/theme/hanashi_theme.dart';
import 'app_theme.dart';
import 'theme_package.dart';

/// The themes installed on this device: `<root>/<id>/index.json` and their
/// files, each named by its role (`logo.png`, `messageSound.ogg`…), never by
/// what the theme's file called it. A theme's folder appears whole or not at
/// all, so one is either there as it was installed or not there.
class ThemeStore {
  ThemeStore(this.root, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Directory root;
  final DateTime Function() _now;

  Directory _folder(String id) => Directory('${root.path}/$id');

  bool has(String id) => File('${_folder(id).path}/index.json').existsSync();

  /// How long an install takes at most: a folder it works in that is older
  /// was left behind.
  static const leftoverAge = Duration(hours: 1);

  /// Every theme here this version can read, read at once: the app's first
  /// frame, and the push engine, need the one shown before anything else.
  /// What an install left behind goes, once it is old enough not to be one
  /// going on (the push engine reads themes while the app runs).
  List<AppTheme> loadAllSync() {
    if (!root.existsSync()) return const [];
    final themes = <AppTheme>[];
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('.')) {
        try {
          if (_now().difference(entry.statSync().modified) > leftoverAge) entry.deleteSync(recursive: true);
        } on FileSystemException {
          // The next time.
        }
        continue;
      }
      final theme = _load(entry, name);
      if (theme != null) themes.add(theme);
    }
    return themes;
  }

  static AppTheme? _load(Directory folder, String name) {
    try {
      final index = jsonDecode(File('${folder.path}/index.json').readAsStringSync()) as Map<String, Object?>;
      if (index['id'] != name) return null;
      HanashiPalette? palette(String variant, HanashiPalette base) => switch (index[variant]) {
        final Map<String, Object?> colors => HanashiPalette.fromJson(colors, base: base),
        _ => null,
      };
      final light = palette('light', HanashiPalette.light);
      final dark = palette('dark', HanashiPalette.dark);
      if (light == null && dark == null) return null;
      final files = (index['files'] as Map<String, Object?>?) ?? const {};
      FileSource? file(String role) => switch (files[role]) {
        final String file when !file.contains('/') && !file.contains(r'\') => FileSource('${folder.path}/$file'),
        _ => null,
      };
      final version = index['version'];
      return AppTheme(
        id: name,
        title: index['title']! as String,
        author: index['author'] as String?,
        appName: index['appName'] as String?,
        version: version is int ? version : null,
        // A theme with one look shows it in light and dark mode alike.
        light: light ?? dark!,
        dark: dark ?? light!,
        assets: ThemeAssets(
          logo: file('logo'),
          wordmark: file('wordmark'),
          appIcon: file('appIcon'),
          messageSound: file('messageSound'),
          ringtone: file('ringtone'),
        ),
        origin: ThemeOrigin.imported,
      );
    } on Object {
      // Not one this version reads, or damaged.
      return null;
    }
  }

  /// Installs [package] (one [readThemePackage] checked) in place of a theme
  /// of its ID here.
  Future<void> install(ThemePackage package) async {
    final manifest = package.manifest;
    await root.create(recursive: true);
    final incoming = Directory('${root.path}/.incoming-${newUlid()}');
    try {
      await incoming.create();
      final files = <String, String>{};
      for (final MapEntry(key: role, value: bytes) in package.files.entries) {
        final name = '$role.${manifest.assets[role]!.split('.').last}';
        await File('${incoming.path}/$name').writeAsBytes(bytes, flush: true);
        files[role] = name;
      }
      await File('${incoming.path}/index.json').writeAsString(
        jsonEncode({
          'id': manifest.id,
          'title': manifest.title,
          'author': ?manifest.author,
          'appName': ?manifest.appName,
          'version': ?manifest.version,
          'light': ?manifest.light?.toJson(),
          'dark': ?manifest.dark?.toJson(),
          'files': files,
        }),
        flush: true,
      );
      final target = _folder(manifest.id);
      if (target.existsSync()) {
        final old = Directory('${root.path}/.old-${newUlid()}');
        await target.rename(old.path);
        await incoming.rename(target.path);
        await old.delete(recursive: true);
      } else {
        await incoming.rename(target.path);
      }
    } finally {
      if (incoming.existsSync()) await incoming.delete(recursive: true);
    }
  }

  Future<void> remove(String id) async {
    final folder = _folder(id);
    if (folder.existsSync()) await folder.delete(recursive: true);
  }
}
