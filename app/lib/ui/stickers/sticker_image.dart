import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/packs/sticker_pack.dart';
import '../media/gif_view.dart';

/// The user's pack [sticker] is from, if they have one of its ID.
StickerPack? packOf(List<StickerPack> packs, StickerRef sticker) {
  final named = sticker.packSticker;
  return named == null ? null : packs.where((p) => p.id == named.pack).firstOrNull;
}

/// A sticker's picture, decoded no larger than [decodeWidth] pixels across:
/// its own, for one sent as its picture (whatever packs the user has); else
/// the file of the pack it names, on this device. Null for one named from a
/// pack the user does not have.
Widget? stickerImage(List<StickerPack> packs, StickerRef sticker, {required int decodeWidth}) {
  if (sticker.media case final media?) {
    return UploadedImage(media: media, fit: BoxFit.contain, placeholder: const SizedBox(), cacheWidth: decodeWidth);
  }
  final item = packOf(packs, sticker)?[sticker.id!];
  if (item?.path case final path?) {
    return Image.file(File(path), fit: BoxFit.contain, cacheWidth: decodeWidth, gaplessPlayback: true);
  }
  return null;
}
