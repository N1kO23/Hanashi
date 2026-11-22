import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/attachments.dart';
import '../../data/models.dart';
import '../../data/packs/sticker_pack.dart';
import '../../data/remote/api_client.dart';
import '../../data/remote/link_previews.dart';
import '../../state/providers.dart';
import '../calls/call_stage.dart';
import '../calls/call_widgets.dart';
import '../emojis/custom_emoji_image.dart';
import '../encryption/verification_dialog.dart';
import '../groups/group_info_dialog.dart';
import '../profile/profile_card.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/format.dart';
import '../widgets/links.dart';
import '../widgets/picked_file.dart';
import '../widgets/presence.dart';
import '../window/window_caption.dart';
import '../../data/local/database.dart' show AppDatabase;
import 'chat_menu.dart';
import 'composer.dart';
import 'file_drop.dart';
import 'message_actions.dart';
import 'message_bubble.dart';

/// Messages of one conversation plus the composer. Used full-screen on phones
/// and as the right-hand panel on wide layouts.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.conversationId, this.fullScreen = false});

  final String conversationId;

  /// Phone layout: pink title bar with a back button.
  final bool fullScreen;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  static const _groupGap = Duration(minutes: 5);
  final _scroll = ScrollController();

  /// Replying to or editing a message.
  ComposerMode? _mode;

  /// Keys of the message rows, to find one on screen (see [_showMessage]).
  final _rowKeys = <String, GlobalKey>{};

  /// The message just jumped to, lit up for a moment.
  String? _highlighted;
  Timer? _unhighlight;

  @override
  void initState() {
    super.initState();
    _markRead();
    _loadOlder();
    // The list is reversed: its far end is the oldest message.
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        _loadOlder();
      }
    });
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _mode = null;
      _rowKeys.clear();
      _markRead();
      _loadOlder();
    }
  }

  @override
  void dispose() {
    _unhighlight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _reply(ChatMessage message, String Function(String) nameOf) => setState(
    () => _mode = ComposerMode.reply(
      messageId: message.id,
      title:
          'Replying to ${message.senderId == ref.read(chatRepositoryProvider).me ? 'yourself' : nameOf(message.senderId)}',
      preview: AppDatabase.quotePreview(message.envelope),
    ),
  );

  void _edit(ChatMessage message) =>
      setState(() => _mode = ComposerMode.edit(messageId: message.id, text: message.envelope.text ?? ''));

  void _send(String text, LinkPreviewDraft? link) {
    final repository = ref.read(chatRepositoryProvider);
    final mode = _mode;
    setState(() => _mode = null);
    if (mode != null && mode.isEdit) {
      if (text != mode.editText) repository.editMessage(mode.messageId, text);
    } else {
      repository.sendText(widget.conversationId, text, replyTo: mode?.messageId, link: link);
    }
  }

  void _sendGif(GifRef gif) {
    final mode = _mode;
    setState(() => _mode = null);
    ref.read(chatRepositoryProvider).sendGif(widget.conversationId, gif, replyTo: mode?.messageId);
  }

  Future<void> _sendSticker(StickerRef sticker) async {
    final mode = _mode;
    setState(() => _mode = null);
    try {
      await ref.read(chatRepositoryProvider).sendSticker(widget.conversationId, sticker, replyTo: mode?.messageId);
    } on StickerPackMissing catch (e) {
      _showError('$e');
    } on Exception catch (e) {
      _showError('Could not send the sticker: $e');
    }
  }

  /// Scrolls to [messageId] and lights it up: one screen at a time towards
  /// older messages until it is built.
  Future<void> _showMessage(String messageId, List<ChatMessage> messages) async {
    if (!messages.any((m) => m.id == messageId)) {
      _showError('The original message is not on this device.');
      return;
    }
    for (var i = 0; i < 50 && mounted; i++) {
      final row = _rowKeys[messageId]?.currentContext;
      if (row != null && row.mounted) {
        await Scrollable.ensureVisible(row, alignment: 0.5, duration: const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _highlighted = messageId);
        _unhighlight?.cancel();
        _unhighlight = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _highlighted = null);
        });
        return;
      }
      final position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) return;
      _scroll.jumpTo(min(position.pixels + position.viewportDimension * 0.8, position.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _loadOlder() => Future.microtask(() {
    if (mounted) {
      ref.read(chatRepositoryProvider).loadOlderMessages(widget.conversationId);
    }
  });

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<void> _attach() async {
    final source = await showModalBottomSheet<_AttachSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo or video'),
              onTap: () => Navigator.pop(context, _AttachSource.gallery),
            ),
            if (_isMobile) ...[
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, _AttachSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('Record a video'),
                onTap: () => Navigator.pop(context, _AttachSource.cameraVideo),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () => Navigator.pop(context, _AttachSource.file),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final List<LocalFile> picked;
    try {
      picked = await _pick(source);
    } catch (e) {
      _showError('Could not open the picker: $e');
      return;
    }
    await _sendFiles(picked);
  }

  /// Is asking whether to send dropped or pasted files.
  var _confirming = false;

  /// Files dropped onto the chat or pasted into it, sent once the user agrees.
  Future<void> _sendFromOtherApps(List<LocalFile> files) async {
    if (_confirming || files.isEmpty || !mounted) return;
    _confirming = true;
    try {
      final title = ref.read(conversationProvider(widget.conversationId))?.title ?? 'this chat';
      if (await confirmSendFiles(context, files, to: title)) await _sendFiles(files);
    } finally {
      _confirming = false;
    }
  }

  /// Files or an image on the clipboard; false when it has neither, so that
  /// the text is pasted.
  Future<bool> _paste() async {
    final temp = Directory('${Directory.systemTemp.path}/hanashi-pasted/${DateTime.now().microsecondsSinceEpoch}');
    try {
      final files = await clipboardFiles(temp);
      if (files == null) return false;
      await _sendFromOtherApps(files);
      return true;
    } on AttachmentException catch (e) {
      _showError(e.message);
      return true;
    } finally {
      // A pasted image is in the outbox's own copy by now.
      if (temp.existsSync()) await temp.delete(recursive: true);
    }
  }

  /// Downloads the file a link leads to and sends it like an attachment.
  Future<void> _sendLinkedFile(LinkPreviewDraft link) async {
    // The preview has it already.
    final media = link.media;
    if (media != null && File(media.path).existsSync()) {
      await _sendFiles([(path: media.path, name: link.title ?? 'file')]);
      return;
    }
    final limit = ref.read(chatRepositoryProvider).maxUploadBytes ?? _defaultUploadLimit;
    final messenger = ScaffoldMessenger.of(context);
    final temp = Directory('${Directory.systemTemp.path}/hanashi-linked/${DateTime.now().microsecondsSinceEpoch}');
    messenger.showSnackBar(SnackBar(content: Text('Downloading ${link.title ?? linkHost(link.url)}...')));
    try {
      final file = await ref
          .read(linkPreviewFetcherProvider)
          .download(link.url, temp, name: link.title ?? 'file', maxBytes: limit);
      messenger.hideCurrentSnackBar();
      await _sendFiles([(path: file.path, name: file.uri.pathSegments.last)]);
    } on AttachmentException catch (e) {
      messenger.hideCurrentSnackBar();
      _showError(e.message);
    } finally {
      // The outbox has its own copy by now.
      if (temp.existsSync()) await temp.delete(recursive: true);
    }
  }

  /// What servers accept unless they say otherwise.
  static const _defaultUploadLimit = 100 << 20;

  Future<void> _sendFiles(List<LocalFile> picked) async {
    if (picked.isEmpty || !mounted) return;
    final repository = ref.read(chatRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    // The first file answers the message being replied to.
    var replyTo = _mode?.isEdit == false ? _mode!.messageId : null;
    setState(() => _mode = null);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          picked.length == 1 ? 'Preparing ${picked.single.name}...' : 'Preparing ${picked.length} files...',
        ),
      ),
    );
    for (final file in picked) {
      try {
        await repository.sendAttachment(widget.conversationId, path: file.path, name: file.name, replyTo: replyTo);
        replyTo = null;
      } on AttachmentException catch (e) {
        _showError(e.message);
      } on ApiException catch (e) {
        _showError(e.toString());
      } on FileSystemException catch (e) {
        _showError('Could not read ${file.name}: ${e.message}');
      }
    }
    messenger.hideCurrentSnackBar();
  }

  Future<List<LocalFile>> _pick(_AttachSource source) async {
    final picker = ImagePicker();
    switch (source) {
      case _AttachSource.gallery when _isMobile:
        return [for (final x in await picker.pickMultipleMedia()) (path: x.path, name: x.name)];
      case _AttachSource.camera:
        final x = await picker.pickImage(source: ImageSource.camera);
        return x == null ? [] : [(path: x.path, name: x.name)];
      case _AttachSource.cameraVideo:
        final x = await picker.pickVideo(source: ImageSource.camera);
        return x == null ? [] : [(path: x.path, name: x.name)];
      case _AttachSource.gallery || _AttachSource.file:
        final files = await FilePicker.pickFiles(type: source == _AttachSource.gallery ? FileType.media : FileType.any);
        return [for (final f in files) (path: await localPathOf(f), name: f.name)];
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onFailedTap(ChatMessage message) async {
    final repository = ref.read(chatRepositoryProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('This message was not delivered')),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Try again'),
              onTap: () => Navigator.pop(context, 'retry'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: context.palette.failed),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'retry':
        await repository.retry(message.id);
      case 'delete':
        await repository.discard(message.id);
    }
  }

  void _markRead() {
    // Deferred so that notifying listeners never happens during a build.
    Future.microtask(() {
      if (mounted) {
        ref.read(chatRepositoryProvider).markRead(widget.conversationId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(messagesProvider(widget.conversationId), (_, next) {
      if (next.hasValue) _markRead();
    });
    // Up to date for the message actions ("Save GIF" or "Remove", the same
    // for stickers, and the recent reactions).
    ref.listen(savedGifsProvider, (_, _) {});
    ref.listen(savedStickersProvider, (_, _) {});
    ref.listen(recentReactionsProvider, (_, _) {});

    final summary = ref.watch(conversationProvider(widget.conversationId));
    final messages = ref.watch(messagesProvider(widget.conversationId));
    // In a steady order, so the pictures do not swap places.
    final typing = [...ref.watch(typingProvider(widget.conversationId)).value ?? const <String>{}]..sort();
    final profiles = ref.watch(profilesProvider).value ?? const {};
    final me = ref.watch(chatRepositoryProvider).me;
    String nameOf(String id) => profiles[id]?.displayName ?? UserId.fallbackName(id, me: me);

    final view = ColoredBox(
      color: context.palette.chatBackground,
      child: Column(
        children: [
          _TitleBar(summary: summary, nameOf: nameOf, fullScreen: widget.fullScreen),
          if (summary != null) _SecurityBanner(summary: summary, nameOf: nameOf),
          _HubBanner(conversationId: widget.conversationId),
          CallStrip(conversationId: widget.conversationId),
          CallStage(conversationId: widget.conversationId),
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load messages: $e')),
              data: (list) => _MessageList(
                controller: _scroll,
                onFailedTap: _onFailedTap,
                messages: list,
                typing: typing,
                me: me,
                nameOf: nameOf,
                rowKeys: _rowKeys,
                highlighted: _highlighted,
                onActions: (message, position, {reactionsOnly = false}) => showMessageActions(
                  context,
                  ref,
                  message: message,
                  me: me,
                  at: position,
                  reactionsOnly: reactionsOnly,
                  onReply: (m) => _reply(m, nameOf),
                  onEdit: _edit,
                ),
                onReply: (message) => _reply(message, nameOf),
                onReact: (message, emoji, remove) => reactTo(ref, message, emoji, remove: remove),
                onQuoteTap: (id) => _showMessage(id, list),
              ),
            ),
          ),
          Composer(
            mode: _mode,
            onCancelMode: () => setState(() => _mode = null),
            conversationId: widget.conversationId,
            customEmojis: ref.watch(chatEmojisProvider(widget.conversationId)),
            onSend: _send,
            // Until the setting is read, no link is fetched.
            onPreviewLink: switch (ref.watch(linkPreviewsProvider)) {
              AsyncData(value: true) || AsyncError() => ref.read(linkPreviewFetcherProvider).fetch,
              _ => null,
            },
            onSendLinkedFile: _sendLinkedFile,
            linkedFileLimit: ref.read(chatRepositoryProvider).maxUploadBytes ?? _defaultUploadLimit,
            onAttach: _attach,
            onGif: _sendGif,
            onSticker: _sendSticker,
            onPaste: _paste,
            // Only once the setting is known to allow it.
            onTyping: switch (ref.watch(typingNotificationsProvider)) {
              AsyncData(value: true) => () => ref.read(chatRepositoryProvider).sendTyping(widget.conversationId),
              _ => null,
            },
          ),
        ],
      ),
    );
    final droppable = FileDropTarget(
      label: 'Drop files to send them to ${summary?.title ?? 'this chat'}',
      onFiles: _sendFromOtherApps,
      // Files would end the edit.
      enabled: _mode?.isEdit != true,
      child: view,
    );
    // On phones, back returns to the list (see HomeShell).
    return droppable;
  }
}

enum _AttachSource { gallery, camera, cameraVideo, file }

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.controller,
    required this.onFailedTap,
    required this.messages,
    this.typing = const [],
    required this.me,
    required this.nameOf,
    required this.rowKeys,
    required this.onActions,
    required this.onReact,
    required this.onQuoteTap,
    required this.onReply,
    this.highlighted,
  });

  final ScrollController controller;
  final void Function(ChatMessage message) onFailedTap;
  final List<ChatMessage> messages;

  /// Who else is typing: shown below the newest message.
  final List<String> typing;
  final String me;
  final String Function(String userId) nameOf;
  final Map<String, GlobalKey> rowKeys;
  final void Function(ChatMessage message, Offset? position, {bool reactionsOnly}) onActions;
  final void Function(ChatMessage message) onReply;

  /// With a mouse (desktop), messages get hover buttons.
  static bool get _hoverActions => switch (defaultTargetPlatform) {
    TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
    _ => false,
  };
  final void Function(ChatMessage message, String emoji, bool remove) onReact;
  final void Function(String messageId) onQuoteTap;
  final String? highlighted;

  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _isGroupLine(ChatMessage m) => m.envelope.isGroupLine;

  bool _continues(ChatMessage previous, ChatMessage next) =>
      !_isGroupLine(previous) &&
      !_isGroupLine(next) &&
      previous.senderId == next.senderId &&
      _sameDay(previous.sentAt, next.sentAt) &&
      next.sentAt.difference(previous.sentAt) < _ChatViewState._groupGap;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && typing.isEmpty) {
      return Center(
        child: Text('No messages yet. Say hello!', style: TextStyle(color: context.palette.textSecondary)),
      );
    }
    // Reversed so the list starts at the newest message and stays anchored to
    // the bottom as messages arrive.
    return ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: messages.length + (typing.isEmpty ? 0 : 1),
      itemBuilder: (context, reversedIndex) {
        if (typing.isNotEmpty) {
          if (reversedIndex == 0) return TypingBubble(users: typing, nameOf: nameOf);
          reversedIndex--;
        }
        final index = messages.length - 1 - reversedIndex;
        final message = messages[index];
        final previous = index > 0 ? messages[index - 1] : null;
        final next = index < messages.length - 1 ? messages[index + 1] : null;
        final newDay = previous == null || !_sameDay(previous.sentAt, message.sentAt);

        final Widget bubble = _isGroupLine(message)
            ? _GroupLine(
                key: ValueKey(message.id),
                text: describeGroupChange(message.envelope, me: me, nameOf: nameOf),
                emoji: _lineEmoji(message.envelope),
              )
            : MessageBubble(
                key: rowKeys.putIfAbsent(message.id, GlobalKey.new),
                message: message,
                isMine: message.senderId == me,
                senderName: nameOf(message.senderId),
                me: me,
                nameOf: nameOf,
                highlighted: message.id == highlighted,
                onActions: (position) => onActions(message, position),
                hoverActions: _hoverActions,
                onReply: () => onReply(message),
                onReactAt: (position) => onActions(message, position, reactionsOnly: true),
                onReact: (emoji, remove) => onReact(message, emoji, remove),
                onQuoteTap: onQuoteTap,
                isFirstInGroup: previous == null || newDay || !_continues(previous, message),
                isLastInGroup:
                    next == null || !_continues(message, next) || next.sentAt.minute != message.sentAt.minute,
                onRetry: () => onFailedTap(message),
              );
        if (!newDay) return bubble;
        return Column(
          children: [
            _DaySeparator(day: message.sentAt),
            bubble,
          ],
        );
      },
    );
  }
}

