import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A file that is not a package this version takes; [message] says why, for
/// the user.
class PackageException implements Exception {
  const PackageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How large a package, and what it holds, can be.
class PackageLimits {
  const PackageLimits({
    required this.maxBytes,
    required this.maxEntries,
    required this.maxManifestBytes,
    required this.maxFileBytes,
    required this.maxTotalBytes,
  });

  /// The package file itself.
  final int maxBytes;

  /// Entries of its zip, folders and files it does not name included.
  final int maxEntries;

  final int maxManifestBytes;

  /// Any one file it names, inflated.
  final int maxFileBytes;

  /// All of its entries together, inflated, as its zip declares them.
  final int maxTotalBytes;
}

/// What a package calls its manifest, at its top level.
const packageManifest = 'pack.json';

/// Reads [zip], a package: a zip file of [packageManifest] (JSON, read by
/// [manifest]) and the files [files] names from it, all at its top level.
///
/// The zip's directory is checked against [limits] before anything is
/// inflated: how many entries, how large each says it is and all together,
/// and that none is encrypted, a link, or compressed other than by deflate.
/// Then only the manifest and the files it names are inflated, never past
/// the size the directory gave them, and checked against their CRC. Nothing
/// the zip names ever becomes a path: callers write what they keep under
/// names of their own. A file can be at most [PackageLimits.maxFileBytes],
/// or what [maxBytesOf] says for it. Throws a [PackageException].
({T manifest, Map<String, Uint8List> files}) readContentPackage<T>(
  Uint8List zip, {
  required PackageLimits limits,
  required T Function(Map<String, Object?> json) manifest,
  required Iterable<String> Function(T manifest) files,
  int Function(String name)? maxBytesOf,
  String what = 'package',
}) {
  if (zip.length > limits.maxBytes) throw PackageException('This $what is larger than ${_size(limits.maxBytes)}');
  final damaged = PackageException('This $what is damaged');
  final entries = <String, ZipFileHeader>{};
  try {
    var total = 0;
    for (final header in ZipDirectory().headers(InputMemoryStream(zip), verify: true)) {
      if (entries.length >= limits.maxEntries) throw PackageException('This $what holds too many files');
      final name = header.filename;
      // Two of a name: one could be checked and the other used.
      if (entries.containsKey(name)) throw damaged;
      entries[name] = header;
      if (header.generalPurposeBitFlag & ZipEncoder.fileEncryptionBit != 0) {
        throw PackageException('This $what is encrypted');
      }
      if (header.compressionMethod != ZipFile.zipCompressionStore &&
          header.compressionMethod != ZipFile.zipCompressionDeflate) {
        throw PackageException('This $what is compressed in a way Hanashi does not read');
      }
      // A symbolic link, as Unix zips mark one.
      if (header.versionMadeBy >> 8 == 3 && (header.externalFileAttributes >> 16) & 0xF000 == 0xA000) {
        throw PackageException('This $what holds a link');
      }
      final size = header.uncompressedSize;
      if (size < 0 || size > limits.maxTotalBytes || (total += size) > limits.maxTotalBytes) {
        throw PackageException('This $what is larger than ${_size(limits.maxTotalBytes)} unpacked');
      }
    }
  } on PackageException {
    rethrow;
  } on Object {
    throw damaged;
  }

  Uint8List read(String name, int maxBytes) {
    final header = entries[name];
    if (header == null) {
      throw PackageException(
        name == packageManifest ? 'This is not a $what: it has no $name' : 'This $what has no "$name"',
      );
    }
    if (header.uncompressedSize > maxBytes) {
      throw PackageException('"$name" in this $what is larger than ${_size(maxBytes)}');
    }
    try {
      final file = header.file!
        ..verify = true
        ..throwOnError = true;
      final bytes = file.readBytes();
      if (bytes.length != header.uncompressedSize) throw damaged;
      return bytes;
    } on PackageException {
      rethrow;
    } on Object {
      throw damaged;
    }
  }

  final Object? json;
  try {
    json = jsonDecode(utf8.decode(read(packageManifest, limits.maxManifestBytes)));
  } on FormatException {
    throw damaged;
  }
  if (json is! Map) throw damaged;
  final T parsed;
  try {
    parsed = manifest(json.cast<String, Object?>());
  } on FormatException catch (e) {
    throw PackageException(e.message);
  }
  return (
    manifest: parsed,
    files: {for (final name in files(parsed)) name: read(name, maxBytesOf?.call(name) ?? limits.maxFileBytes)},
  );
}

/// A package of [manifest] and [files], each stored as it is (pictures are
/// compressed already), dated the same every time: the same contents make
/// the same file.
Uint8List writeContentPackage(Map<String, Object?> manifest, Map<String, List<int>> files) {
  final archive = Archive();
  final json = utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest));
  archive.add(ArchiveFile.noCompress(packageManifest, json.length, json));
  for (final MapEntry(:key, :value) in files.entries) {
    archive.add(ArchiveFile.noCompress(key, value.length, value));
  }
  return ZipEncoder().encodeBytes(archive, modified: DateTime.utc(2026));
}

String _size(int bytes) => bytes >= 1024 * 1024 ? '${bytes ~/ (1024 * 1024)} MB' : '${bytes ~/ 1024} KB';
