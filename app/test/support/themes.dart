import 'dart:typed_data';

import 'package:hanashi/data/packs/content_package.dart';

import 'sticker_packs.dart';

/// A short, quiet WAV: 8-bit mono at 8 kHz. Made here, as no test needs
/// anyone's sound.
Uint8List syntheticWav({int samples = 800}) {
  final data = ByteData(44 + samples);
  void text(int at, String value) {
    for (final (i, unit) in value.codeUnits.indexed) {
      data.setUint8(at + i, unit);
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + samples, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, 8000, Endian.little)
    ..setUint32(28, 8000, Endian.little)
    ..setUint16(32, 1, Endian.little)
    ..setUint16(34, 8, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setUint8(44 + i, 128);
  }
  return data.buffer.asUint8List();
}

/// The start of an Ogg file, as the theme check reads one.
final syntheticOgg = Uint8List.fromList([...'OggS'.codeUnits, 0, 2, ...List.filled(40, 0)]);

/// The start of an MP3 with an ID3 tag, as the theme check reads one.
final syntheticMp3 = Uint8List.fromList([...'ID3'.codeUnits, 4, 0, 0, ...List.filled(40, 0)]);

/// The `pack.json` of a theme; [extra] goes over it (null takes a key away).
Map<String, Object?> themeManifestJson({
  String id = 'test-theme',
  String title = 'Test theme',
  Map<String, Object?>? light = const {'header': '#336699'},
  Map<String, Object?>? dark,
  Map<String, String> assets = const {},
  Map<String, Object?> extra = const {},
}) {
  final json = <String, Object?>{
    'format': 1,
    'type': 'theme',
    'id': id,
    'title': title,
    'author': 'Hanashi tests',
    'version': 1,
    'light': ?light,
    'dark': ?dark,
    if (assets.isNotEmpty) 'assets': assets,
  };
  for (final MapEntry(:key, :value) in extra.entries) {
    if (value == null) {
      json.remove(key);
    } else {
      json[key] = value;
    }
  }
  return json;
}

/// The file of a theme, with [files] (by name) next to its `pack.json`.
Uint8List syntheticThemeBytes({
  String id = 'test-theme',
  String title = 'Test theme',
  Map<String, Object?>? light = const {'header': '#336699'},
  Map<String, Object?>? dark,
  Map<String, String> assets = const {},
  Map<String, List<int>>? files,
  Map<String, Object?> extra = const {},
}) => writeContentPackage(
  themeManifestJson(id: id, title: title, light: light, dark: dark, assets: assets, extra: extra),
  files ??
      {
        for (final name in assets.values)
          name: switch (name.split('.').last) {
            'wav' => syntheticWav(),
            'ogg' => syntheticOgg,
            'mp3' => syntheticMp3,
            _ => syntheticSticker(1),
          },
      },
);