/// A change to the group ("Kumiko added Naoko"), centered in the timeline.
/// The custom emoji a line about a group's emojis is about, if it names one.
({String name, MediaRef picture})? _lineEmoji(Envelope line) {
  final (name, picture) = (line.body['name'], line.body['picture']);
  if (name is! String || picture is! Map) return null;
  try {
    return (name: name, picture: MediaRef.fromJson(picture.cast<String, Object?>()));
  } on FormatException {
    return null;
  }
}

class _GroupLine extends StatelessWidget {
  const _GroupLine({super.key, required this.text, this.emoji});

  final String text;

  /// Shown after the text.
  final ({String name, MediaRef picture})? emoji;

  @override
  Widget build(BuildContext context) {
    final emoji = this.emoji;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
      child: Text.rich(
        TextSpan(
          text: text,
          children: [
            if (emoji != null) ...[
              const TextSpan(text: ' '),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: CustomEmojiImage(name: emoji.name, picture: emoji.picture, size: 20),
              ),
            ],
          ],
        ),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: context.palette.textMuted),
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(color: context.palette.listBackground, borderRadius: BorderRadius.circular(12)),
        child: Text(formatDay(day), style: TextStyle(fontSize: 12, color: context.palette.textMuted)),
      ),
    );
  }
}

