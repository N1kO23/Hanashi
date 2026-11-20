import 'dart:convert';
import 'dart:io';

import '../packs/content_package.dart';
import 'app_theme.dart';
import 'appearance.dart';
import 'builtin_themes.dart';
import 'theme_package.dart';
import 'theme_store.dart';

/// The user has a theme of the same ID already: [title].
class ThemeInstalled implements Exception {
  const ThemeInstalled(this.title);

  final String title;

  @override
  String toString() => 'You have "$title" already';
}

/// The themes of this device and how it shows the app: the built-in themes,
/// those installed in `<supportDir>/themes/` (see [ThemeStore]), and the
/// [Appearance] in `<supportDir>/appearance.json`. Read at once, before the
/// first frame, by the app and by the push engine alike.
class ThemeLibrary {
  ThemeLibrary._(this.supportDir, this.store, this.builtIns, this._installed, this._appearance);

  /// The library of [supportDir]; without one (tests), the built-in themes
  /// only, and the appearance kept in memory. A device without an appearance
  /// gets Default's, written down at once, so that it keeps that theme should
  /// a later version start devices with another.
  factory ThemeLibrary.load(Directory? supportDir, {List<AppTheme>? builtIns}) {
    final store = supportDir == null ? null : ThemeStore(Directory('${supportDir.path}/themes'));
    final file = supportDir == null ? null : File('${supportDir.path}/$fileName');
    Appearance? appearance;
    try {
      if (file != null && file.existsSync()) {
        appearance = Appearance.fromJson(jsonDecode(file.readAsStringSync()), fallbackTheme: defaultThemeId);
      }
    } on Object {
      // Damaged: as on a first start.
    }
    final library = ThemeLibrary._(
      supportDir,
      store,
      builtIns ?? builtInThemes,
      store?.loadAllSync() ?? const [],
      appearance ?? const Appearance(themeId: defaultThemeId),
    );
    if (appearance == null) library._writeNow();
    return library;
  }

  static const fileName = 'appearance.json';

  final Directory? supportDir;
  final ThemeStore? store;
  final List<AppTheme> builtIns;
  List<AppTheme> _installed;
  Appearance _appearance;

  Appearance get appearance => _appearance;

  File? get _file => supportDir == null ? null : File('${supportDir!.path}/$fileName');

  /// Every theme, the built-in ones first. A theme the user imported takes
  /// the place of a built-in one of its ID.
  List<AppTheme> get themes {
    final byId = <String, AppTheme>{
      for (final theme in builtIns) theme.id: theme,
      for (final theme in _installed) theme.id: theme,
    };
    final first = [for (final theme in builtIns) byId.remove(theme.id)!];
    final rest = byId.values.toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return [...first, ...rest];
  }

  AppTheme? operator [](String id) => themes.where((theme) => theme.id == id).firstOrNull;

  /// The theme shown: the chosen one, or Default if it is gone.
  AppTheme get active => this[_appearance.themeId] ?? defaultTheme;

  /// Written whole or not at all (the file is renamed into place): the push
  /// engine reads it while the app runs, and takes a damaged one for none.
  /// One write at a time, each of the appearance as it is by then.
  Future<void> setAppearance(Appearance appearance) {
    _appearance = appearance;
    return _writing = _writing.then((_) => _write());
  }

  Future<void> _writing = Future.value();

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    try {
      final next = await File('${file.path}.$pid').writeAsString(jsonEncode(_appearance.toJson()), flush: true);
      await next.rename(file.path);
    } on FileSystemException {
      // Shown until the app closes, at least.
    }
  }

  void _writeNow() {
    final file = _file;
    if (file == null) return;
    try {
      File('${file.path}.$pid')
        ..writeAsStringSync(jsonEncode(_appearance.toJson()), flush: true)
        ..renameSync(file.path);
    } on FileSystemException {
      // Written the next time it changes.
    }
  }

  /// Adds the theme file at [path]. One of its ID (built in or not) is only
  /// replaced with [replace]; otherwise [ThemeInstalled] says whose it is.
  /// Throws a [PackageException] for a file that is not a theme.
  Future<AppTheme> import(String path, {bool replace = false}) async {
    final store = this.store;
    if (store == null) throw StateError('Themes need a folder');
    final file = File(path);
    if (await file.length() > themeLimits.maxBytes) {
      throw PackageException('This theme is larger than ${themeLimits.maxBytes ~/ (1024 * 1024)} MB');
    }
    final package = await readThemePackage(await file.readAsBytes());
    final existing = this[package.manifest.id];
    if (existing != null && !replace) throw ThemeInstalled(existing.title);
    await store.install(package);
    _installed = store.loadAllSync();
    return this[package.manifest.id]!;
  }

  /// Lets a theme the user imported go; those that come with the app stay.
  /// If it was the one shown, Default is.
  Future<void> remove(String id) async {
    final store = this.store;
    final theme = this[id];
    if (store == null || theme == null || theme.origin == ThemeOrigin.builtIn) return;
    await store.remove(id);
    _installed = store.loadAllSync();
    if (_appearance.themeId == id && this[id] == null) {
      await setAppearance(_appearance.copyWith(themeId: defaultThemeId));
    }
  }
}
