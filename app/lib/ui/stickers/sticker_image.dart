import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/packs/sticker_pack.dart';
import '../../data/packs/sticker_pack_store.dart';
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
    // The demo's are plain files.
    if (item!.key == null) {
      return Image.file(File(path), fit: BoxFit.contain, cacheWidth: decodeWidth, gaplessPlayback: true);
    }
    return _PackPicture(item, decodeWidth: decodeWidth);
  }
  return null;
}

/// A picture of a pack kept on this device, decrypted into memory (see
/// [packPicture]); nothing until it is.
class _PackPicture extends StatefulWidget {
  const _PackPicture(this.sticker, {required this.decodeWidth});

  final PackSticker sticker;
  final int decodeWidth;

  @override
  State<_PackPicture> createState() => _PackPictureState();
}

class _PackPictureState extends State<_PackPicture> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PackPicture old) {
    super.didUpdateWidget(old);
    if (old.sticker.path != widget.sticker.path) _load();
  }

  void _load() {
    final sticker = widget.sticker;
    // Decrypted lately: at once, without a frame of nothing.
    _bytes = packPictureNow(sticker);
    if (_bytes != null) return;
    packPicture(sticker).then(
      (bytes) {
        if (mounted && widget.sticker.path == sticker.path) setState(() => _bytes = bytes);
      },
      onError: (Object _) {}, // Damaged: it shows nothing, and is fetched again.
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const SizedBox();
    return Image.memory(bytes, fit: BoxFit.contain, cacheWidth: widget.decodeWidth, gaplessPlayback: true);
  }
}
