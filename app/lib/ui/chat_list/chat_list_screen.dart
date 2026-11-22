import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../chat/chat_menu.dart';
import '../chat/chat_screen.dart';
import '../home/home_shell.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/presence.dart';
import '../widgets/emoji_text.dart';
import '../widgets/format.dart';
import '../widgets/list_header.dart';
import '../widgets/unread_badge.dart';

/// The "Chats" tab: conversation list, plus the open chat beside it on wide
/// layouts.
class ChatsPane extends StatelessWidget {
  const ChatsPane({super.key, this.selectedId});

  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    final selected = selectedId;
    if (!isWideLayout(context)) {
      return selected == null ? const ChatList() : ChatView(conversationId: selected, fullScreen: true);
    }
    return Row(
      children: [
        SizedBox(width: 340, child: ChatList(selectedId: selected)),
        VerticalDivider(width: 1, color: context.palette.panelDivider),
        Expanded(
          child: selected == null
              ? const _NoChatSelected()
              : ChatView(key: ValueKey(selected), conversationId: selected),
        ),
      ],
    );
  }
}

enum ChatSort {
  newest('Newest'),
  unread('Unread first'),
  name('Name');

  const ChatSort(this.label);

  final String label;
}

class ChatList extends ConsumerStatefulWidget {
  const ChatList({super.key, this.selectedId});

  final String? selectedId;

  @override
  ConsumerState<ChatList> createState() => _ChatListState();
}

class _ChatListState extends ConsumerState<ChatList> {
  var _sort = ChatSort.newest;

  /// The repository already orders by newest activity. A direct chat starts as
  /// soon as two people are contacts, but shows only once there is something in
  /// it, or while it is open.
  List<ConversationSummary> _sorted(List<ConversationSummary> all) {
    final list = [
      for (final c in all)
        if (c.conversation.isGroup || c.lastMessage != null || c.id == widget.selectedId) c,
    ];
    return switch (_sort) {
      ChatSort.newest => list,
      ChatSort.unread => [...list.where((c) => c.unreadCount > 0), ...list.where((c) => c.unreadCount == 0)],
      ChatSort.name => [...list]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
    };
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsProvider);
    final unread = ref.watch(totalUnreadProvider);
    final profiles = ref.watch(profilesProvider).value ?? const {};
    final me = ref.watch(chatRepositoryProvider).me;
    final now = ref.watch(clockProvider)();
    final settings = ref.watch(chatSettingsProvider).value ?? const {};

    return ColoredBox(
      color: context.palette.listBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListHeader(
            title: unread > 0 ? 'Unread Messages ($unread)' : 'Chats',
            trailing: ListSortMenu(
              value: _sort,
              options: ChatSort.values,
              labelOf: (s) => s.label,
              onSelected: (s) => setState(() => _sort = s),
            ),
          ),
          Expanded(
            child: conversations.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load chats: $e')),
              data: (list) {
                final sorted = _sorted(list);
                if (sorted.isEmpty) {
                  return Center(
                    child: Text('No chats yet.', style: TextStyle(color: context.palette.textSecondary)),
                  );
                }
                return ListView.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, _) => const Divider(indent: 16, endIndent: 16),
                  itemBuilder: (context, i) => ConversationTile(
                    summary: sorted[i],
                    selected: sorted[i].id == widget.selectedId,
                    preview: _preview(sorted[i], me, profiles),
                    now: now,
                    muted: settings[sorted[i].id]?.mutedAt(now) ?? false,
                    onTap: () => context.go('/chats/${sorted[i].id}'),
                    onMenu: (at) => showChatMenu(context, ref, conversationId: sorted[i].id, at: at),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The last message in one line; in groups with its sender's name.
  static String _preview(ConversationSummary s, String me, Map<String, UserProfile> profiles) {
    final last = s.lastMessage;
    if (last == null) return '';
    String nameOf(String id) => profiles[id]?.displayName ?? UserId.fallbackName(id, me: me);
    if (last.envelope.isGroupLine) {
      return describeGroupChange(last.envelope, me: me, nameOf: nameOf);
    }
    if (!s.conversation.isGroup) return last.envelope.preview;
    return '${last.senderId == me ? 'You' : nameOf(last.senderId)}: ${last.envelope.preview}';
  }
}

class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.summary,
    required this.onTap,
    this.onMenu,
    this.selected = false,
    this.preview,
    this.now,
    this.muted = false,
  });

  final ConversationSummary summary;
  final VoidCallback onTap;

  /// The chat's menu (see [showChatMenu]), after a long press or, at the
  /// pointer, a right click.
  final void Function(Offset? at)? onMenu;
  final bool selected;

  /// The preview line; the last message's own preview if not given.
  final String? preview;
  final DateTime? now;

  /// Shown with a crossed-out bell and a grey unread count.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final last = summary.lastMessage;
    final preview = this.preview ?? last?.envelope.preview ?? '';
    return Material(
      color: selected ? context.palette.listSelected : context.palette.listBackground,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu == null ? null : () => onMenu!(null),
        onSecondaryTapUp: onMenu == null ? null : (details) => onMenu!(details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              PresenceAvatar(id: summary.avatarId, label: summary.title, picture: summary.picture, size: 54),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: EmojiText(
                            summary.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 17,
                              color: context.palette.textPrimary,
                            ),
                          ),
                        ),
                        if (muted) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.notifications_off,
                            key: Key('chat-muted-icon'),
                            size: 15,
                            color: context.palette.textMuted,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    EmojiText(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // The custom emojis of a text message's text.
                      emojis: last?.envelope.messageType == MessageType.text ? last!.envelope.emojis : const {},
                      style: TextStyle(fontSize: 14, color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (last != null)
                    Text(
                      formatListTime(last.sentAt, now: now),
                      style: TextStyle(fontSize: 12, color: context.palette.textMuted),
                    ),
                  const SizedBox(height: 6),
                  if (summary.unreadCount > 0)
                    UnreadBadge(count: summary.unreadCount, muted: muted)
                  else
                    const SizedBox(height: 24),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoChatSelected extends StatelessWidget {
  const _NoChatSelected();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.palette.chatBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sms_outlined, size: 56, color: context.palette.divider),
            SizedBox(height: 12),
            Text('Select a chat to start messaging', style: TextStyle(color: context.palette.textSecondary)),
          ],
        ),
      ),
    );
  }
}