/// The title opens what the chat is about: in a direct chat the other
/// person's profile, in a group its info (members, name, picture).
Widget _titleOnTap(BuildContext context, ConversationSummary? s, bool direct, Widget info) {
  if (s == null || !direct && !s.conversation.isGroup) return info;
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      key: Key(direct ? 'chat-title-profile' : 'chat-title-group-info'),
      behavior: HitTestBehavior.opaque,
      onTap: () => direct ? showProfileCard(context, s.avatarId) : showGroupInfo(context, s.id),
      child: info,
    ),
  );
}

class _TitleBar extends ConsumerWidget {
  const _TitleBar({required this.summary, required this.nameOf, required this.fullScreen});

  final ConversationSummary? summary;
  final String Function(String userId) nameOf;
  final bool fullScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foreground = fullScreen ? context.palette.onHeader : context.palette.textPrimary;
    final s = summary;
    final typing = s == null ? const <String>{} : ref.watch(typingProvider(s.id)).value ?? const {};
    final me = ref.watch(chatRepositoryProvider).me;
    final direct = s != null && !s.conversation.isGroup && s.avatarId != me;
    final muted = s != null && ref.watch(chatSettingsOfProvider(s.id)).mutedAt(ref.watch(clockProvider)());
    final presence = direct ? ref.watch(presenceOfProvider(s.avatarId)) : Presence.offline;
    final subtitle = typing.isNotEmpty
        ? typingText([
            for (final user in [...typing]..sort()) nameOf(user),
          ])
        : s != null && s.conversation.isGroup
        ? '${s.conversation.members.length} members'
        : presence != Presence.offline
        ? presenceLabel(presence)
        : null;
    final info = s == null
        ? const SizedBox.expand()
        : Row(
            children: [
              PresenceAvatar(id: s.avatarId, label: s.title, picture: s.picture, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: EmojiText(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: foreground),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'End-to-end encrypted',
                          child: Icon(Icons.lock, size: 14, color: foreground.withValues(alpha: 0.75)),
                        ),
                        if (muted) ...[
                          const SizedBox(width: 4),
                          Tooltip(
                            message: 'Muted',
                            child: Icon(
                              Icons.notifications_off,
                              key: const Key('chat-title-muted'),
                              size: 14,
                              color: foreground.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        key: const Key('chat-subtitle'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: foreground.withValues(alpha: 0.75)),
                      ),
                  ],
                ),
              ),
            ],
          );
    final bar = SizedBox(
      height: 56,
      child: Row(
        children: [
          if (fullScreen)
            IconButton(
              tooltip: 'Back',
              icon: Icon(Icons.arrow_back, color: foreground),
              onPressed: () => context.go('/chats'),
            )
          else
            const SizedBox(width: 16),
          // Full screen, this bar is also the window's title bar on desktop.
          Expanded(
            child: fullScreen
                ? WindowDragArea(child: _titleOnTap(context, s, direct, info))
                : _titleOnTap(context, s, direct, info),
          ),
          if (s != null) CallButton(summary: s, foreground: foreground, video: true),
          if (s != null) CallButton(summary: s, foreground: foreground),
          // A group's info opens from its name, and from the chat's menu.
          if (s != null && !s.conversation.isGroup && s.avatarId != me)
            _VerifyButton(userId: s.avatarId, name: s.title, foreground: foreground),
          if (s != null) _ChatMenuButton(conversationId: s.id, foreground: foreground),
          if (fullScreen) const WindowButtons(),
        ],
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: fullScreen ? context.palette.header : context.palette.surface,
        border: Border(bottom: BorderSide(color: context.palette.panelDivider)),
      ),
      child: fullScreen ? SafeArea(bottom: false, child: bar) : bar,
    );
  }
}

