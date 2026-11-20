import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/attachments.dart';
import '../../data/packs/content_package.dart';
import '../../data/packs/sticker_pack.dart';
import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../chat/expression_panel.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/picked_file.dart';
import 'sticker_image.dart';

/// The expression panel's sticker tab.
final stickerTab = ExpressionTab(
  id: 'sticker',
  icon: Icons.sticky_note_2_outlined,
  label: 'Stickers',
  build: (context, target, height) => StickerPicker(height: height, onSticker: target.onSticker!),
);

/// Keeps [sticker] among the user's stickers or, with [saved] false, lets it
/// go, and says so.
Future<void> setStickerSaved(BuildContext context, WidgetRef ref, StickerRef sticker, bool saved) async {
  final messenger = ScaffoldMessenger.of(context);
  final repository = ref.read(chatRepositoryProvider);
  try {
    await repository.setStickerSaved(sticker, saved);
    // The latest says what is so now, at once.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(saved ? 'Added to your stickers' : 'Removed from your stickers'),
          action: saved
              ? null
              : SnackBarAction(label: 'Undo', onPressed: () => unawaited(repository.setStickerSaved(sticker, true))),
        ),
      );
  } on ApiException catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not change your stickers: $e')));
  }
}

/// A sticker pack file the user picks; null if they picked none.
Future<String?> pickStickerPackFile() async {
  final file = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['zip'])).firstOrNull;
  return file == null ? null : localPathOf(file);
}

/// The user's own stickers, with a way to make one from an image, then each
/// pack they keep, under its title, and a way to add a pack from its file.
/// Tapping a sticker sends it; a long press or right click keeps it among
/// the user's, or lets a kept one go.
class StickerPicker extends ConsumerStatefulWidget {
  const StickerPicker({
    super.key,
    required this.height,
    required this.onSticker,
    this.pickImage = pickPicture,
    this.pickPackFile = pickStickerPackFile,
  });

  final double height;
  final ValueChanged<StickerRef> onSticker;

  /// An image to make a sticker of; null if the user picked none.
  final Future<String?> Function() pickImage;

  /// A sticker pack file to add; null if the user picked none.
  final Future<String?> Function() pickPackFile;

