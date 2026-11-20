import 'envelope.dart';

/// A sticker in a pack: its ID, as messages name it (see [StickerSource]),
/// and its picture's file in the pack.
class StickerPackItem {
  const StickerPackItem({required this.id, required this.file, this.emoji});

  final String id;
  final String file;

  /// An emoji it goes with, if the pack says.
  final String? emoji;

  Map<String, Object?> toJson() => {'id': id, 'file': file, 'emoji': ?emoji};
}

/// What a sticker pack holds: its `pack.json`. A pack is a zip file of this
/// and its stickers' pictures, flat, nothing in folders (see
/// `docs/protocol.md`).
class StickerPackManifest {
  const StickerPackManifest({
    required this.id,
    required this.title,
    this.author,
    required this.cover,
    this.version,
    required this.stickers,
  });

  /// What a sticker pack's manifest says it is (`"type"`), unlike other
  /// packages a later version may take.
  static const type = 'sticker-pack';

  /// The newest format this version reads (`"format"`).
  static const format = 1;

  static const maxStickers = 100;

  /// The longest an emoji of a sticker can be, in UTF-16 code units.
  static const maxEmoji = 16;

  /// What a sticker's file can be called: in no folder, and a picture.
  static final filePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.(webp|png|gif)$');

  /// Names the pack: the same ID is the same pack, whoever made the file.
  final String id;
  final String title;
  final String? author;

  /// The ID of the sticker that stands for the pack.
  final String cover;

  /// The pack's own version, if it says.
  final int? version;

  final List<StickerPackItem> stickers;

  /// Throws a [FormatException] whose message can be shown to the user.
  factory StickerPackManifest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) throw const FormatException('This is not a sticker pack');
    final given = json['format'];
    if (given is! int || given < 1) throw const FormatException('This sticker pack is damaged');
    if (given > format) throw const FormatException('This sticker pack needs a newer version of Hanashi');
    final id = json['id'];
    if (id is! String || !StickerRef.idPattern.hasMatch(id)) {
      throw const FormatException('This sticker pack has no valid ID');
    }
    final title = _text(json['title']);
    if (title == null) throw const FormatException('This sticker pack has no title');
    final list = json['stickers'];
    if (list is! List || list.isEmpty) throw const FormatException('This sticker pack has no stickers');
    if (list.length > maxStickers) {
      throw const FormatException('This sticker pack has more than $maxStickers stickers');
    }
    final seen = <String>{};
    final stickers = <StickerPackItem>[];
    for (final entry in list) {
      if (entry is! Map) throw const FormatException('This sticker pack is damaged');
      final (sticker, file, emoji) = (entry['id'], entry['file'], entry['emoji']);
      if (sticker is! String || !StickerRef.idPattern.hasMatch(sticker)) {
        throw const FormatException('A sticker in this pack has no valid ID');
      }
      // Apart in case too: some file systems would not tell them apart.
      if (!seen.add(sticker.toLowerCase())) throw FormatException('This sticker pack has "$sticker" twice');
      if (file is! String || !filePattern.hasMatch(file)) {
        throw FormatException('Sticker "$sticker" of this pack has no valid file');
      }
      stickers.add(
        StickerPackItem(
          id: sticker,
          file: file,
          emoji: emoji is String && emoji.isNotEmpty && emoji.length <= maxEmoji ? emoji : null,
        ),
      );
    }
    final (cover, version) = (json['cover'], json['version']);
    return StickerPackManifest(
      id: id,
      title: title,
      author: _text(json['author']),
      cover: cover is String && stickers.any((s) => s.id == cover) ? cover : stickers.first.id,
      version: version is int && version >= 0 ? version : null,
      stickers: stickers,
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty || text.length > StickerSource.maxTitle ? null : text;
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'type': type,
    'id': id,
    'title': title,
    'author': ?author,
    'cover': cover,
    'version': ?version,
    'stickers': [for (final sticker in stickers) sticker.toJson()],
  };
}

/// A sticker pack a user keeps, as their account data lists it: the pack's
/// ID and title, and its file, encrypted and uploaded to their own server.
class PackEntry {
  const PackEntry({required this.id, required this.title, required this.archive});

  final String id;
  final String title;
  final MediaRef archive;

  /// Null for one this version cannot read.
  static PackEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    final (id, title, archive) = (json['id'], json['title'], json['archive']);
    if (id is! String || !StickerRef.idPattern.hasMatch(id) || title is! String || archive is! Map) return null;
    try {
      return PackEntry(id: id, title: title, archive: MediaRef.fromJson(archive.cast<String, Object?>()));
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'archive': archive.toJson()};
}

/// The user keeps as many sticker packs as they can.
class TooManyStickerPacks implements Exception {
  const TooManyStickerPacks();

  @override
  String toString() => 'You have the most sticker packs you can keep (${PackList.maxPacks}): remove one first';
}

/// The sticker packs a user keeps, newest first, the same on all of their
/// devices: their account data `packs`, `{"packs": [PackEntry...]}`.
/// Whatever this version does not know (other keys, entries
/// it cannot read, fields of those it can) is kept as it came, so changing
/// the list here never drops what a later version added.
class PackList {
  PackList._(this._json, this._packs);

  factory PackList.fromJson(Map<String, Object?>? json) {
    final packs = json?['packs'];
    return PackList._({...?json}, [if (packs is List) ...packs]);
  }

  static final empty = PackList.fromJson(null);

  /// The most packs a user keeps.
  static const maxPacks = 100;

  final Map<String, Object?> _json;
  final List<Object?> _packs;

  /// The packs this version reads: the first of each ID.
  late final List<PackEntry> entries = () {
    final seen = <String>{};
    return [
      for (final raw in _packs)
        if (PackEntry.tryParse(raw) case final entry? when seen.add(entry.id)) entry,
    ];
  }();

  PackEntry? operator [](String id) => entries.where((e) => e.id == id).firstOrNull;

  static String? _idOf(Object? raw) => raw is Map && raw['id'] is String ? raw['id'] as String : null;

  /// With [entry]: in the place of the pack of its ID, or else first. Throws
  /// [TooManyStickerPacks] for one more than [maxPacks].
  PackList withAdded(PackEntry entry) {
    int? at;
    final packs = <Object?>[];
    for (final raw in _packs) {
      if (_idOf(raw) == entry.id) {
        at ??= packs.length;
      } else {
        packs.add(raw);
      }
    }
    if (at == null && entries.length >= maxPacks) throw const TooManyStickerPacks();
    packs.insert(at ?? 0, entry.toJson());
    return PackList._({..._json, 'packs': packs}, packs);
  }

  /// Without the pack [id].
  PackList withRemoved(String id) {
    final packs = [
      for (final raw in _packs)
        if (_idOf(raw) != id) raw,
    ];
    return PackList._({..._json, 'packs': packs}, packs);
  }

  Map<String, Object?> toJson() => {..._json, 'packs': _packs};
}
