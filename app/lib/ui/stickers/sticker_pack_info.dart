import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/packs/content_package.dart';
import '../../data/packs/sticker_pack.dart';
import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import 'sticker_image.dart';

/// Shows a sticker from a message larger, with the pack it comes from: one
/// of the user's, or one they can add, if the sticker came with its pack.
Future<void> showStickerPackInfo(BuildContext context, StickerRef sticker) => showDialog<void>(
  context: context,
  builder: (dialog) => Consumer(
    builder: (dialog, ref, _) {
      final packs = ref.watch(stickerPacksProvider).value ?? const <StickerPack>[];
      final pack = packOf(packs, sticker);
      final source = sticker.source;
      final title = pack?.title ?? source?.title;
      final canAdd = pack == null && source?.archive != null;
      final image = stickerImage(packs, sticker, decodeWidth: (96 * MediaQuery.devicePixelRatioOf(dialog)).round());
      return AlertDialog(
        key: const Key('sticker-pack-info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 96,
              child: image ?? Icon(Icons.sticky_note_2_outlined, size: 48, color: context.palette.textMuted),
            ),
            const SizedBox(height: 12),
            Text(
              title == null ? 'From a sticker pack' : 'From $title',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              pack != null
                  ? 'In your sticker packs'
                  : canAdd
                  ? 'Add its pack to send its stickers too.'
                  : "Its pack didn't come with it.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.palette.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close')),
          if (canAdd) _AddPackButton(source: source!),
        ],
      );
    },
  ),
);

/// Adds [source]'s pack; the dialog then says it is the user's.
class _AddPackButton extends ConsumerStatefulWidget {
  const _AddPackButton({required this.source});

  final StickerSource source;

  @override
  ConsumerState<_AddPackButton> createState() => _AddPackButtonState();
}

class _AddPackButtonState extends ConsumerState<_AddPackButton> {
  var _adding = false;

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding = true);
    try {
      final pack = await ref.read(chatRepositoryProvider).addStickerPack(widget.source);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Added ${pack.title} to your sticker packs')));
    } on PackageException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } on TooManyStickerPacks catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$e')));
    } on ApiException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not add the sticker pack: $e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton(
    key: const Key('add-sticker-pack'),
    onPressed: _adding ? null : _add,
    child: _adding
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: context.palette.onAccent),
          )
        : const Text('Add pack'),
  );
}
