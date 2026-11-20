import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Color;
import 'package:hanashi/data/packs/pictures.dart';
import 'package:hanashi/data/themes/app_theme.dart';
import 'package:hanashi/data/themes/builtin_themes.dart';
import 'package:hanashi/data/themes/theme_library.dart';
import 'package:hanashi/data/themes/theme_manifest.dart';
import 'package:hanashi/data/themes/theme_package.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';

/// One of the app's files.
Future<Uint8List> _asset(String asset) => File(asset).readAsBytes();

/// Default's files, and `tool/make_theme.py` against the app.
void main() {
  test("Default's files are the app's own, and as a theme file's would be", () async {
    final assets = defaultTheme.assets;
    expect([assets.logo, assets.wordmark, assets.messageSound], everyElement(isNull));
    final icon = await _asset((assets.appIcon! as AssetSource).asset);
    expect(
      checkPicture(icon, file: 'icon_default.png', what: 'Its icon', maxSide: maxThemeImageSide, types: const {'png'}),
      (mime: 'image/png', width: 512, height: 512, frames: 1),
    );
    expect(await File((assets.ringtone! as AssetSource).asset).exists(), isTrue);
  });

  test('the theme tool knows the colours the app does', () {
    final tool = File('tool/make_theme.py').readAsStringSync();
    final listed = RegExp(r'SLOTS = \[(.*?)\]', dotAll: true).firstMatch(tool)!.group(1)!;
    expect(RegExp(r"'(\w+)'").allMatches(listed).map((m) => m.group(1)).toList(), [
      for (final slot in PaletteSlot.values) slot.name,
    ]);
  });

  test('the theme tool takes the file the app makes, and the app the one the tool makes', () async {
    final ProcessResult version;
    try {
      version = Process.runSync('python3', ['--version']);
    } on ProcessException {
      markTestSkipped('No python3');
      return;
    }
    if (version.exitCode != 0) return markTestSkipped('No python3');
    final dir = Directory.systemTemp.createTempSync('hanashi-theme-tool-');
    addTearDown(() => dir.deleteSync(recursive: true));

    final manifest = ThemeManifest(
      id: 'sample',
      title: 'Sample',
      light: HanashiPalette.light,
      dark: HanashiPalette.dark,
      assets: const {'appIcon': 'icon.png', 'ringtone': 'ring.wav'},
    );
    final made = File('${dir.path}/sample.zip')
      ..writeAsBytesSync(
        writeThemePackage(manifest, {
          'appIcon': await _asset('assets/branding/icon_default.png'),
          'ringtone': await _asset('assets/sounds/ringtone.wav'),
        }),
      );
    final checked = Process.runSync('python3', ['tool/make_theme.py', '--check', made.path]);
    expect(checked.exitCode, 0, reason: '${checked.stdout}${checked.stderr}');
    expect(checked.stdout, contains('"Sample" (sample), light and dark colours; appIcon icon.png (512x512)'));

    // A folder of the theme's files, packed by the tool.
    final folder = Directory('${dir.path}/folder')..createSync();
    File('${folder.path}/pack.json').writeAsStringSync('''
{"format": 1, "type": "theme", "id": "night", "title": "Night", "author": "Hanashi tests",
 "dark": {"header": "#203040", "avatarColors": ["#405060"], "sparkle": "#FFFFFF"},
 "assets": {"logo": "logo.png", "ringtone": "ring.wav"}}
''');
    File('${folder.path}/logo.png').writeAsBytesSync(await _asset('assets/branding/icon_default.png'));
    File('${folder.path}/ring.wav').writeAsBytesSync(await _asset('assets/sounds/ringtone.wav'));
    final packed = Process.runSync('python3', ['tool/make_theme.py', folder.path, '-o', '${dir.path}/night.zip']);
    expect(packed.exitCode, 0, reason: '${packed.stdout}${packed.stderr}');
    expect(packed.stdout, contains('"sparkle" is no colour this version knows'));
    final read = readThemePackageNow(File('${dir.path}/night.zip').readAsBytesSync());
    expect(read.manifest.dark!.header, const Color(0xFF203040));
    expect(read.manifest.light, isNull);
    expect(read.files.keys, unorderedEquals(['logo', 'ringtone']));

    // What the app refuses, the tool does too.
    File('${folder.path}/ring.wav').writeAsBytesSync(await _asset('assets/branding/icon_default.png'));
    final refused = Process.runSync('python3', ['tool/make_theme.py', folder.path, '-o', '${dir.path}/bad.zip']);
    expect(refused.exitCode, isNot(0));
    expect(refused.stderr, contains('ringtone: ring.wav is not the sound its name says'));
    expect(File('${dir.path}/bad.zip').existsSync(), isFalse);

    // The library takes the tool's file as it takes any.
    final library = ThemeLibrary.load(dir);
    final theme = await library.import('${dir.path}/night.zip');
    expect(theme.light, theme.dark);
    expect(theme.assets.ringtone, isA<FileSource>());
  });
}
