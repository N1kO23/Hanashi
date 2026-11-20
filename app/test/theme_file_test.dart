import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/packs/content_package.dart';
import 'package:hanashi/data/packs/sounds.dart';
import 'package:hanashi/data/themes/theme_manifest.dart';
import 'package:hanashi/data/themes/theme_package.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';

import 'support/sticker_packs.dart';
import 'support/themes.dart';

void main() {
  test('reads a theme: its colours, and its files by role', () {
    final package = readThemePackageNow(
      syntheticThemeBytes(
        light: {'header': '#336699'},
        dark: {'chatBackground': '#000000'},
        assets: {'logo': 'logo.png', 'messageSound': 'ping.ogg', 'ringtone': 'ring.wav'},
      ),
    );
    final manifest = package.manifest;
    expect(manifest.id, 'test-theme');
    expect(manifest.title, 'Test theme');
    expect(manifest.author, 'Hanashi tests');
    expect(manifest.version, 1);
    expect(manifest.light!.header, const Color(0xFF336699));
    expect(manifest.light!.brightness, Brightness.light);
    expect(manifest.dark!.chatBackground, const Color(0xFF000000));
    expect(manifest.dark!.header, HanashiPalette.dark.header);
    expect(manifest.assets, {'logo': 'logo.png', 'messageSound': 'ping.ogg', 'ringtone': 'ring.wav'});
    expect(package.files.keys, unorderedEquals(['logo', 'messageSound', 'ringtone']));
    expect(package.files['ringtone'], syntheticWav());
  });

  test('a theme of one look, and a later version\'s files left alone', () {
    final package = readThemePackageNow(
      syntheticThemeBytes(
        light: null,
        dark: {'header': '#222222'},
        assets: {'confetti': 'confetti.png'},
        files: {'confetti.png': syntheticSticker(1)},
      ),
    );
    expect(package.manifest.light, isNull);
    expect(package.manifest.dark!.header, const Color(0xFF222222));
    expect(package.manifest.assets, isEmpty);
  });

  test("a theme's name for the app: trimmed, and passed over if it is too long", () {
    ThemeManifest read(Object? appName) =>
        readThemePackageNow(syntheticThemeBytes(extra: {'appName': appName})).manifest;
    expect(read('  Night Chat ').appName, 'Night Chat');
    expect(read('x' * ThemeManifest.maxAppName).appName, hasLength(ThemeManifest.maxAppName));
    for (final wrong in ['x' * (ThemeManifest.maxAppName + 1), '   ', 7]) {
      expect(read(wrong).appName, isNull, reason: '$wrong');
    }
    expect(readThemePackageNow(syntheticThemeBytes()).manifest.appName, isNull);
  });

  test('writes a theme it reads back', () {
    final manifest = ThemeManifest(
      id: 'written',
      title: 'Written',
      appName: 'Written Chat',
      light: HanashiPalette.light,
      dark: HanashiPalette.dark,
      assets: const {'messageSound': 'message.wav'},
    );
    final read = readThemePackageNow(writeThemePackage(manifest, {'messageSound': syntheticWav()}));
    expect(read.manifest.appName, 'Written Chat');
    expect(read.manifest.light, HanashiPalette.light);
    expect(read.manifest.dark, HanashiPalette.dark);
    expect(read.files['messageSound'], syntheticWav());
  });

  test('knows a sound by its first bytes and its extension', () {
    expect(checkSound(syntheticWav(), file: 'a.wav', what: 'It'), 'audio/wav');
    expect(checkSound(syntheticOgg, file: 'a.ogg', what: 'It'), 'audio/ogg');
    expect(checkSound(syntheticMp3, file: 'a.mp3', what: 'It'), 'audio/mpeg');
    expect(checkSound(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64]), file: 'a.mp3', what: 'It'), 'audio/mpeg');
    for (final (bytes, file) in [
      (syntheticOgg, 'a.wav'),
      (syntheticWav(), 'a.mp3'),
      (Uint8List.fromList('RIFF....AVI '.codeUnits), 'a.wav'),
      (Uint8List(0), 'a.ogg'),
    ]) {
      expect(
        () => checkSound(bytes, file: file, what: 'It'),
        throwsA(isA<PackageException>().having((e) => e.message, 'message', 'It is not the sound its file says')),
      );
    }
  });

  group('refuses', () {
    void refuses(Uint8List file, Object message) => expect(
      () => readThemePackageNow(file),
      throwsA(isA<PackageException>().having((e) => e.message, 'message', message)),
    );

    test('what is not a theme', () {
      refuses(syntheticStickerPackBytes(), 'This is not a theme');
      refuses(Uint8List.fromList('not a zip'.codeUnits), contains('not a theme'));
    });

    test('a theme of a later format', () {
      refuses(syntheticThemeBytes(extra: {'format': 2}), 'This theme needs a newer version of Hanashi');
    });

    test('IDs that cannot be folder names, and "default"', () {
      for (final id in ['Upper', '-dash', '../up', 'a/b', '', 'x' * 65]) {
        refuses(syntheticThemeBytes(id: id), contains('no valid ID'));
      }
      refuses(syntheticThemeBytes(id: 'default'), 'A theme cannot be called "default"');
    });

    test('a theme without a title or colours', () {
      refuses(syntheticThemeBytes(extra: {'title': null}), 'This theme has no title');
      refuses(syntheticThemeBytes(light: null), 'This theme has neither "light" nor "dark" colours');
      refuses(syntheticThemeBytes(light: {'header': 'pink'}), allOf(contains('"header"'), contains('"light"')));
    });

    test('files of a kind a role does not take', () {
      refuses(syntheticThemeBytes(assets: {'logo': 'logo.gif'}), contains('must be a .png or .webp file'));
      // The system draws the app's icon, and not every one reads WebP.
      refuses(
        syntheticThemeBytes(assets: {'appIcon': 'icon.webp'}),
        '"appIcon" of this theme must be a .png file, in no folder',
      );
      refuses(syntheticThemeBytes(assets: {'logo': 'art/logo.png'}), contains('in no folder'));
      refuses(syntheticThemeBytes(assets: {'ringtone': 'ring.flac'}), contains('must be a .wav, .ogg or .mp3 file'));
    });

    test('a file that is not what its name says', () {
      refuses(
        syntheticThemeBytes(assets: {'messageSound': 'ping.wav'}, files: {'ping.wav': syntheticOgg}),
        'The messageSound of this theme ("ping.wav") is not the sound its file says',
      );
      refuses(
        syntheticThemeBytes(assets: {'logo': 'logo.webp'}, files: {'logo.webp': syntheticSticker(1)}),
        'The logo of this theme ("logo.webp") is not the picture its file says',
      );
    });

    test('a file it does not have', () {
      refuses(syntheticThemeBytes(assets: {'logo': 'logo.png'}, files: {}), 'This theme has no "logo.png"');
    });

    test('pictures that move, or are too large', () {
      final moving = syntheticPicture(1)..addFrame(syntheticPicture(2));
      refuses(
        syntheticThemeBytes(assets: {'logo': 'logo.png'}, files: {'logo.png': img.encodePng(moving)}),
        contains('must be a still picture'),
      );
      refuses(
        syntheticThemeBytes(assets: {'appIcon': 'icon.png'}, files: {'icon.png': syntheticSticker(1, size: 2049)}),
        contains('is larger than 2048×2048'),
      );
    });

    test('files over their limits', () {
      refuses(
        syntheticThemeBytes(assets: {'logo': 'logo.png'}, files: {'logo.png': Uint8List(maxThemeImageBytes + 1)}),
        '"logo.png" in this theme is larger than 1 MB',
      );
      refuses(
        syntheticThemeBytes(
          assets: {'ringtone': 'ring.wav'},
          files: {'ring.wav': syntheticWav(samples: maxThemeSoundBytes)},
        ),
        '"ring.wav" in this theme is larger than 2 MB',
      );
    });
  });
}
