import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/attachments.dart';
import '../../data/custom_emojis.dart';
import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../chat/expression_panel.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import 'custom_emoji_image.dart';

/// The expression panel's tab of custom emojis.
final customEmojiTab = ExpressionTab(
  id: 'custom',
  icon: Icons.face_retouching_natural_outlined,
  label: 'Custom emojis',
  build: (context, target, height) => CustomEmojiPicker(
    height: height,
    conversationId: target.conversationId,
    onEmoji: (name) => insertAtCursor(target.text, ':$name:'),
  ),
);

/// Writes [text] where the cursor is in [controller], over anything selected.
void insertAtCursor(TextEditingController controller, String text) {
  final value = controller.value;
  final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
  controller.value = TextEditingValue(
    text: selection.textBefore(value.text) + text + selection.textAfter(value.text),
    selection: TextSelection.collapsed(offset: selection.start + text.length),
  );
}

/// [text] as much of an emoji's name as it can be: lower case, `_` between
/// words, at most 32 characters.
String toEmojiName(String text) {
  final name = text
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9_]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return name.length > 32 ? name.substring(0, 32) : name;
}

/// A name for an emoji made from the file at [path]: its file name, as far
/// as a name can be that.
String emojiNameFromFile(String path) {
  final file = path.split(RegExp(r'[/\\]')).last;
  final dot = file.lastIndexOf('.');
  final name = toEmojiName(dot > 0 ? file.substring(0, dot) : file);
  return name.length >= 2 ? name : 'emoji';
}

/// [name], or if it is [taken], the first of `name_2`, `name_3`, ... that is not.
String freeEmojiName(String name, Set<String> taken) {
  if (!taken.contains(name)) return name;
  for (var i = 2; ; i++) {
    final suffix = '_$i';
    final free = '${name.length + suffix.length > 32 ? name.substring(0, 32 - suffix.length) : name}$suffix';
    if (!taken.contains(free)) return free;
  }
}

/// Runs [change] to a set of custom emojis, then says [done] (with [undo]),
/// or what went wrong.
Future<void> _changeSaying(
  ScaffoldMessengerState messenger,
  Future<void> Function() change, {
  required String done,
  SnackBarAction? undo,
}) async {
  String? failed;
  try {
    await change();
  } on TooManyEmojis catch (e) {
    failed = '$e';
  } on AttachmentException catch (e) {
    failed = e.message;
  } on StateError catch (e) {
    failed = e.message;
  } on ApiException catch (e) {
    failed = 'Could not change the emojis: $e';
  }
  // The latest says what is so now, at once.
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(failed ?? done), action: failed == null ? undo : null));
}

/// Adds [picture] (one of a group's emojis, or one from a message) to the
/// user's own, under a name they choose: [name], if they have no other.
Future<void> keepEmoji(BuildContext context, WidgetRef ref, String name, MediaRef picture) async {
  final messenger = ScaffoldMessenger.of(context);
  final repository = ref.read(chatRepositoryProvider);
  final taken = (ref.read(myEmojisProvider).value ?? const {}).keys.toSet();
  final chosen = await askEmojiName(
    context,
    title: 'Add to my emojis',
    picture: CustomEmojiImage(name: name, picture: picture, size: 64),
    suggested: freeEmojiName(name, taken),
    taken: taken,
  );
  if (chosen == null) return;
  await _changeSaying(
    messenger,
    () => repository.changeEmojis((current) => {...current, chosen: picture}),
    done: 'Added :$chosen: to your emojis',
  );
}

