import 'dart:convert';
import 'dart:io';

import 'package:hanashi_protocol/hanashi_protocol.dart';

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
/// never taken for theirs. A folder holds `index.json` and the pictures,
/// named by their place (`000.webp`...), never by what the pack calls them:
/// sticker IDs may differ only in case, which some file systems do not tell
/// apart. Folders appear whole or not at all.
class StickerPackStore {
  StickerPackStore(this.root);

  final Directory root;
  final _loaded = <String, StoredPack>{};

  /// Being extracted: their folders are not for [gc] to take.
  final _installing = <String>{};

  static final _file = RegExp(r'^[0-9]{3}\.(webp|png|gif)$');

  /// The name of the folder of the pack whose file is [archiveHash].
  static String folderName(String archiveHash) => archiveHash.substring('sha256:'.length, 'sha256:'.length + 32);

  Directory _folder(String archiveHash) => Directory('${root.path}/${folderName(archiveHash)}');

  /// The pack whose file is [archiveHash], if it is on this device.
  Future<StoredPack?> load(String archiveHash) async {
    final known = _loaded[archiveHash];
    if (known != null) return known;
    final folder = _folder(archiveHash);
    try {
      final index = jsonDecode(await File('${folder.path}/index.json').readAsString()) as Map<String, Object?>;
      if (index['archive'] != archiveHash) return null;
      final stickers = [
        for (final sticker in (index['stickers']! as List).cast<Map<String, Object?>>())
          PackSticker(
            id: sticker['id']! as String,
            path: '${folder.path}/${_checkedName(sticker['file']! as String)}',
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

  /// Extracts [pack], whose file on the user's server is [archiveHash]; one
  /// there already stays.
  Future<StoredPack> install(StickerPackFile pack, String archiveHash) async {
    final existing = await load(archiveHash);
    if (existing != null) return existing;
    final target = _folder(archiveHash);
    final incoming = Directory('${root.path}/.incoming-${newUlid()}');
    _installing.add(archiveHash);
    try {
      await incoming.create(recursive: true);
      final stickers = <Map<String, Object?>>[];
      for (final (place, sticker) in pack.stickers.indexed) {
        final name = '${'$place'.padLeft(3, '0')}.${sticker.extension}';
        await File('${incoming.path}/$name').writeAsBytes(sticker.bytes, flush: true);
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
      await File('${incoming.path}/index.json').writeAsString(
        jsonEncode({
          'archive': archiveHash,
          'id': manifest.id,
          'title': manifest.title,
          'author': ?manifest.author,
          'cover': manifest.cover,
          'stickers': stickers,
        }),
        flush: true,
      );
      // One there that could not be loaded is damaged.
      if (target.existsSync()) await target.delete(recursive: true);
      await incoming.rename(target.path);
    } finally {
      _installing.remove(archiveHash);
      if (incoming.existsSync()) await incoming.delete(recursive: true);
    }
    final installed = await load(archiveHash);
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
      } on FileSystemException {
        // In use (on Windows, say): the next time.
      }
    }
  }

  /// Deletes every pack on this device.
  Future<void> clear() async {
    _loaded.clear();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
