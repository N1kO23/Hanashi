import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/packs/content_package.dart';
import 'package:hanashi/data/themes/app_theme.dart';
import 'package:hanashi/data/themes/appearance.dart';
import 'package:hanashi/data/themes/builtin_themes.dart';
import 'package:hanashi/data/themes/theme_library.dart';

import 'support/themes.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi-library-'));
  tearDown(() => dir.deleteSync(recursive: true));

  File appearanceFile() => File('${dir.path}/${ThemeLibrary.fileName}');

  /// A theme file in [dir] to import.
  String themeFile({String id = 'test-theme', String title = 'Test theme', String name = 'theme.zip'}) {
    final file = File('${dir.path}/$name')..writeAsBytesSync(syntheticThemeBytes(id: id, title: title));
    return file.path;
  }

  List<String> ids(ThemeLibrary library) => [for (final theme in library.themes) theme.id];

  /// The themes that come with the app, first in the list.
  final builtIn = [for (final theme in builtInThemes) theme.id];

  group('appearance', () {
    test("a device's first start: Default, written down at once", () {
      final library = ThemeLibrary.load(dir);
      expect(library.appearance, const Appearance(themeId: defaultThemeId));
      expect(library.active.id, defaultThemeId);
      expect(jsonDecode(appearanceFile().readAsStringSync()), {'theme': defaultThemeId, 'mode': 'system'});
    });

    test('kept in its file', () async {
      final library = ThemeLibrary.load(dir);
      await library.setAppearance(const Appearance(themeId: defaultThemeId, mode: ThemeMode.dark));
      expect(jsonDecode(appearanceFile().readAsStringSync()), {'theme': 'default', 'mode': 'dark'});
      final again = ThemeLibrary.load(dir);
      expect(again.appearance, const Appearance(themeId: defaultThemeId, mode: ThemeMode.dark));
      expect(again.active, defaultTheme);
    });

    test('of quick changes, the last is the one kept', () async {
      final library = ThemeLibrary.load(dir);
      await Future.wait([
        library.setAppearance(const Appearance(themeId: 'first')),
        library.setAppearance(const Appearance(themeId: 'second', mode: ThemeMode.light)),
        library.setAppearance(const Appearance(themeId: defaultThemeId, mode: ThemeMode.dark)),
      ]);
      expect(jsonDecode(appearanceFile().readAsStringSync()), {'theme': 'default', 'mode': 'dark'});
      expect(dir.listSync().where((entry) => entry.path.contains('${ThemeLibrary.fileName}.')), isEmpty);
    });

    test('what it does not understand is the default', () {
      expect(
        Appearance.fromJson({'theme': 'mine', 'mode': 'sepia'}, fallbackTheme: 'x'),
        const Appearance(themeId: 'mine'),
      );
      expect(
        Appearance.fromJson({'theme': '', 'mode': 'light'}, fallbackTheme: 'x'),
        const Appearance(themeId: 'x', mode: ThemeMode.light),
      );
      expect(Appearance.fromJson([1, 2], fallbackTheme: 'x'), const Appearance(themeId: 'x'));
      appearanceFile().writeAsStringSync('{"theme": "def');
      expect(ThemeLibrary.load(dir).appearance, const Appearance(themeId: defaultThemeId));
    });

    test('a theme no longer there: Default shows', () {
      appearanceFile().writeAsStringSync(jsonEncode({'theme': 'gone', 'mode': 'light'}));
      final library = ThemeLibrary.load(dir);
      expect(library.appearance.themeId, 'gone');
      expect(library.active.id, defaultThemeId);
    });

    test('without a folder (tests): kept in memory', () async {
      final library = ThemeLibrary.load(null);
      await library.setAppearance(const Appearance(themeId: defaultThemeId));
      expect(library.active, defaultTheme);
      expect(() => library.import(themeFile()), throwsStateError);
    });
  });

  group('themes', () {
    test('the built-in ones first, then the others by title', () async {
      final library = ThemeLibrary.load(dir);
      expect(ids(library), builtIn);
      await library.import(themeFile(id: 'zeta', title: 'zeta', name: 'z.zip'));
      await library.import(themeFile(id: 'alpha', title: 'Beta', name: 'a.zip'));
      await library.import(themeFile(id: 'beta', title: 'Alpha', name: 'b.zip'));
      expect(ids(library), [...builtIn, 'beta', 'alpha', 'zeta']);
      expect(ids(ThemeLibrary.load(dir)), ids(library));
    });

    test('imports a theme file', () async {
      final library = ThemeLibrary.load(dir);
      final theme = await library.import(themeFile());
      expect(theme.id, 'test-theme');
      expect(theme.origin, ThemeOrigin.imported);
      expect(library['test-theme'], isNotNull);
      // Importing does not show it: the controller in the app does that.
      expect(library.active, defaultTheme);
    });

    test('replaces a theme of the same ID only when asked', () async {
      final library = ThemeLibrary.load(dir);
      await library.import(themeFile());
      final again = themeFile(title: 'Test theme, again', name: 'again.zip');
      await expectLater(
        library.import(again),
        throwsA(isA<ThemeInstalled>().having((e) => e.title, 'title', 'Test theme')),
      );
      expect(library['test-theme']!.title, 'Test theme');
      await library.import(again, replace: true);
      expect(library['test-theme']!.title, 'Test theme, again');
    });

    test('says why a file is not a theme', () async {
      final library = ThemeLibrary.load(dir);
      final file = File('${dir.path}/stickers.zip')
        ..writeAsBytesSync(syntheticThemeBytes(extra: {'type': 'sticker-pack'}));
      await expectLater(
        library.import(file.path),
        throwsA(isA<PackageException>().having((e) => e.message, 'message', 'This is not a theme')),
      );
      final large = File('${dir.path}/large.zip')..writeAsBytesSync(Uint8List(8 * 1024 * 1024 + 1));
      await expectLater(
        library.import(large.path),
        throwsA(isA<PackageException>().having((e) => e.message, 'message', 'This theme is larger than 8 MB')),
      );
      expect(ids(library), builtIn);
    });

    test('removes an imported theme; if it was shown, Default is', () async {
      final library = ThemeLibrary.load(dir);
      await library.import(themeFile());
      await library.setAppearance(const Appearance(themeId: 'test-theme', mode: ThemeMode.dark));
      expect(library.active.id, 'test-theme');
      await library.remove('test-theme');
      expect(library['test-theme'], isNull);
      expect(library.appearance, const Appearance(themeId: defaultThemeId, mode: ThemeMode.dark));
      expect(jsonDecode(appearanceFile().readAsStringSync()), {'theme': defaultThemeId, 'mode': 'dark'});
      expect(Directory('${dir.path}/themes/test-theme').existsSync(), isFalse);
    });

    test('Default stays', () async {
      final library = ThemeLibrary.load(dir);
      await library.remove(defaultThemeId);
      expect(ids(library), builtIn);
      expect(library.active, defaultTheme);
    });
  });
}
