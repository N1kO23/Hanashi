import 'package:hanashi_protocol/hanashi_protocol.dart';

/// How far a pack the user keeps is on this device.
enum StickerPackState {
  /// Its stickers are here.
  ready,

  /// Being fetched.
  fetching,

  /// Fetching it failed; it is tried again on the next connect.
  failed,
}

/// A sticker of a pack, as this device shows it.
class PackSticker {
  const PackSticker({required this.id, this.path, this.mime, this.width, this.height, this.emoji});

  final String id;

  /// Its picture on this device.
  final String? path;

  final String? mime;
  final int? width;
  final int? height;

  /// An emoji it goes with, if its pack says.
  final String? emoji;
}

/// A sticker pack the user keeps, as the picker shows it.
class StickerPack {
  const StickerPack({
    required this.id,
    required this.title,
    this.author,
    this.archive,
    this.state = StickerPackState.ready,
    this.stickers = const [],
  });

  final String id;
  final String title;
  final String? author;

  /// Its file on the user's server.
  final MediaRef? archive;

  final StickerPackState state;

  /// Empty until it is ready.
  final List<PackSticker> stickers;

  PackSticker? operator [](String sticker) => stickers.where((s) => s.id == sticker).firstOrNull;

  /// Where a sticker sent from this pack says it comes from.
  StickerSource sourceFor(String sticker) => StickerSource(pack: id, id: sticker, title: title, archive: archive);
}

/// The user has a sticker pack of the same ID already: [title].
class StickerPackInstalled implements Exception {
  const StickerPackInstalled(this.title);

  final String title;

  @override
  String toString() => 'You have "$title" already';
}

/// A sticker of a pack the user does not have (any more).
class StickerPackMissing implements Exception {
  const StickerPackMissing();

  @override
  String toString() => 'That sticker pack is not on this device yet';
}
