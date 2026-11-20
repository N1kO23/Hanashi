import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/themes/app_theme.dart';
import 'package:hanashi/data/themes/theme_package.dart';
import 'package:hanashi/data/themes/theme_store.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';

import 'support/themes.dart';

void main() {
  late Directory dir;
  late ThemeStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hanashi-themes-');
    store = ThemeStore(Directory('${dir.path}/themes'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ThemePackage package({
    String id = 'test-theme',
    String title = 'Test theme',
    Map<String, Object?>? light = const {'header': '#336699'},
    Map<String, Object?>? dark,
    Map<String, String> assets = const {},
  }) => readThemePackageNow(syntheticThemeBytes(id: id, title: title, light: light, dark: dark, assets: assets));

  List<String> names(Directory folder) =>
      [for (final entry in folder.listSync()) entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)]..sort();

  test('installs a theme: its colours, and its files named by their role', () async {
    expect(store.loadAllSync(), isEmpty);
    await store.install(
      readThemePackageNow(
        syntheticThemeBytes(
          light: {'header': '#336699'},
          dark: {'header': '#111111'},
          assets: {'logo': 'mark.png', 'messageSound': 'ping.ogg'},
          extra: {'appName': 'Test Chat'},
        ),
      ),
    );
    expect(store.has('test-theme'), isTrue);
    final folder = Directory('${store.root.path}/test-theme');
    expect(names(folder), ['index.json', 'logo.png', 'messageSound.ogg']);
    expect(names(store.root), ['test-theme']);

    final [theme] = store.loadAllSync();
    expect(theme.id, 'test-theme');
    expect(theme.title, 'Test theme');
    expect(theme.author, 'Hanashi tests');
    expect(theme.appName, 'Test Chat');
    expect(theme.shownName, 'Test Chat');
    expect(theme.branding.appName, 'Test Chat');
    expect(theme.version, 1);
    expect(theme.origin, ThemeOrigin.imported);
    expect(theme.light.header, const Color(0xFF336699));
    expect(theme.light.brightness, Brightness.light);
    expect(theme.dark.header, const Color(0xFF111111));
    expect(theme.dark.brightness, Brightness.dark);
    expect(theme.assets.logo, FileSource('${folder.path}/logo.png'));
    expect(theme.assets.messageSound, FileSource('${folder.path}/messageSound.ogg'));
    expect(theme.assets.ringtone, isNull);
    expect(File('${folder.path}/messageSound.ogg').readAsBytesSync(), syntheticOgg);
  });

  test('a theme of one look shows it in light and dark mode alike', () async {
    await store.install(package(light: null, dark: {'header': '#111111'}));
    final [theme] = store.loadAllSync();
    expect(theme.light, theme.dark);
    expect(theme.light.header, const Color(0xFF111111));
  });

  test('replaces a theme of the same ID whole', () async {
    await store.install(package(assets: {'logo': 'logo.png'}));
    await store.install(package(title: 'Test theme 2', assets: {'ringtone': 'ring.wav'}));
    final [theme] = store.loadAllSync();
    expect(theme.title, 'Test theme 2');
    expect(theme.origin, ThemeOrigin.imported);
    expect(theme.assets.logo, isNull);
    expect(names(Directory('${store.root.path}/test-theme')), ['index.json', 'ringtone.wav']);
    // Nothing of the install stays behind.
    expect(names(store.root), ['test-theme']);
  });

  test('removes a theme', () async {
    await store.install(package());
    await store.install(package(id: 'other'));
    await store.remove('test-theme');
    expect(store.has('test-theme'), isFalse);
    expect([for (final theme in store.loadAllSync()) theme.id], ['other']);
    await store.remove('never-there');
  });

  test('passes over folders it cannot read', () async {
    await store.install(package());
    Directory('${store.root.path}/empty').createSync();
    Directory('${store.root.path}/damaged').createSync();
    File('${store.root.path}/damaged/index.json').writeAsStringSync('{"id": "damaged", "tit');
    // Its index says it is another theme.
    Directory('${store.root.path}/moved').createSync();
    File('${store.root.path}/moved/index.json')
        .writeAsStringSync(jsonEncode({'id': 'elsewhere', 'title': 'Moved', 'light': HanashiPalette.light.toJson()}));
    // A later version's colours that this one cannot read.
    Directory('${store.root.path}/later').createSync();
    File('${store.root.path}/later/index.json').writeAsStringSync(
      jsonEncode({
        'id': 'later',
        'title': 'Later',
        'light': {'header': 'oklch(70% 0.1 0)'},
      }),
    );
    File('${store.root.path}/stray.txt').writeAsStringSync('');
    expect([for (final theme in store.loadAllSync()) theme.id], ['test-theme']);
  });

  test('a file of a theme never names one outside its folder', () async {
    Directory('${store.root.path}/sneaky').createSync(recursive: true);
    File('${store.root.path}/sneaky/index.json').writeAsStringSync(
      jsonEncode({
        'id': 'sneaky',
        'title': 'Sneaky',
        'light': {'header': '#000000'},
        'files': {'logo': '../other/logo.png', 'ringtone': r'..\ring.wav', 'messageSound': 'ok.wav'},
      }),
    );
    final [theme] = store.loadAllSync();
    expect(theme.assets.logo, isNull);
    expect(theme.assets.ringtone, isNull);
    expect(theme.assets.messageSound, FileSource('${store.root.path}/sneaky/ok.wav'));
  });

  test('lets go what an install left behind, once it is old enough not to be going on', () async {
    await store.install(package());
    Directory('${store.root.path}/.incoming-01ABC/x').createSync(recursive: true);
    Directory('${store.root.path}/.old-01DEF').createSync();
    store.loadAllSync();
    expect(names(store.root), ['.incoming-01ABC', '.old-01DEF', 'test-theme']);

    final later = ThemeStore(store.root, now: () => DateTime.now().add(ThemeStore.leftoverAge * 2));
    expect([for (final theme in later.loadAllSync()) theme.id], ['test-theme']);
    expect(names(store.root), ['test-theme']);
  });
}