/// Shows a custom emoji from a message larger, with a way to add it to the
/// user's own.
Future<void> showCustomEmoji(BuildContext context, WidgetRef ref, String name, MediaRef picture) => showDialog<void>(
  context: context,
  builder: (dialog) => Consumer(
    builder: (dialog, watching, _) {
      final mine = watching.watch(myEmojisProvider).value ?? const {};
      final kept = mine.values.any((p) => p.hash == picture.hash);
      return AlertDialog(
        key: const Key('custom-emoji-info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomEmojiImage(name: name, picture: picture, size: 96),
            const SizedBox(height: 12),
            Text(':$name:', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (kept) ...[
              const SizedBox(height: 4),
              Text('In your emojis', style: TextStyle(fontSize: 13, color: context.palette.textMuted)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close')),
          if (!kept)
            FilledButton(
              key: const Key('keep-emoji'),
              onPressed: () {
                Navigator.pop(dialog);
                unawaited(keepEmoji(context, ref, name, picture));
              },
              child: const Text('Add to my emojis'),
            ),
        ],
      );
    },
  ),
);

/// Asks for a custom emoji's name, showing its [picture]: one not [taken] in
/// its set. Null if the user gave none.
Future<String?> askEmojiName(
  BuildContext context, {
  required String title,
  required Widget picture,
  required Set<String> taken,
  String suggested = '',
  String action = 'Add',
}) => showDialog<String>(
  context: context,
  builder: (_) => _EmojiNameDialog(title: title, picture: picture, taken: taken, suggested: suggested, action: action),
);

class _EmojiNameDialog extends StatefulWidget {
  const _EmojiNameDialog({
    required this.title,
    required this.picture,
    required this.taken,
    required this.suggested,
    required this.action,
  });

  final String title;
  final Widget picture;
  final Set<String> taken;
  final String suggested;
  final String action;

  @override
  State<_EmojiNameDialog> createState() => _EmojiNameDialogState();
}

class _EmojiNameDialogState extends State<_EmojiNameDialog> {
  late final _controller = TextEditingController(text: widget.suggested)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.suggested.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// What is wrong with the name, if anything but its being empty.
  String? get _problem {
    final name = _controller.text;
    if (name.isEmpty) return null;
    if (name.length < 2) return 'At least 2 characters';
    if (!CustomEmoji.namePattern.hasMatch(name)) return 'Only a to z, 0 to 9 and _';
    if (widget.taken.contains(name)) return 'There is already a :$name:';
    return null;
  }

  bool get _valid => _controller.text.isNotEmpty && _problem == null;

  void _save() {
    if (_valid) Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 64, child: widget.picture),
        const SizedBox(height: 16),
        TextField(
          key: const Key('emoji-name'),
          controller: _controller,
          autofocus: true,
          inputFormatters: [_EmojiNameFormatter(), LengthLimitingTextInputFormatter(32)],
          decoration: InputDecoration(
            labelText: 'Name',
            prefixText: ':',
            suffixText: ':',
            errorText: _problem,
            helperText: 'Write :name: to use it',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(key: const Key('emoji-name-save'), onPressed: _valid ? _save : null, child: Text(widget.action)),
    ],
  );
}

/// Lower case, `_` for spaces and dashes, and nothing else a name cannot have.
class _EmojiNameFormatter extends TextInputFormatter {
  static String _clean(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s-]'), '_').replaceAll(RegExp('[^a-z0-9_]'), '');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = _clean(newValue.text);
    if (text == newValue.text) return newValue;
    final end = newValue.selection.end.clamp(0, newValue.text.length);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: _clean(newValue.text.substring(0, end)).length),
    );
  }
}

enum _EmojiAction { keep, rename, remove }

/// Custom emojis to write: a group's first, in a group, then the user's
/// own, each set with a way to make one from an image. Tapping one writes
/// `:name:`; a long press or right click renames it or removes it, or adds
/// one of a group's to the user's own.
class CustomEmojiPicker extends ConsumerStatefulWidget {
  const CustomEmojiPicker({
    super.key,
    required this.height,
    required this.onEmoji,
    this.conversationId,
    this.pickImage = pickPicture,
  });

  final double height;
  final ValueChanged<String> onEmoji;

  /// The chat being written in: a group's emojis show too.
  final String? conversationId;

  /// An image to make an emoji of; null if the user picked none.
  final Future<String?> Function() pickImage;

  @override
  ConsumerState<CustomEmojiPicker> createState() => _CustomEmojiPickerState();
}

class _CustomEmojiPickerState extends ConsumerState<CustomEmojiPicker> {
  static const _cell = 52.0;

  /// The sets one is being added to: null for the user's own, or a group.
  final _adding = <String?>{};