/// Says why sending is paused in this chat and, when the fix is the user's to
/// make, offers it. Messages written meanwhile wait in the outbox.
/// Says why messages wait when the server that orders the conversation,
/// another than the user's, cannot be reached.
class _HubBanner extends ConsumerWidget {
  const _HubBanner({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(unreachableHubsProvider.select((hubs) => hubs.value?[conversationId]));
    if (host == null) return const SizedBox.shrink();
    final server = host.isEmpty ? 'The server this chat runs on' : '$host, the server this chat runs on,';
    return Container(
      key: const Key('hub-banner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: context.palette.warningBackground,
        border: Border(bottom: BorderSide(color: context.palette.panelDivider)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, color: context.palette.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "$server can't be reached right now, so messages here wait. They're sent once it's back.",
              style: TextStyle(color: context.palette.textPrimary, fontSize: 13.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _SecurityBanner extends ConsumerWidget {
  const _SecurityBanner({required this.summary, required this.nameOf});

  final ConversationSummary summary;
  final String Function(String userId) nameOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changed = (ref.watch(identityChangesProvider).value ?? const {})
        .where(summary.conversation.members.contains)
        .firstOrNull;
    final issue = summary.securityIssue;
    if (changed == null && issue == null) return const SizedBox.shrink();
    return Container(
      key: const Key('security-banner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: context.palette.warningBackground,
        border: Border(bottom: BorderSide(color: context.palette.panelDivider)),
      ),
      child: Row(
        children: [
          Icon(Icons.gpp_maybe_outlined, color: context.palette.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              changed != null
                  ? "${nameOf(changed)}'s security key changed, for example because they reset "
                        'encryption. You verified them before, so your messages wait until you '
                        'verify them again or accept the new key.'
                  : issue!,
              style: TextStyle(color: context.palette.textPrimary, fontSize: 13.5, height: 1.3),
            ),
          ),
          if (changed != null)
            TextButton(
              key: const Key('verify-again'),
              onPressed: () => verifyContact(context, ref, changed),
              child: const Text('Verify'),
            ),
          if (changed != null)
            TextButton(
              key: const Key('accept-identity'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ref.read(chatRepositoryProvider).acceptIdentityChange(changed);
                } on Exception catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('Could not accept the new key: $e')));
                }
              },
              child: const Text('Accept'),
            ),
        ],
      ),
    );
  }
}

/// A direct chat's verification: a green badge once the user compared emoji
/// with the contact, otherwise a button to do so.
/// The chat's menu (see [showChatMenu]): its settings, muting it, and more.
class _ChatMenuButton extends ConsumerWidget {
  const _ChatMenuButton({required this.conversationId, required this.foreground});

  final String conversationId;
  final Color foreground;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const Key('chat-menu'),
    tooltip: 'More',
    icon: Icon(Icons.more_vert, color: foreground),
    onPressed: () {
      final box = context.findRenderObject()! as RenderBox;
      showChatMenu(
        context,
        ref,
        conversationId: conversationId,
        at: box.localToGlobal(box.size.bottomLeft(Offset.zero)),
      );
    },
  );
}

class _VerifyButton extends ConsumerWidget {
  const _VerifyButton({required this.userId, required this.name, required this.foreground});

  final String userId;
  final String name;
  final Color foreground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verified = ref.watch(verifiedUsersProvider).value?.contains(userId) ?? false;
    return IconButton(
      key: const Key('verify-contact'),
      tooltip: verified ? '$name is verified' : 'Verify $name',
      icon: Icon(
        verified ? Icons.verified_user : Icons.shield_outlined,
        color: verified ? context.palette.success : foreground,
      ),
      onPressed: verified ? null : () => verifyContact(context, ref, userId),
    );
  }
}
