import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/remote/link_previews.dart';
import '../emojis/custom_emoji_picker.dart';
import '../emojis/emoji_suggestions.dart';
import '../stickers/sticker_picker.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/links.dart';
import 'expression_panel.dart';
import 'gif_picker.dart';

/// What the next message does besides being sent: answer a message, or
/// replace the text of one of the user's own.
class ComposerMode {
  const ComposerMode.reply({required this.messageId, required this.title, required this.preview}) : editText = null;

  const ComposerMode.edit({required this.messageId, required String text})
    : title = 'Edit message',
      preview = text,
      editText = text;

  final String messageId;
  final String title;
  final String preview;

  /// The text being edited; null when replying.
  final String? editText;

  bool get isEdit => editText != null;
}

/// Message input, styled after Hanashi's "Reply" panel. Enter sends on
/// hardware keyboards; Shift+Enter inserts a newline; Escape closes the
/// emoji panel, or stops replying or editing. On phones the emoji panel takes
/// the keyboard's place.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    this.onPreviewLink,
    this.onSendLinkedFile,
    this.linkedFileLimit,
    this.onAttach,
    this.onGif,
    this.onSticker,
    this.onPaste,
    this.onTyping,
    this.mode,
    this.onCancelMode,
    this.conversationId,
    this.customEmojis = const {},
  });

  /// Sends the text, with the preview of a link in it if there is one.
  final void Function(String text, LinkPreviewDraft? link) onSend;

  /// Makes a preview of a link being written (null if there is nothing to
  /// show); without it, links get none.
  final Future<LinkPreviewDraft?> Function(String address)? onPreviewLink;

  /// Sends the file a link leads to (an image or other file, up to
  /// [linkedFileLimit] if that is known) instead of the link.
  final ValueChanged<LinkPreviewDraft>? onSendLinkedFile;
  final int? linkedFileLimit;

  final VoidCallback? onAttach;

  /// Sends a GIF from the panel's GIF tab.
  final ValueChanged<GifRef>? onGif;

  /// Sends a sticker from the panel's sticker tab.
  final ValueChanged<StickerRef>? onSticker;

  /// Ctrl+V (Cmd+V) on a desktop: takes files or an image from the clipboard
  /// and returns true, or returns false, and the text is pasted as usual.
  final Future<bool> Function()? onPaste;

  /// Called as the user types (the repository throttles what it sends).
  final VoidCallback? onTyping;

  /// Replying or editing, shown above the input.
  final ComposerMode? mode;
  final VoidCallback? onCancelMode;

  /// The chat being written in: the panel then has a tab of custom emojis.
  final String? conversationId;

  /// What `:name:` stands for here, for the suggestions while it is written.
  final Map<String, MediaRef> customEmojis;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = EmojiEditingController();
  final _focusNode = FocusNode();

  /// The emoji panel (see [ExpressionPanel]) is open under the input.
  var _panelOpen = false;

  /// Once opened, the panel stays built (hidden when closed): it keeps the
  /// user's place, and the emoji picker is not torn down in the middle of
  /// its tab animation, which its package does not clean up after.
  var _panelBuilt = false;

  /// The first link in the text that can have a preview, and the preview
  /// once made (null while being made, or if there is none).
  String? _linkAddress;
  LinkPreviewDraft? _link;
  var _linkLoading = false;
  Timer? _linkTimer;

  /// Links whose preview the user closed, until the message is sent.
  final _closedLinks = <String>{};

  /// Emojis for the `:name` being written; Enter or Tab writes the
  /// [_highlighted] one.
  var _suggestions = const <EmojiSuggestion>[];
  var _highlighted = 0;

  /// Where the `:` of that name is, and the name as written so far.
  int? _suggestedAt;
  String? _suggestedFor;

  /// The `:` whose suggestions the user closed with Escape: none until
  /// another is being written.
  int? _dismissedAt;

  static bool get _touch =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  void _togglePanel() {
    final open = !_panelOpen;
    setState(() {
      _panelOpen = open;
      _panelBuilt = true;
    });
    if (_touch && open) {
      _focusNode.unfocus(); // The panel replaces the keyboard...
    } else {
      _focusNode.requestFocus(); // ...and the other way round; on desktop typing goes on.
    }
  }

  void _escape() {
    if (_suggestions.isNotEmpty) {
      setState(() {
        _dismissedAt = _suggestedAt;
        _suggestions = const [];
      });
    } else if (_panelOpen) {
      setState(() => _panelOpen = false);
    } else {
      widget.onCancelMode?.call();
    }
  }

  @override
  void initState() {
    super.initState();
    var last = '';
    _controller.addListener(() {
      setState(() {
        _previewLink();
        _suggest();
      });
      final text = _controller.text;
      if (text != last && text.trim().isNotEmpty && widget.mode?.isEdit != true) widget.onTyping?.call();
      last = text;
    });
  }

  /// Previews the first link that can have one, once the user stops typing
  /// for a moment. An edit changes only the text: no previews.
  void _previewLink() {
    final fetch = widget.onPreviewLink;
    final address = fetch == null || widget.mode?.isEdit == true
        ? null
        : findLinks(_controller.text)
              .map((link) => link.address)
              .where((a) => !_closedLinks.contains(a) && LinkPreviewFetcher.canPreview(Uri.parse(a)))
              .firstOrNull;
    if (address == _linkAddress) return;
    _linkTimer?.cancel();
    _linkAddress = address;
    _link = null;
    _linkLoading = address != null;
    if (address == null) return;
    _linkTimer = Timer(const Duration(milliseconds: 500), () async {
      final link = await fetch!(address).catchError((Object _) => null);
      if (!mounted || _linkAddress != address) return;
      setState(() {
        _link = link;
        _linkLoading = false;
      });
    });
  }

  /// Suggests emojis for a `:name` being written right before the cursor.
  void _suggest() {
    final value = _controller.value;
    final cursor = value.selection;
    final typed = cursor.isValid && cursor.isCollapsed
        ? typedEmojiName.firstMatch(value.text.substring(0, cursor.start))
        : null;
    final at = typed == null ? null : cursor.start - typed[1]!.length - 1;
    if (at != _dismissedAt) _dismissedAt = null;
    final suggestions = typed == null || at == _dismissedAt
        ? const <EmojiSuggestion>[]
        : suggestEmojis(typed[1]!, widget.customEmojis);
    // Another name, another list: its first is the one Enter writes.
    if (typed?[1] != _suggestedFor) _highlighted = 0;
    _suggestedAt = at;
    _suggestedFor = typed?[1];
    _suggestions = suggestions;
  }

  /// Writes [suggestion] over the `:name` it is for.
  void _choose(EmojiSuggestion suggestion) {
    final at = _suggestedAt;
    final value = _controller.value;
    if (at == null || !value.selection.isValid) return;
    final end = value.selection.start;
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(at, end, suggestion.text),
      selection: TextSelection.collapsed(offset: at + suggestion.text.length),
    );
    _focusNode.requestFocus();
  }

  void _moveHighlight(int by) => setState(() => _highlighted = (_highlighted + by) % _suggestions.length);

  /// Enter writes the emoji suggested, if any; otherwise it sends.
  void _enter() {
    if (_suggestions.isNotEmpty) return _choose(_suggestions[_highlighted.clamp(0, _suggestions.length - 1)]);
    _send();
  }

  /// The file goes instead of the link; the rest of the text stays.
  void _sendLinkedFile() {
    final link = _link!;
    widget.onSendLinkedFile!(link);
    final text = _controller.text;
    final at = findLinks(text).where((l) => l.address == link.url).firstOrNull;
    if (at != null) {
      final rest = [text.substring(0, at.start).trimRight(), text.substring(at.end).trimLeft()];
      _controller.text = rest.where((part) => part.isNotEmpty).join(' ');
    }
    _focusNode.requestFocus();
  }

  bool _canSendFile(LinkPreviewDraft link) {
    final size = link.size, limit = widget.linkedFileLimit;
    // A file, not a page: one with a type of its own.
    return widget.onSendLinkedFile != null &&
        (link.kind == LinkKind.image || link.kind == LinkKind.file || link.mime != null) &&
        (size == null || limit == null || size <= limit);
  }

  void _closeLink() => setState(() {
    _closedLinks.add(_linkAddress!);
    _previewLink();
  });

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if ((old.onPreviewLink == null) != (widget.onPreviewLink == null)) _previewLink();
    final mode = widget.mode;
    if (mode?.messageId == old.mode?.messageId && mode?.isEdit == old.mode?.isEdit) return;
    if (mode?.isEdit == true) {
      _controller.text = mode!.editText!;
    } else if (old.mode?.isEdit == true) {
      _controller.clear(); // Stopped editing: the old text is not a draft.
    }
    if (mode != null) _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _linkTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    if (await widget.onPaste!()) return;
    final field = _focusNode.context;
    if (field != null && field.mounted) {
      Actions.maybeInvoke(field, const PasteTextIntent(SelectionChangedCause.keyboard));
    }
  }

  void _sendGif(GifRef gif) {
    widget.onGif!(gif);
    setState(() => _panelOpen = false);
  }

  /// What the panel holds, for the button's tooltip: "Emoji, GIFs and stickers".
  String get _panelKinds {
    final kinds = ['Emoji', if (widget.onGif != null) 'GIFs', if (widget.onSticker != null) 'stickers'];
    return kinds.length == 1 ? kinds.single : '${kinds.sublist(0, kinds.length - 1).join(', ')} and ${kinds.last}';
  }

  void _sendSticker(StickerRef sticker) {
    widget.onSticker!(sticker);
    setState(() => _panelOpen = false);
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final link = _link;
    widget.onSend(text, link != null && findLinks(text).any((l) => l.address == link.url) ? link : null);
    _closedLinks.clear();
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _controller.text.trim().isNotEmpty;
    final mode = widget.mode;
    return Container(
      decoration: BoxDecoration(
        color: context.palette.replyPanel,
        border: Border(top: BorderSide(color: context.palette.fieldBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mode != null) _ModeBar(mode: mode, onCancel: widget.onCancelMode),
                  if (_linkAddress != null && (_linkLoading || _link != null))
                    _LinkBar(
                      address: _linkAddress!,
                      link: _link,
                      onClose: _closeLink,
                      onSendFile: _link != null && _canSendFile(_link!) ? _sendLinkedFile : null,
                    ),
                  if (_suggestions.isNotEmpty)
                    EmojiSuggestions(
                      suggestions: _suggestions,
                      highlighted: _highlighted.clamp(0, _suggestions.length - 1),
                      onChoose: _choose,
                    ),
                  _inputRow(mode, canSend),
                ],
              ),
            ),
            // Part of the field: clicking in the panel neither takes focus from
            // the field (on desktop, the cursor would be lost) nor closes it.
            if (_panelBuilt)
              Visibility(
                visible: _panelOpen,
                maintainState: true,
                child: TextFieldTapRegion(
                  child: ExpressionPanel(
                    target: ExpressionTarget(
                      text: _controller,
                      conversationId: widget.conversationId,
                      onGif: widget.onGif == null ? null : _sendGif,
                      onSticker: widget.onSticker == null ? null : _sendSticker,
                    ),
                    // An edit changes only the text.
                    tabs: [
                      emojiTab,
                      if (widget.conversationId != null) customEmojiTab,
                      if (widget.onGif != null && mode?.isEdit != true) gifTab,
                      if (widget.onSticker != null && mode?.isEdit != true) stickerTab,
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _inputRow(ComposerMode? mode, bool canSend) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      IconButton(
        tooltip: 'Attach',
        icon: Icon(Icons.add_circle_outline, color: context.palette.replyAccent),
        // A new text is all an edit can change.
        onPressed: mode?.isEdit == true ? null : widget.onAttach,
      ),
      TextFieldTapRegion(
        child: IconButton(
          key: const Key('composer-emoji'),
          tooltip: _panelOpen
              ? (_touch ? 'Keyboard' : 'Close')
              : _panelKinds,
          isSelected: _panelOpen,
          icon: Icon(Icons.emoji_emotions_outlined, color: context.palette.replyAccent),
          selectedIcon: Icon(_touch ? Icons.keyboard_outlined : Icons.emoji_emotions, color: context.palette.replyAccent),
          onPressed: _togglePanel,
        ),
      ),
      Expanded(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): _enter,
            if (_suggestions.isNotEmpty) ...{
              const SingleActivator(LogicalKeyboardKey.tab): _enter,
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => _moveHighlight(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => _moveHighlight(-1),
            },
            // An edit changes only the text.
            if (widget.onPaste != null && !_touch && mode?.isEdit != true)
              defaultTargetPlatform == TargetPlatform.macOS
                      ? const SingleActivator(LogicalKeyboardKey.keyV, meta: true)
                      : const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  () => unawaited(_paste()),
            if (mode != null || _panelOpen || _suggestions.isNotEmpty)
              const SingleActivator(LogicalKeyboardKey.escape): _escape,
          },
          child: TextField(
            key: const Key('composer-field'),
            controller: _controller,
            focusNode: _focusNode,
            minLines: 1,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(hintText: 'Type a message'),
            // On a phone, the keyboard comes back instead of the panel.
            onTap: () {
              if (_touch && _panelOpen) setState(() => _panelOpen = false);
            },
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filled(
        key: const Key('composer-send'),
        tooltip: mode?.isEdit == true ? 'Save' : 'Send',
        style: IconButton.styleFrom(
          backgroundColor: context.palette.replyAccent,
          disabledBackgroundColor: context.palette.fieldBorder,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minimumSize: const Size(46, 46),
        ),
        icon: Icon(
          mode?.isEdit == true ? Icons.check_rounded : Icons.send_rounded,
          color: context.palette.onAccent,
          size: 20,
        ),
        onPressed: canSend ? _send : null,
      ),
    ],
  );
}

/// "Replying to Kumiko: ..." or "Edit message", with a button to stop.
class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.mode, this.onCancel});

  final ComposerMode mode;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('composer-mode'),
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 8),
      child: Row(
        children: [
          Icon(mode.isEdit ? Icons.edit_outlined : Icons.reply, size: 20, color: context.palette.replyAccent),
          const SizedBox(width: 10),
          Container(width: 3, height: 34, color: context.palette.replyAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EmojiText(
                  mode.title,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.palette.replyAccent),
                ),
                EmojiText(
                  mode.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('composer-mode-cancel'),
            tooltip: mode.isEdit ? 'Cancel editing' : 'Cancel reply',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 20, color: context.palette.textSecondary),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// The preview of a link in the message being written, as it will be sent,
/// with a button to send the link without it, and for a link to a file one
/// to send the file instead.
class _LinkBar extends StatelessWidget {
  const _LinkBar({required this.address, required this.link, required this.onClose, this.onSendFile});

  final String address;

  /// Null while it is being made.
  final LinkPreviewDraft? link;
  final VoidCallback onClose;
  final VoidCallback? onSendFile;

  @override
  Widget build(BuildContext context) {
    final link = this.link;
    final picture = link?.picture;
    final media = link?.media;
    // A still picture goes along only for the viewer.
    final plays = media != null && (link!.kind == LinkKind.gif || media.mime.startsWith('video/'));
    final host = linkHost(address);
    return Padding(
      key: const Key('composer-link'),
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 8),
      child: Row(
        children: [
          Icon(Icons.link, size: 20, color: context.palette.replyAccent),
          const SizedBox(width: 10),
          Container(width: 3, height: 40, color: context.palette.replyAccent),
          const SizedBox(width: 8),
          if (picture != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Image.memory(picture.bytes, width: 40, height: 40, fit: BoxFit.cover),
                  // It goes with the message, to play in the chat.
                  if (plays)
                    Icon(
                      link.kind == LinkKind.gif ? Icons.gif_box_outlined : Icons.play_circle_outline,
                      key: const Key('composer-link-media'),
                      color: Colors.white,
                      size: 22,
                      shadows: const [Shadow(blurRadius: 4)],
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EmojiText(
                  link?.site ?? host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.palette.replyAccent),
                ),
                if (link == null)
                  Text(
                    'Making a preview...',
                    style: TextStyle(fontSize: 13, color: context.palette.textMuted),
                  )
                else
                  EmojiText(
                    link.title ?? link.description ?? address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
                  ),
              ],
            ),
          ),
          if (onSendFile != null)
            TextButton(
              key: const Key('composer-link-file'),
              onPressed: onSendFile,
              child: Text(switch (link?.mime ?? '') {
                'image/gif' => 'Send as GIF',
                final mime when mime.startsWith('image/') => 'Send as photo',
                final mime when mime.startsWith('video/') => 'Send as video',
                _ => 'Send as file',
              }),
            ),
          IconButton(
            key: const Key('composer-link-close'),
            tooltip: 'Send without a preview',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 20, color: context.palette.textSecondary),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
