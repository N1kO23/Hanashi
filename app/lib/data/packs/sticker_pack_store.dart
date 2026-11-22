import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../e2ee/file_cipher.dart';
import '../../e2ee/primitives.dart';
import '../decrypted_cache.dart';
import 'sticker_pack.dart';
import 'sticker_pack_file.dart';

/// A sticker pack extracted on this device (see [StickerPackStore]).
class StoredPack {
  const StoredPack({required this.archive, required this.id, required this.title, this.author, required this.stickers});

  /// The hash of its file on the user's server.
  final String archive;
  final String id;
  final String title;
  final String? author;
  final List<PackSticker> stickers;

  /// As the picker shows it, [entry] being how the user's packs list it.
  StickerPack view(PackEntry entry) =>
      StickerPack(id: id, title: title, author: author, archive: entry.archive, stickers: stickers);
}

/// The sticker packs on this device, extracted: each in a folder named by
/// the hash of its file on the user's server, so another account's are
/// never taken for theirs. A folder holds `index.sealed` and the pictures,
/// named by their place (`000.webp`...), never by what the pack calls them:
/// sticker IDs may differ only in case, which some file systems do not tell
/// apart. Folders appear whole or not at all.
///
/// All of it is encrypted (see [FileCipher]) with a key from that of the
/// pack's file, which only the user's account data holds, in the encrypted
/// database: nothing here is readable without it. Pictures are decrypted
/// into memory to show them (see [packPicture]). A folder of a version
/// before 1.0.5, decrypted, has no `index.sealed`: it is fetched again.
class StickerPackStore {
  StickerPackStore(this.root);

  final Directory root;
  final _loaded = <String, StoredPack>{};

  /// Being extracted: their folders are not for [gc] to take.
  final _installing = <String>{};

  static final _file = RegExp(r'^[0-9]{3}\.(webp|png|gif)$');
  static const _index = 'index.sealed';

  /// The key a pack's files here are encrypted with: one of their own, from
  /// that of its file on the server ([archive]).
  static Future<Uint8List> _keyOf(MediaRef archive) async {
    final key = archive.key;
    if (key == null) throw const FormatException('A sticker pack file without a key');
    return hkdf(base64.decode(key), 'hanashi-sticker-pack-files-v1');
  }

  /// The name of the folder of the pack whose file is [archiveHash].
  static String folderName(String archiveHash) => archiveHash.substring('sha256:'.length, 'sha256:'.length + 32);

  Directory _folder(String archiveHash) => Directory('${root.path}/${folderName(archiveHash)}');

  /// The pack whose file is [archive], if it is on this device.
  Future<StoredPack?> load(MediaRef archive) async {
    final archiveHash = archive.hash;
    final known = _loaded[archiveHash];
    if (known != null) return known;
    final folder = _folder(archiveHash);
    try {
      final key = await _keyOf(archive);
      final sealed = await FileCipher.decryptBytes('${folder.path}/$_index', key);
      final index = jsonDecode(utf8.decode(sealed)) as Map<String, Object?>;
      if (index['archive'] != archiveHash) return null;
      final stickers = [
        for (final sticker in (index['stickers']! as List).cast<Map<String, Object?>>())
          PackSticker(
            id: sticker['id']! as String,
            path: '${folder.path}/${_checkedName(sticker['file']! as String)}',
            key: key,
            mime: sticker['mime'] as String?,
            width: sticker['w'] as int?,
            height: sticker['h'] as int?,
            emoji: sticker['emoji'] as String?,
          ),
      ];
      return _loaded[archiveHash] = StoredPack(
        archive: archiveHash,
        id: index['id']! as String,
        title: index['title']! as String,
        author: index['author'] as String?,
        stickers: stickers,
      );
    } on Object {
      // Not here, or damaged: fetched again.
      return null;
    }
  }

  static String _checkedName(String name) =>
      _file.hasMatch(name) ? name : throw FormatException('Not a sticker file', name);

  /// Extracts [pack], whose file on the user's server is [archive]; one there
  /// already stays.
  Future<StoredPack> install(StickerPackFile pack, MediaRef archive) async {
    final archiveHash = archive.hash;
    final existing = await load(archive);
    if (existing != null) return existing;
    final key = await _keyOf(archive);
    final target = _folder(archiveHash);
    final incoming = Directory('${root.path}/.incoming-${newUlid()}');
    _installing.add(archiveHash);
    try {
      await incoming.create(recursive: true);
      final stickers = <Map<String, Object?>>[];
      for (final (place, sticker) in pack.stickers.indexed) {
        final name = '${'$place'.padLeft(3, '0')}.${sticker.extension}';
        await FileCipher.encryptBytes(sticker.bytes, '${incoming.path}/$name', key);
        stickers.add({
          'id': sticker.item.id,
          'file': name,
          'mime': sticker.mime,
          'w': sticker.width,
          'h': sticker.height,
          'frames': sticker.frames,
          'emoji': ?sticker.item.emoji,
        });
      }
      final manifest = pack.manifest;
      final index = jsonEncode({
        'archive': archiveHash,
        'id': manifest.id,
        'title': manifest.title,
        'author': ?manifest.author,
        'cover': manifest.cover,
        'stickers': stickers,
      });
      await FileCipher.encryptBytes(utf8.encode(index), '${incoming.path}/$_index', key);
      // One there that could not be loaded is damaged, or from before 1.0.5.
      if (target.existsSync()) await target.delete(recursive: true);
      _forgetPictures(target);
      await incoming.rename(target.path);
    } finally {
      _installing.remove(archiveHash);
      if (incoming.existsSync()) await incoming.delete(recursive: true);
    }
    final installed = await load(archive);
    if (installed == null) throw FileSystemException('Could not keep the sticker pack', target.path);
    return installed;
  }

  /// Deletes the packs but those whose files are [keep] (hashes), and what
  /// an extraction left behind.
  Future<void> gc(Set<String> keep) async {
    final kept = {
      for (final hash in {...keep, ..._installing}) folderName(hash),
    };
    _loaded.removeWhere((hash, _) => !keep.contains(hash) && !_installing.contains(hash));
    if (!root.existsSync()) return;
    final busy = _installing.isNotEmpty;
    await for (final entry in root.list()) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (kept.contains(name) || (busy && name.startsWith('.incoming-'))) continue;
      try {
        await entry.delete(recursive: true);
        _forgetPictures(entry);
      } on FileSystemException {
        // In use (on Windows, say): the next time.
      }
    }
  }

  /// Deletes every pack on this device.
  Future<void> clear() async {
    _loaded.clear();
    _forgetPictures(root);
    if (root.existsSync()) await root.delete(recursive: true);
  }

  static void _forgetPictures(FileSystemEntity folder) => _pictures.forget((path) => path.startsWith(folder.path));
}

/// Pictures of packs decrypted lately (see [DecryptedCache]), by their path.
final _pictures = DecryptedCache(maxBytes: 16 << 20);

/// [sticker]'s picture, decrypted into memory (see [PackSticker.key]).
Future<Uint8List> packPicture(PackSticker sticker) {
  final path = sticker.path!, key = sticker.key;
  return key == null ? File(path).readAsBytes() : _pictures.get(path, () => FileCipher.decryptBytes(path, key));
}

/// [sticker]'s picture, if it was decrypted lately.
Uint8List? packPictureNow(PackSticker sticker) => sticker.path == null ? null : _pictures.peek(sticker.path!);
