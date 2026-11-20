import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../groups/group_info_dialog.dart';
import '../theme/hanashi_theme.dart';
import 'chat_settings_sheet.dart';

enum _ChatAction {
  markRead('Mark as read', Icons.mark_chat_read_outlined),
  mute('Mute notifications', Icons.notifications_off_outlined),
  unmute('Unmute notifications', Icons.notifications_active_outlined),
  settings('Chat settings', Icons.settings_outlined),
  groupInfo('Group info', Icons.group_outlined);

  const _ChatAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// What can be done with a whole chat: the quick things (marking it read,
/// muting it), its settings, and in a group its info. A bottom sheet after a
/// long press, or a menu at the pointer ([at]) after a right click or from
/// the title bar's button. More goes into [ChatSettingsDialog], in sections.
Future<void> showChatMenu(BuildContext context, WidgetRef ref, {required String conversationId, Offset? at}) async {
  final summary = ref.read(conversationProvider(conversationId));
  if (summary == null) return;
  final settings = ref.read(chatSettingsOfProvider(conversationId));
  final now = ref.read(clockProvider)();
  final actions = [
    if (summary.unreadCount > 0) _ChatAction.markRead,
    settings.mutedAt(now) ? _ChatAction.unmute : _ChatAction.mute,
    _ChatAction.settings,
    if (summary.conversation.isGroup) _ChatAction.groupInfo,
  ];
  final action = await _choose(
    context,
    at: at,
    options: [for (final a in actions) (key: 'chat-menu-${a.name}', label: a.label, icon: a.icon, value: a)],
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _ChatAction.markRead:
      await ref.read(chatRepositoryProvider).markRead(conversationId);
    case _ChatAction.mute:
      final duration = await _choose(
        context,
        at: at,
        options: [
          for (final (label, duration) in muteDurations)
            (key: muteKey(duration), label: label, icon: null, value: duration),
        ],
      );
      if (duration != null && context.mounted) {
        await saveChatSettings(context, ref, conversationId, mutedFor(settings, duration, now));
      }
    case _ChatAction.unmute:
      await saveChatSettings(context, ref, conversationId, unmuted(settings));
    case _ChatAction.settings:
      await showChatSettings(context, conversationId);
    case _ChatAction.groupInfo:
      await showGroupInfo(context, conversationId);
  }
}

/// One of [options], from a bottom sheet or, with [at], a menu there.
Future<T?> _choose<T extends Object>(
  BuildContext context, {
  required Offset? at,
  required List<({String key, String label, IconData? icon, T value})> options,
}) {
  Widget? icon(IconData? icon) => icon == null ? null : Icon(icon, color: context.palette.textSecondary);
  if (at == null) {
    // Over the whole window, as the message actions (see showMessageActions).
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              ListTile(
                key: ValueKey(o.key),
                leading: icon(o.icon),
                title: Text(o.label),
                onTap: () => Navigator.pop(context, o.value),
              ),
          ],
        ),
      ),
    );
  }
  final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    useRootNavigator: true,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
    items: [
      for (final o in options)
        PopupMenuItem(
          key: ValueKey(o.key),
          value: o.value,
          child: Row(
            children: [
              if (o.icon != null) ...[icon(o.icon)!, const SizedBox(width: 12)],
              Flexible(child: Text(o.label, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
    ],
  );
}

/// Saves [settings] for the chat, saying why if that fails.
Future<void> saveChatSettings(BuildContext context, WidgetRef ref, String conversationId, ChatSettings settings) async {
  try {
    await ref.read(chatRepositoryProvider).setChatSettings(conversationId, settings);
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}
