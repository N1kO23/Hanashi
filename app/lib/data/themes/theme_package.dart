import 'dart:isolate';
import 'dart:typed_data';

import '../packs/content_package.dart';
import '../packs/pictures.dart';
import '../packs/sounds.dart';
import 'theme_manifest.dart';

/// How large a theme's file, and what it holds, can be.
const themeLimits = PackageLimits(
  maxBytes: 8 * 1024 * 1024,
  maxEntries: 32,
  maxManifestBytes: 64 * 1024,
  maxFileBytes: maxThemeSoundBytes,
  maxTotalBytes: 16 * 1024 * 1024,
);

const maxThemeImageBytes = 1024 * 1024;
const maxThemeSoundBytes = 2 * 1024 * 1024;

/// The longest side of a theme's picture, in pixels.
const maxThemeImageSide = 2048;

/// A theme's file, read and checked (see [readThemePackage]): its manifest,
/// and the bytes of each file it brings, by role.
class ThemePackage {
  const ThemePackage(this.manifest, this.files);

  final ThemeManifest manifest;
  final Map<String, Uint8List> files;
}

/// Reads and checks [zip], a theme's file, off the UI isolate. Throws a
/// [PackageException] saying what is wrong with it.
Future<ThemePackage> readThemePackage(Uint8List zip) => Isolate.run(() => readThemePackageNow(zip));

/// [readThemePackage] on this isolate.
ThemePackage readThemePackageNow(Uint8List zip) {
  final read = readContentPackage(
    zip,
    limits: themeLimits,
    manifest: ThemeManifest.fromJson,
    files: (manifest) => manifest.assets.values.toSet(),
    maxBytesOf: (name) => name.endsWith('.png') || name.endsWith('.webp') ? maxThemeImageBytes : maxThemeSoundBytes,
    what: 'theme',
  );
  final manifest = read.manifest;
  final files = <String, Uint8List>{};
  for (final MapEntry(key: role, value: name) in manifest.assets.entries) {
    final bytes = read.files[name]!;
    final what = 'The $role of this theme ("$name")';
    if (ThemeManifest.imageRoles.contains(role)) {
      checkPicture(bytes, file: name, what: what, maxSide: maxThemeImageSide, types: const {'png', 'webp'});
    } else {
      checkSound(bytes, file: name, what: what);
    }
    files[role] = bytes;
  }
  return ThemePackage(manifest, files);
}

/// A theme's file of [manifest] and [files] (by role, as [manifest.assets]
/// names them).
Uint8List writeThemePackage(ThemeManifest manifest, Map<String, List<int>> files) => writeContentPackage(
  manifest.toJson(),
  {for (final MapEntry(key: role, value: name) in manifest.assets.entries) name: files[role]!},
);
