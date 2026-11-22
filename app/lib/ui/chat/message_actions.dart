import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../media/save_media.dart';
import '../stickers/sticker_picker.dart';
import '../theme/hanashi_theme.dart';
import 'expression_panel.dart';
import '../media/gif_view.dart';
import 'gif_picker.dart';

/// The quick reactions until the user has used others; any other emoji is
/// one tap further.
const defaultReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// The quick reactions: the user's recent ones, then the defaults.
List<String> quickReactions(List<String> recent) =>
    [...recent, ...defaultReactions.where((e) => !recent.contains(e))].take(defaultReactions.length).toList();

/// Adds the user's [emoji] to [message], or with [remove] takes it back. An
/// added one becomes the first quick reaction.
Future<void> reactTo(WidgetRef ref, ChatMessage message, String emoji, {bool remove = false}) async {
  if (!remove) ref.read(recentReactionsProvider.notifier).use(emoji);
  await ref.read(chatRepositoryProvider).react(message.id, emoji, remove: remove);
}

/// The emoji [me] reacted to [message] with.
Set<String> myReactions(ChatMessage message, String me) => {
  for (final MapEntry(key: emoji, value: users) in message.reactions.entries)
    if (users.contains(me)) emoji,
};

enum _Action {
  reply('Reply', Icons.reply),
  copy('Copy text', Icons.copy),
  copyLink('Copy link', Icons.link),
  download('Download', Icons.download),
  saveGif('Save GIF', Icons.bookmark_add_outlined),
  unsaveGif('Remove from saved GIFs', Icons.bookmark_remove_outlined),
  saveSticker('Add to my stickers', Icons.bookmark_add_outlined),
  unsaveSticker('Remove from my stickers', Icons.bookmark_remove_outlined),
  edit('Edit', Icons.edit_outlined),
  delete('Delete for everyone', Icons.delete_outline);

  const _Action(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// One choice from the actions: a reaction, "more emoji", or an action.
class _Choice {
  const _Choice({this.emoji, this.more = false, this.action});

  final String? emoji;
  final bool more;
  final _Action? action;
}

/// Reacting to and acting on one message: a bottom sheet after a long press,
/// or a menu at the pointer ([at]) after a right click or from the hover
/// buttons. With [reactionsOnly], just the reactions.
Future<void> showMessageActions(
  BuildContext context,
  WidgetRef ref, {
  required ChatMessage message,
  required String me,
  required void Function(ChatMessage message) onReply,
  required void Function(ChatMessage message) onEdit,
  Offset? at,
  bool reactionsOnly = false,
}) async {
  final mine = message.senderId == me;
  final current = myReactions(message, me);
  final quick = quickReactions(ref.read(recentReactionsProvider));
  final gif = reactionsOnly || message.isDeleted ? null : gifOf(message.envelope);
  final savedGif = gif != null && (ref.read(savedGifsProvider).value ?? const []).any((g) => g.key == gif.key);
  final sticker = reactionsOnly || message.isDeleted ? null : message.envelope.sticker;
  final savedSticker =
      sticker != null && (ref.read(savedStickersProvider).value ?? const []).any((s) => s.key == sticker.key);
  // An uploaded file; not a GIF that KLIPY serves, which may not be kept.
  final media = reactionsOnly || message.isDeleted ? null : message.envelope.media;
  // The one with a preview, or else the first.
  final link = message.envelope.link?.url ?? findLinks(message.envelope.text ?? '').firstOrNull?.address;
  final actions = [
    if (!reactionsOnly) ...[
      _Action.reply,
      if ((message.envelope.text ?? '').isNotEmpty) _Action.copy,
      if (link != null) _Action.copyLink,
      if (media != null) _Action.download,
      if (gif != null) savedGif ? _Action.unsaveGif : _Action.saveGif,
      if (sticker != null) savedSticker ? _Action.unsaveSticker : _Action.saveSticker,
      if (mine && message.envelope.messageType == MessageType.text) _Action.edit,
      if (mine) _Action.delete,
    ],
  ];
  Widget icon(_Action a) =>
      Icon(a.icon, color: a == _Action.delete ? context.palette.failed : context.palette.textSecondary);
  Widget label(_Action a) =>
      Text(a.label, style: a == _Action.delete ? TextStyle(color: context.palette.failed) : null);

  final _Choice? choice;
  if (at == null) {
    // Over the whole window: in the two-pane layout the chat has its own
    // navigator, and the chat list must not stay clickable meanwhile.
    choice = await showModalBottomSheet<_Choice>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: _ReactionBar(emojis: quick, current: current, onChoice: (c) => Navigator.pop(context, c)),
            ),
            if (actions.isNotEmpty) const Divider(height: 1),
            for (final a in actions)
              ListTile(
                key: ValueKey('action-${a.name}'),
                leading: icon(a),
                title: label(a),
                onTap: () => Navigator.pop(context, _Choice(action: a)),
              ),
          ],
        ),
      ),
    );
  } else {
    final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject()! as RenderBox;
    choice = await showMenu<_Choice>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      // Wide enough for the reactions (menus are narrower by default).
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 360),
      items: [
        _ReactionEntry(emojis: quick, current: current),
        if (actions.isNotEmpty) const PopupMenuDivider(),
        for (final a in actions)
          PopupMenuItem(
            key: ValueKey('action-${a.name}'),
            value: _Choice(action: a),
            child: Row(children: [icon(a), const SizedBox(width: 12), label(a)]),
          ),
      ],
    );
  }
  if (choice == null || !context.mounted) return;
  final repository = ref.read(chatRepositoryProvider);
  switch (choice) {
    case _Choice(:final emoji?):
      // One of the user's own again takes it back.
      await reactTo(ref, message, emoji, remove: current.contains(emoji));
    case _Choice(more: true):
      final emoji = await pickEmoji(context);
      if (emoji != null) await reactTo(ref, message, emoji, remove: current.contains(emoji));
    case _Choice(action: _Action.reply):
      onReply(message);
    case _Choice(action: _Action.download):
      await saveMedia(context, ref, media!);
    case _Choice(action: _Action.saveGif || _Action.unsaveGif):
      await setGifSaved(context, ref, gif!, choice.action == _Action.saveGif);
    case _Choice(action: _Action.saveSticker || _Action.unsaveSticker):
      await setStickerSaved(context, ref, sticker!, choice.action == _Action.saveSticker);
    case _Choice(action: _Action.copy || _Action.copyLink):
      await Clipboard.setData(ClipboardData(text: choice.action == _Action.copy ? message.envelope.text! : link!));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
      }
    case _Choice(action: _Action.edit):
      onEdit(message);
    case _Choice(action: _Action.delete):
      if (await _confirmDelete(context)) await repository.deleteMessage(message.id);
    case _Choice():
      break;
  }
}

