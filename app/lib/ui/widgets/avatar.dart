import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';

/// A user's or group's picture, or until there is one a coloured circle with
/// initials, derived from the ID so the same user always gets the same colour
/// on every device.
class Avatar extends ConsumerWidget {
  const Avatar({super.key, required this.id, required this.label, this.picture, this.size = 44});

  final String id;
  final String label;

  /// A group's picture; a user's comes from their profile.
  final MediaRef? picture;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picture = this.picture ?? ref.watch(profilesProvider.select((p) => p.value?[id]?.avatar));
    final bytes = picture == null ? null : ref.watch(mediaBytesProvider(mediaKey(picture))).value;
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
    final colors = context.palette.avatarColors;
    final color = colors[_stableHash(id) % colors.length];
    final initial = label.trim().isEmpty ? '?' : label.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(color: context.palette.onAccent, fontWeight: FontWeight.bold, fontSize: size * 0.42),
      ),
    );
  }

  /// FNV-1a; `String.hashCode` is not stable across runs or platforms.
  static int _stableHash(String s) {
    var hash = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}

/// One image for a picture, from the gallery (phones) or a file dialog
/// (desktop); null if the user picked none.
Future<String?> pickPicture() async {
  if (Platform.isAndroid || Platform.isIOS) return (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;
  return (await FilePicker.pickFiles(type: FileType.image)).firstOrNull?.path;
}