  @override
  ConsumerState<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends ConsumerState<StickerPicker> {
  /// The largest a sticker shows here.
  static const _cell = 96.0;

  var _making = false;
  var _importing = false;

  Future<void> _make() async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await widget.pickImage();
    if (path == null || !mounted) return;
    setState(() => _making = true);
    try {
      await ref.read(chatRepositoryProvider).makeSticker(path);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Added to your stickers')));
    } on AttachmentException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } on ApiException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not make the sticker: $e')));
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await widget.pickPackFile();
    if (path == null || !mounted) return;
    setState(() => _importing = true);
    try {
      final repository = ref.read(chatRepositoryProvider);
      StickerPack pack;
      try {
        pack = await repository.importStickerPack(path);
      } on StickerPackInstalled catch (e) {
        // Not busy while asking.
        setState(() => _importing = false);
        if (!mounted || !await _confirmReplace(e.title) || !mounted) return;
        setState(() => _importing = true);
        pack = await repository.importStickerPack(path, replace: true);
      }
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
    } on FileSystemException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not read the file: ${e.message}')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<bool> _confirmReplace(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const Key('replace-sticker-pack'),
          title: Text('Replace "$title"?'),
          content: const Text(
            'This file is a version of a sticker pack you have. Stickers sent from it stay as they are.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Replace')),
          ],
        ),
      ) ??
      false;

  Future<void> _remove(StickerPack pack) async {
    final messenger = ScaffoldMessenger.of(context);
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('remove-sticker-pack'),
        title: Text('Remove "${pack.title}"?'),
        content: const Text('It goes from all of your devices. Stickers you kept from it stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.failed),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await ref.read(chatRepositoryProvider).removeStickerPack(pack.id);
    } on ApiException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not remove the sticker pack: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(savedStickersProvider).value ?? const <StickerRef>[];
    final packs = ref.watch(stickerPacksProvider).value ?? const <StickerPack>[];
    // Decoded no larger than shown: a few dozen at full size would take
    // more memory than the whole chat.
    final decodeWidth = (_cell * MediaQuery.devicePixelRatioOf(context)).round();

    Widget tile(StickerRef sticker, Key key) => _StickerTile(
      key: key,
      image: stickerImage(packs, sticker, decodeWidth: decodeWidth),
      onTap: () => widget.onSticker(sticker),
      onLongPress: () => setStickerSaved(context, ref, sticker, !saved.any((s) => s.key == sticker.key)),
    );
    Widget header(String title, {bool busy = false, Widget? menu}) => SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, menu == null ? 8 : 4, menu == null ? 12 : 2, menu == null ? 2 : 0),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.palette.textSecondary),
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    ),
                ],
              ),
            ),
            ?menu,
          ],
        ),
      ),
    );
    Widget grid(List<Widget> tiles) => SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      sliver: SliverGrid.list(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: _cell),
        children: tiles,
      ),
    );
    Widget note(String text, {Key? key}) => SliverToBoxAdapter(
      key: key,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Text(text, style: TextStyle(fontSize: 13, color: context.palette.textMuted)),
      ),
    );

    return SizedBox(
      key: const Key('sticker-picker'),
      height: widget.height,
      child: CustomScrollView(
        slivers: [
          header('My stickers'),
          grid([
            _MakeTile(making: _making, onTap: _making ? null : _make),
            for (final sticker in saved) tile(sticker, ValueKey('my-sticker-${sticker.key}')),
          ]),
          if (saved.isEmpty) note('Make one from an image, or long-press any sticker to keep it here.'),
          for (final pack in packs) ...[
            header(
              pack.title,
              busy: pack.state == StickerPackState.fetching,
              menu: pack.archive == null ? null : _PackMenu(pack: pack, onRemove: () => _remove(pack)),
            ),
            switch (pack.state) {
              StickerPackState.ready => grid([
                for (final sticker in pack.stickers)
                  tile(StickerRef.named(pack: pack.id, id: sticker.id), ValueKey('sticker-${pack.id}-${sticker.id}')),
              ]),
              StickerPackState.fetching => note('Getting its stickers…'),
              StickerPackState.failed => note(
                "Couldn't get its stickers yet; they come the next time you connect.",
                key: ValueKey('sticker-pack-failed-${pack.id}'),
              ),
            },
          ],
          if (packs.isEmpty) note('Sticker packs come with stickers people send you: tap one to add its pack.'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('import-sticker-pack'),
                  onPressed: _importing ? null : _import,
                  icon: _importing
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.file_open_outlined),
                  label: const Text('Import pack file…'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What can be done with one of the user's packs.
class _PackMenu extends StatelessWidget {
  const _PackMenu({required this.pack, required this.onRemove});

  final StickerPack pack;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
    // No taller than the pack's title needs.
    width: 40,
    height: 28,
    child: PopupMenuButton<VoidCallback>(
      key: ValueKey('pack-menu-${pack.id}'),
      tooltip: 'Sticker pack',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_horiz, size: 20, color: context.palette.textMuted),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        PopupMenuItem(key: const Key('remove-sticker-pack-item'), value: onRemove, child: const Text('Remove pack…')),
      ],
    ),
  );
}

/// One sticker to pick: [image] its picture, or a sign that the pack it is
/// from is not the user's (any more).
class _StickerTile extends StatelessWidget {
  const _StickerTile({super.key, required this.image, required this.onTap, required this.onLongPress});

  final Widget? image;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    onLongPress: onLongPress,
    onSecondaryTap: onLongPress,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: image ?? Icon(Icons.sticky_note_2_outlined, color: context.palette.textMuted),
    ),
  );
}

/// Makes a sticker of an image the user picks.
class _MakeTile extends StatelessWidget {
  const _MakeTile({required this.making, required this.onTap});

  final bool making;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Material(
      color: context.palette.listBackground,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: const Key('make-sticker'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Tooltip(
          message: 'Make a sticker from an image',
          child: Center(
            child: making
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Icon(Icons.add_photo_alternate_outlined, color: context.palette.replyAccent, size: 30),
          ),
        ),
      ),
    ),
  );
}