Future<bool> _confirmDelete(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete for everyone?'),
        content: const Text(
          'The message disappears from this chat on every device. People who already read it may remember it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: context.palette.failed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

/// Any emoji, from the full picker; null if the user closes it.
Future<String?> pickEmoji(BuildContext context) {
  Widget picker(BuildContext context) => EmojiPicker(
    key: const Key('emoji-picker'),
    onEmojiSelected: (_, emoji) => Navigator.pop(context, emoji.emoji),
    config: emojiPickerConfig(context.palette, height: 340),
  );
  if (MediaQuery.sizeOf(context).width >= 600) {
    return showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 400, child: picker(context)),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(child: picker(context)),
  );
}

/// The quick reactions and a button for any other emoji.
class _ReactionBar extends StatelessWidget {
  const _ReactionBar({required this.emojis, required this.current, required this.onChoice});

  final List<String> emojis;

  /// The user's reactions, highlighted.
  final Set<String> current;
  final ValueChanged<_Choice> onChoice;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final emoji in emojis)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              key: ValueKey('react-$emoji'),
              customBorder: const CircleBorder(),
              onTap: () => onChoice(_Choice(emoji: emoji)),
              child: Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: current.contains(emoji) ? context.palette.replyPanel : null,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 24, fontFamilyFallback: emojiOnlyFallback)),
              ),
            ),
          ),
        IconButton(
          key: const Key('react-more'),
          tooltip: 'More emoji',
          icon: Icon(Icons.add_reaction_outlined, color: context.palette.textSecondary),
          onPressed: () => onChoice(const _Choice(more: true)),
        ),
      ],
    );
  }
}

/// [_ReactionBar] as the first row of a popup menu.
class _ReactionEntry extends PopupMenuEntry<_Choice> {
  const _ReactionEntry({required this.emojis, required this.current});

  final List<String> emojis;
  final Set<String> current;

  @override
  double get height => 52;

  @override
  bool represents(_Choice? value) => false;

  @override
  State<_ReactionEntry> createState() => _ReactionEntryState();
}

class _ReactionEntryState extends State<_ReactionEntry> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: _ReactionBar(emojis: widget.emojis, current: widget.current, onChoice: (c) => Navigator.pop(context, c)),
  );
}
