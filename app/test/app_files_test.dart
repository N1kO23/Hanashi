import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app comes with its own files only, none of anyone else's art (see the
/// fan-project note in README.md). A file of the app's own added to its
/// assets goes in these lists too; art of a game goes in a theme or a sticker
/// pack, files the app imports.
void main() {
  List<String> filesIn(String folder) => [
    for (final entry in Directory(folder).listSync(recursive: true))
      if (entry is File) entry.path.replaceAll(r'\', '/'),
  ]..sort();

  test('the app bundles only its own files', () {
    expect(filesIn('assets'), [
      for (final theme in ['default', 'ember', 'forest', 'graphite', 'lavender', 'ocean', 'sakura'])
        'assets/branding/icon_$theme.png',
      'assets/sounds/ringtone.wav',
    ]);
  });

  test('pubspec.yaml bundles those folders and nothing else', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final listed = RegExp(r'^  assets:\n((?:    .*\n)+)', multiLine: true).firstMatch(pubspec)!.group(1)!;
    expect(
      [
        for (final line in listed.split('\n'))
          if (line.trim().startsWith('- ')) line.trim().substring(2),
      ],
      ['assets/branding/', 'assets/sounds/'],
    );
  });

  test('Android comes with no sound of its own', () {
    expect(filesIn('android/app/src/main/res/raw'), ['android/app/src/main/res/raw/keep.xml']);
  });
}