  Future<void> _add(String? conversationId, String title, Map<String, MediaRef> set) async {
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(chatRepositoryProvider);
    final path = await widget.pickImage();
    if (path == null || !mounted) return;
    final taken = set.keys.toSet();
    final name = await askEmojiName(
      context,
      title: title,
      picture: Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: context.palette.textMuted),
      ),
      suggested: freeEmojiName(emojiNameFromFile(path), taken),
      taken: taken,
    );
    if (name == null || !mounted) return;
    setState(() => _adding.add(conversationId));
    try {
      await _changeSaying(messenger, () async {
        final picture = await repository.uploadEmoji(path);
        await repository.changeEmojis((current) => {...current, name: picture}, conversationId: conversationId);
      }, done: 'Added :$name:');
    } finally {
      if (mounted) setState(() => _adding.remove(conversationId));
    }
  }

  Future<void> _menu(
    Offset at,
    String name,
    MediaRef picture,
    String? conversationId,
    Map<String, MediaRef> set,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(chatRepositoryProvider);
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_EmojiAction>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      items: [
        if (conversationId != null)
          const PopupMenuItem(key: Key('emoji-action-keep'), value: _EmojiAction.keep, child: Text('Add to my emojis')),
        const PopupMenuItem(key: Key('emoji-action-rename'), value: _EmojiAction.rename, child: Text('Rename')),
        const PopupMenuItem(key: Key('emoji-action-remove'), value: _EmojiAction.remove, child: Text('Remove')),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case null:
        return;
      case _EmojiAction.keep:
        await keepEmoji(context, ref, name, picture);
      case _EmojiAction.rename:
        final renamed = await askEmojiName(
          context,
          title: 'Rename :$name:',
          picture: CustomEmojiImage(name: name, picture: picture, size: 64),
          suggested: name,
          taken: set.keys.toSet()..remove(name),
          action: 'Rename',
        );
        if (renamed == null || renamed == name) return;
        await _changeSaying(
          messenger,
          () => repository.changeEmojis(
            (current) => {for (final MapEntry(:key, :value) in current.entries) (key == name ? renamed : key): value},
            conversationId: conversationId,
          ),
          done: 'Renamed :$name: to :$renamed:',
        );
      case _EmojiAction.remove:
        await _changeSaying(
          messenger,
          () => repository.changeEmojis((current) => {...current}..remove(name), conversationId: conversationId),
          done: 'Removed :$name:',
          undo: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(
              repository
                  .changeEmojis((current) => {...current, name: picture}, conversationId: conversationId)
                  .catchError((Object _) {}),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversationId;
    final summary = conv == null ? null : ref.watch(conversationProvider(conv));
    final group = summary == null || summary.conversation.isDirect ? null : summary;
    final mine = ref.watch(myEmojisProvider).value ?? const <String, MediaRef>{};
    final theirs = group == null
        ? const <String, MediaRef>{}
        : ref.watch(groupEmojisProvider(group.id)).value ?? const <String, MediaRef>{};

    Widget header(String title) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.palette.textSecondary),
        ),
      ),
    );
    Widget hint(String text) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Text(text, style: TextStyle(fontSize: 13, color: context.palette.textMuted)),
      ),
    );
    Widget grid(String? conversationId, String title, Map<String, MediaRef> set, String keyPrefix) => SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      sliver: SliverGrid.list(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: _cell),
        children: [
          _AddTile(
            key: Key('add-$keyPrefix'),
            adding: _adding.contains(conversationId),
            full: set.length >= CustomEmoji.maxPerSet,
            onTap: () => _add(conversationId, title, set),
          ),
          for (final name in set.keys.toList()..sort())
            _EmojiTile(
              key: ValueKey('$keyPrefix-$name'),
              name: name,
              picture: set[name]!,
              // Here, :name: is the group's own.
              shadowedBy: conversationId == null && theirs.containsKey(name) ? group?.title : null,
              onTap: () => widget.onEmoji(name),
              onMenu: (at) => _menu(at, name, set[name]!, conversationId, set),
            ),
        ],
      ),
    );

    return SizedBox(
      key: const Key('custom-emoji-picker'),
      height: widget.height,
      child: CustomScrollView(
        slivers: [
          if (group != null) ...[
            header(group.title),
            grid(group.id, 'Add to ${group.title}', theirs, 'group-emoji'),
            if (theirs.isEmpty) hint('Emojis everyone in ${group.title} can use. Anyone in it can add one.'),
          ],
          header('My emojis'),
          grid(null, 'Add to my emojis', mine, 'my-emoji'),
          if (mine.isEmpty) hint('Make one from an image, then write :its_name: in any chat.'),
        ],
      ),
    );
  }
}

class _EmojiTile extends StatelessWidget {
  const _EmojiTile({
    super.key,
    required this.name,
    required this.picture,
    required this.shadowedBy,
    required this.onTap,
    required this.onMenu,
  });

  final String name;
  final MediaRef picture;

  /// The group whose own emoji of this name `:name:` is in this chat, if one is.
  final String? shadowedBy;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final shadowedBy = this.shadowedBy;
    return Tooltip(
      message: shadowedBy == null ? ':$name:' : ':$name: (here, it is $shadowedBy\'s own)',
      // On a mouse only: a long press opens the menu.
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPressStart: (details) => onMenu(details.globalPosition),
        onSecondaryTapUp: (details) => onMenu(details.globalPosition),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // Writing it would bring the group's.
          onTap: shadowedBy == null
              ? onTap
              : () => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(content: Text("Here :$name: is $shadowedBy's own. Rename yours to use it here.")),
                  ),
          child: Opacity(
            opacity: shadowedBy == null ? 1 : 0.4,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: CustomEmojiImage(name: name, picture: picture, size: 36),
            ),
          ),
        ),
      ),
    );
  }
}

/// Makes an emoji of an image the user picks.
class _AddTile extends StatelessWidget {
  const _AddTile({super.key, required this.adding, required this.full, required this.onTap});

  final bool adding;
  final bool full;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Material(
      color: context.palette.listBackground,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: adding || full ? null : onTap,
        child: Tooltip(
          message: full ? 'At most ${CustomEmoji.maxPerSet} emojis' : 'Make an emoji from an image',
          child: Center(
            child: adding
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Icon(
                    Icons.add_photo_alternate_outlined,
                    color: full ? context.palette.textMuted : context.palette.replyAccent,
                    size: 24,
                  ),
          ),
        ),
      ),
    ),
  );
}
