import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/models.dart';
import '../../data/packs/sticker_pack.dart';
import '../../state/providers.dart';
import '../calls/call_widgets.dart';
import '../emojis/custom_emoji_picker.dart';
import '../media/gif_view.dart';
import '../media/media_viewer.dart';
import '../media/save_media.dart';
import '../profile/profile_card.dart';
import '../stickers/sticker_image.dart';
import '../stickers/sticker_pack_info.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';
import '../widgets/format.dart';
import '../widgets/links.dart';
import 'bubble_look.dart';

/// One message row in Hanashi style: incoming messages sit on the left in
/// dark-slate bubbles under the sender's avatar and name; the user's own
/// messages sit on the right in blue bubbles. Photos, videos and files are
/// shown on white bordered cards, like the photos in the game. A reply shows
/// the message it answers on top, and reactions sit under the bubble.
///
/// Consecutive messages from the same sender form a group: only the first
/// ([isFirstInGroup]) shows avatar, name and bubble tail, and only the last
/// ([isLastInGroup]) shows the time.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.senderName,
    this.me = '',
    this.nameOf = _localPart,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.highlighted = false,
    this.onRetry,
    this.onActions,
    this.onReact,
    this.onQuoteTap,
    this.hoverActions = false,
    this.onReply,
    this.onReactAt,
  });

  final ChatMessage message;
  final bool isMine;
  final String senderName;

  /// The user, to mark their own reactions.
  final String me;
  final String Function(String userId) nameOf;
  final bool isFirstInGroup;
  final bool isLastInGroup;

  /// Briefly lit up, e.g. after jumping to it from a reply.
  final bool highlighted;
  final VoidCallback? onRetry;

  /// Long press (null position) or right click: reactions and actions.
  final void Function(Offset? position)? onActions;

  /// Tapping a reaction: adds [emoji] to the user's reactions, or takes it
  /// back ([remove]).
  final void Function(String emoji, bool remove)? onReact;

  /// Tapping the quote of a reply.
  final void Function(String messageId)? onQuoteTap;

  /// With a mouse: React, Reply and More buttons beside the message while
  /// the pointer is over it.
  final bool hoverActions;
  final VoidCallback? onReply;

  /// The hover bar's React button, at [position]: the reactions menu.
  final void Function(Offset position)? onReactAt;

  static const _avatarSize = 52.0;
  static const _avatarGap = 12.0;

  static String _localPart(String userId) => userId.split('@').first;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubbleWidth = (constraints.maxWidth - _avatarSize - _avatarGap - 48) * 0.85;
        final actions = onActions;
        final actionable = actions != null && !message.isDeleted && message.envelope.type != Envelope.encryptedType;
        Widget bubble = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth.clamp(120, 520)),
          child: _Bubble(
            message: message,
            isMine: isMine,
            showTail: isFirstInGroup,
            nameOf: nameOf,
            onQuoteTap: onQuoteTap,
          ),
        );
        if (actionable) {
          bubble = GestureDetector(
            onLongPress: () => actions(null),
            onSecondaryTapUp: (details) => actions(details.globalPosition),
            child: bubble,
          );
        }
        final meta = _Meta(message: message, showTime: isLastInGroup, onRetry: onRetry);
        final reactions = message.reactions.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _Reactions(message: message, me: me, nameOf: nameOf, onReact: onReact),
              );

        final padding = EdgeInsets.only(
          left: 16,
          right: 16,
          // Between one person's messages, the game's gap.
          top: isFirstInGroup ? 14 : 7,
        );

        // Hover actions float over the bubble (see _Hover): they take no room
        // in the row, so nothing moves when they show.
        Widget row(Widget Function(Widget bubble)? anchor) {
          final anchored = anchor?.call(bubble) ?? bubble;
          return isMine
              ? _mine(padding, anchored, meta, reactions)
              : _theirs(context, padding, anchored, meta, reactions);
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          color: highlighted ? context.palette.replyPanel : context.palette.replyPanel.withValues(alpha: 0),
          child: hoverActions && actionable
              ? _Hover(
                  mine: isMine,
                  bar: _HoverBar(onReact: onReactAt, onReply: onReply, onMore: actions),
                  builder: row,
                )
              : row(null),
        );
      },
    );
  }

  Widget _mine(EdgeInsets padding, Widget bubble, Widget meta, Widget? reactions) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            meta,
            const SizedBox(width: 6),
            Flexible(child: bubble),
          ],
        ),
        ?reactions,
      ],
    ),
  );

  Widget _theirs(BuildContext context, EdgeInsets padding, Widget bubble, Widget meta, Widget? reactions) => Padding(
    padding: padding,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _avatarSize,
          child: isFirstInGroup
              ? Builder(
                  builder: (context) => GestureDetector(
                    key: ValueKey('sender-${message.id}'),
                    onTap: () => showProfileCard(context, message.senderId),
                    child: Avatar(id: message.senderId, label: senderName, size: _avatarSize),
                  ),
                )
              : null,
        ),
        const SizedBox(width: _avatarGap),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // As in the game: the name level with the top of the picture,
              // and the bubble right below it, its tail by the picture's middle.
              if (isFirstInGroup)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: EmojiText(
                    senderName,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      height: 1,
                      color: context.palette.textPrimary,
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(child: bubble),
                  const SizedBox(width: 6),
                  meta,
                ],
              ),
              ?reactions,
            ],
          ),
        ),
      ],
    ),
  );
}

/// Who is typing, below the newest message: their picture beside a bubble
/// whose dots rise in turn, where their message will appear. With several
/// people, the first two pictures overlap.
class TypingBubble extends StatelessWidget {
  const TypingBubble({super.key, required this.users, required this.nameOf});

  /// At least one.
  final List<String> users;
  final String Function(String userId) nameOf;

  static const _smallAvatar = 36.0;

  @override
  Widget build(BuildContext context) {
    const size = MessageBubble._avatarSize;
    final names = [for (final user in users) nameOf(user)];
    Widget avatar(int i, double size) => Avatar(id: users[i], label: names[i], size: size);
    // Set off from the one behind it.
    Widget ringed(Widget avatar) => Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: context.palette.chatBackground, shape: BoxShape.circle),
      child: avatar,
    );
    return Semantics(
      key: const Key('typing-bubble'),
      container: true,
      liveRegion: true,
      label: typingText(names),
      child: ExcludeSemantics(
        // Rises into place, like a message arriving.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          builder: (context, shown, child) => Opacity(
            opacity: shown,
            child: Transform.translate(offset: Offset(0, 8 * (1 - shown)), child: child),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: size,
                  child: users.length == 1
                      ? avatar(0, size)
                      : Stack(
                          children: [
                            Positioned(right: 0, bottom: 0, child: ringed(avatar(1, _smallAvatar))),
                            Positioned(left: 0, top: 0, child: ringed(avatar(0, _smallAvatar))),
                          ],
                        ),
                ),
                const SizedBox(width: MessageBubble._avatarGap),
                CustomPaint(
                  painter: _TailPainter(color: context.palette.incomingBubble, onLeft: true),
                  child: Container(
                    decoration: BoxDecoration(color: context.palette.incomingBubble, borderRadius: _Bubble._radius),
                    // As tall as a one-line message.
                    padding: BubbleLook.of(context).bubblePadding.copyWith(left: 16, right: 16),
                    child: const _TypingDots(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Three dots that rise and brighten one after another, over and over (held
/// still for those who turned animations off).
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  static const _dot = 8.0, _rise = 4.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0.25;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// How far up dot [i] is, 0 to 1: each rises and falls in its turn, in
  /// the first half of its cycle, and rests in the second.
  double _lift(int i) {
    final t = (_controller.value - i * 0.15) % 1;
    return t < 0.5 ? sin(t * 2 * pi) : 0;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: BubbleLook.of(context).lineHeight,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 5),
              child: Transform.translate(
                offset: Offset(0, _rise / 2 - _rise * _lift(i)),
                child: Container(
                  width: _dot,
                  height: _dot,
                  decoration: BoxDecoration(
                    color: context.palette.onBubble.withValues(alpha: 0.45 + 0.55 * _lift(i)),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Builds its child knowing whether the mouse is over it.
/// With a mouse: [bar] floats over the top corner of the bubble under the
/// pointer, half above it, on the side facing the middle of the chat (the
/// right of someone else's message, the left of the user's own). It takes no
/// room in the layout, so nothing moves when it shows, and it sits in the
/// overlay, so it can be clicked where it sticks out of the message.
class _Hover extends StatefulWidget {
  const _Hover({required this.mine, required this.bar, required this.builder});

  /// The user's own message: the bar goes on the bubble's left corner.
  final bool mine;
  final Widget bar;

  /// The message, its bubble passed through `anchor`, which puts the bar on it.
  final Widget Function(Widget Function(Widget bubble) anchor) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  final _bar = OverlayPortalController();
  var _overMessage = false;
  var _overBar = false;

  /// How far the bar reaches over the bubble's corner: about its padding, so
  /// that the bar sits on the corner without hiding the text.
  static const _overlap = 12.0;

  /// Going from the message onto the bar, the pointer leaves one before it
  /// enters the other: whether the bar shows is settled once both are known.
  void _over({bool? message, bool? bar}) {
    _overMessage = message ?? _overMessage;
    _overBar = bar ?? _overBar;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final show = _overMessage || _overBar;
      if (show != _bar.isShowing) show ? _bar.show() : _bar.hide();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// [bubble], with the bar over its top corner while shown: placed during
  /// layout, wherever the bubble is (also while the chat scrolls), so that
  /// the bar's own tooltips know where it is.
  Widget _anchor(Widget bubble) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _bar,
    overlayChildBuilder: (context, info) {
      final corner = MatrixUtils.transformPoint(
        info.childPaintTransform,
        widget.mine ? Offset.zero : info.childSize.topRight(Offset.zero),
      );
      // Over a sliver of the corner, the rest out in the open; half above
      // the bubble's top.
      return Positioned(
        left: widget.mine ? null : corner.dx - _overlap,
        right: widget.mine ? info.overlaySize.width - corner.dx - _overlap : null,
        top: corner.dy,
        child: FractionalTranslation(
          translation: const Offset(0, -0.5),
          child: MouseRegion(onEnter: (_) => _over(bar: true), onExit: (_) => _over(bar: false), child: widget.bar),
        ),
      );
    },
    child: bubble,
  );

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _over(message: true),
    onExit: (_) => _over(message: false),
    child: widget.builder(_anchor),
  );
}

/// React, Reply and More, over the corner of a message under the mouse (see
/// [_Hover]). The menus open at the button.
class _HoverBar extends StatelessWidget {
  const _HoverBar({this.onReact, this.onReply, this.onMore});

  final void Function(Offset position)? onReact;
  final VoidCallback? onReply;
  final void Function(Offset position)? onMore;

  @override
  Widget build(BuildContext context) {
    Widget button(Key key, String tooltip, IconData icon, void Function(BuildContext context)? onPressed) => Builder(
      builder: (context) => IconButton(
        key: key,
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: context.palette.textSecondary,
        icon: Icon(icon),
        onPressed: onPressed == null ? null : () => onPressed(context),
      ),
    );
    Offset below(BuildContext context) {
      final box = context.findRenderObject()! as RenderBox;
      return box.localToGlobal(box.size.bottomLeft(Offset.zero));
    }

    return Container(
      key: const Key('hover-actions'),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.palette.fieldBorder),
        // It floats over the bubble.
        boxShadow: [
          BoxShadow(color: context.palette.shadow.withAlpha(0x26), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            const Key('hover-react'),
            'React',
            Icons.add_reaction_outlined,
            onReact == null ? null : (context) => onReact!(below(context)),
          ),
          button(const Key('hover-reply'), 'Reply', Icons.reply, onReply == null ? null : (_) => onReply!()),
          button(
            const Key('hover-more'),
            'More',
            Icons.more_horiz,
            onMore == null ? null : (context) => onMore!(below(context)),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({
    required this.message,
    required this.isMine,
    required this.showTail,
    required this.nameOf,
    this.onQuoteTap,
  });

  final ChatMessage message;
  final bool isMine;
  final bool showTail;
  final String Function(String userId) nameOf;
  final void Function(String messageId)? onQuoteTap;

  /// A bubble's corners, as the game has them. Its text and padding are the
  /// device's choice (see [BubbleLook]).
  static const _radius = BorderRadius.all(Radius.circular(6));

  /// The size of one, two or three emoji sent by themselves.
  static const _bigEmojiSizes = [48.0, 40.0, 32.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = BubbleLook.of(context);
    final envelope = message.envelope;
    final gif = envelope.gif;
    final media = envelope.messageType?.isMedia == true ? envelope.media : null;
    final caption = envelope.text;
    final emojis = envelope.emojis;
    void showEmoji(String name, MediaRef picture) => showCustomEmoji(context, ref, name, picture);
    final reply = message.replyTo;
    Widget quote(bool onDark) => _Quote(
      reply: reply!,
      nameOf: nameOf,
      onDark: onDark,
      onTap: onQuoteTap == null ? null : () => onQuoteTap!(reply.id),
    );

    if (media != null || gif != null) {
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.palette.mediaCardBorder, width: 1.5),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reply != null) quote(false),
            if (gif != null)
              _GifBody(envelope: envelope, gif: gif)
            else if (media != null)
              switch (envelope.messageType!) {
                MessageType.image => _VisualMediaBody(envelope: envelope, media: media),
                MessageType.video => _VisualMediaBody(envelope: envelope, media: media, isVideo: true),
                _ => _FileBody(envelope: envelope, media: media),
              },
            if (caption != null && caption.isNotEmpty && envelope.messageType != MessageType.file)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 2),
                child: EmojiText(
                  caption,
                  onLink: (url) => openLink(context, ref, url),
                  emojis: emojis,
                  onEmoji: showEmoji,
                  style: look.textStyle.copyWith(color: context.palette.textPrimary),
                ),
              ),
          ],
        ),
      );
    }

    final color = isMine ? context.palette.outgoingBubble : context.palette.incomingBubble;
    if (envelope.type == Envelope.encryptedType) {
      return _FadedBubble(
        color: color,
        showTail: showTail,
        onLeft: !isMine,
        icon: Icons.lock_clock_outlined,
        text: 'Waiting for keys...',
        tooltip: 'This device cannot read this message yet. It will appear once the key arrives.',
      );
    }
    if (message.isDeleted) {
      return _FadedBubble(
        key: const Key('deleted-message'),
        color: color,
        showTail: showTail,
        onLeft: !isMine,
        icon: Icons.block,
        text: 'This message was deleted',
      );
    }
    // A call: what became of it, and a way in while it goes on.
    if (envelope.callId case final callId?) {
      return CallRecord(callId: callId, conversationId: envelope.conv, mine: isMine);
    }
    // A sticker: by itself, without a bubble; a reply's quote above it.
    if (envelope.sticker case final sticker?) {
      final packs = ref.watch(stickerPacksProvider).value ?? const <StickerPack>[];
      final image = stickerImage(
        packs,
        sticker,
        decodeWidth: (_StickerBody.size * MediaQuery.devicePixelRatioOf(context)).round(),
      );
      final Widget shown = image == null
          ? _FadedBubble(
              key: const Key('unknown-sticker'),
              color: color,
              showTail: showTail,
              onLeft: !isMine,
              icon: Icons.sticky_note_2_outlined,
              text: 'Sticker',
              tooltip: "From a sticker pack you don't have",
            )
          : _StickerBody(
              sticker: sticker,
              image: image,
              // Which pack it is from, and a way to add that.
              onTap: sticker.packSticker == null ? null : () => showStickerPackInfo(context, sticker),
            );
      return reply == null
          ? shown
          : Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [quote(false), shown],
            );
    }
    final content = envelope.messageType == MessageType.text ? caption ?? '' : envelope.preview;
    // A few emoji by themselves: large, without a bubble.
    final emoji = envelope.messageType == MessageType.text
        ? emojiOnlyCount(content, custom: emojis.keys.toSet())
        : null;
    if (emoji != null && emoji <= _bigEmojiSizes.length) {
      final big = EmojiText(
        content.trim(),
        key: const Key('big-emoji'),
        emojis: emojis,
        onEmoji: showEmoji,
        style: TextStyle(fontSize: _bigEmojiSizes[emoji - 1], height: 1.2, color: context.palette.textPrimary),
      );
      return reply == null
          ? big
          : Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [quote(false), big],
            );
    }
    final text = EmojiText(
      content,
      style: look.textStyle.copyWith(color: context.palette.onBubble),
      onLink: (url) => openLink(context, ref, url),
      // A preview of another kind of message names none.
      emojis: envelope.messageType == MessageType.text ? emojis : const {},
      onEmoji: showEmoji,
    );
    final link = envelope.link;
    return CustomPaint(
      painter: showTail ? _TailPainter.of(color: color, onLeft: !isMine) : null,
      child: Container(
        decoration: BoxDecoration(color: color, borderRadius: _radius),
        padding: look.bubblePadding,
        child: reply == null && link == null
            ? text
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (reply != null) quote(true),
                  text,
                  if (link != null) _LinkCard(link: link),
                ],
              ),
      ),
    );
  }
}

/// What a link in a text message leads to, as the sender's app found it:
/// the site is not contacted for it. A GIF it brings plays in place; its
/// picture, or the video it brings, opens in the viewer; the rest of it (and
/// the picture of a video it does not bring, to play it) opens the link, once
/// the user has seen the address: the card need not match where the link leads.
/// If the user chose so, a video or GIF it does not bring opens in the viewer
/// instead, to be loaded from the site there (after asking).
/// Pictures, videos and GIFs are shown large below the text, in their own
/// shape; only an icon is shown small beside it.
class _LinkCard extends ConsumerWidget {
  const _LinkCard({required this.link});

  final LinkPreview link;

  /// Narrower bubbles make it narrower.
  static const _width = 300.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = link.thumb;
    final media = link.media;
    final gif = media != null && link.kind == LinkKind.gif;
    final thumbBytes = thumb == null ? null : ref.watch(mediaBytesProvider(mediaKey(thumb))).value;
    // An animated image plays once it is here.
    final animation = gif && media.mime.startsWith('image/') && media.size <= maxInlineAnimationBytes
        ? ref.watch(mediaBytesProvider(mediaKey(media))).value
        : null;
    final w = (media ?? thumb)?.width, h = (media ?? thumb)?.height;
    final aspect = w != null && h != null && w > 0 && h > 0 ? w / h : 16 / 9;
    // One it does not bring loads from the site in the viewer, if the user
    // chose so; otherwise a video plays on the site.
    final source = media == null && (ref.watch(linkSourcesProvider).value ?? false) ? link.source : null;
    final loadsGif = source != null && link.kind == LinkKind.gif;
    final playsOnSite = media == null && source == null && link.kind == LinkKind.video;
    final duration = gif || loadsGif ? null : media?.durationMs ?? source?.durationMs;
    Widget picture(double aspect, {double radius = 4}) {
      final shown = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (gif && media.mime.startsWith('video/'))
                LoopingVideo(media: media, poster: thumb)
              else if ((animation ?? thumbBytes) != null)
                Image.memory((animation ?? thumbBytes)!, fit: BoxFit.cover, gaplessPlayback: true)
              else
                const ColoredBox(color: Color(0x33000000)),
              if (gif || loadsGif) const Positioned(left: 6, bottom: 6, child: GifBadge()),
              if (!gif &&
                  !loadsGif &&
                  (playsOnSite ||
                      (media?.mime.startsWith('video/') ?? false) ||
                      (source?.mime.startsWith('video/') ?? false)))
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Color(0x88000000), shape: BoxShape.circle),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
                  ),
                ),
              if (duration != null)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      formatDuration(Duration(milliseconds: duration)),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      return playsOnSite
          ? shown
          : GestureDetector(
              key: const Key('link-picture'),
              onTap: () => MediaViewerScreen.openLinkPicture(context, link),
              child: shown,
            );
    }

    final host = linkHost(link.url);
    final Widget body;
    if (link.kind == LinkKind.file) {
      final mime = link.mime ?? '';
      body = Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: context.palette.onBubble.withValues(alpha: 0.2), shape: BoxShape.circle),
            child: Icon(
              mime.startsWith('video/')
                  ? Icons.movie_outlined
                  : mime.startsWith('audio/')
                  ? Icons.audiotrack_outlined
                  : mime.startsWith('image/')
                  ? Icons.image_outlined
                  : Icons.insert_drive_file_outlined,
              color: context.palette.onBubble,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _LinkText(
              title: link.title ?? host,
              detail: [?_fileType(link), if (link.size != null) formatBytes(link.size!), host].join(' · '),
            ),
          ),
        ],
      );
    } else if (link.kind == LinkKind.image || (media != null && link.mime != null)) {
      // The address is the image, video or GIF itself.
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          picture(aspect.clamp(0.6, 2.0)),
          const SizedBox(height: 4),
          _LinkText(detail: host),
        ],
      );
    } else {
      final small =
          thumb != null && link.kind == LinkKind.page && w != null && h != null && max(w, h) < LinkPreview.iconSize;
      final text = _LinkText(heading: link.site ?? host, title: link.title, detail: link.description);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (small)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: text),
                const SizedBox(width: 8),
                SizedBox(width: 56, child: picture(1)),
              ],
            )
          else ...[
            text,
            if (media != null || thumb != null || source != null) ...[
              const SizedBox(height: 6),
              picture(playsOnSite ? 16 / 9 : aspect.clamp(0.6, 2.0)),
            ],
          ],
        ],
      );
    }
    return GestureDetector(
      key: const Key('link-card'),
      onTap: () => confirmOpenLink(context, ref, Uri.parse(link.url)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: _width,
          margin: const EdgeInsets.only(top: 8),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.palette.onBubble.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(4),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: _color(link.color) ?? context.palette.onBubble.withAlpha(0xB3)),
                Expanded(
                  child: Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 7), child: body),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The site's colour, from `#rrggbb`.
  static Color? _color(String? color) =>
      color == null ? null : Color(0xFF000000 | int.parse(color.substring(1), radix: 16));

  /// "PDF" for a.pdf; "MP4" for an unnamed video/mp4.
  static String? _fileType(LinkPreview link) {
    final name = link.title ?? '';
    final dot = name.lastIndexOf('.');
    final type = dot > 0 && name.length - dot <= 6 ? name.substring(dot + 1) : link.mime?.split('/').last;
    return type == null || type.isEmpty ? null : type.toUpperCase();
  }
}

/// The lines of a link card: the site, the title and a detail.
class _LinkText extends StatelessWidget {
  const _LinkText({this.heading, this.title, this.detail});

  final String? heading;
  final String? title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (heading != null)
        EmojiText(
          heading!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12.5,
            color: context.palette.onBubble.withAlpha(0xB3),
          ),
        ),
      if (title != null)
        EmojiText(
          title!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, height: 1.3, color: context.palette.onBubble),
        ),
      if (detail != null)
        EmojiText(
          detail!,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, height: 1.3, color: context.palette.onBubble.withValues(alpha: 0.85)),
        ),
    ],
  );
}

/// The message a reply answers: who wrote it and how it starts. Tapping it
/// shows the original.
class _Quote extends StatelessWidget {
  const _Quote({required this.reply, required this.nameOf, required this.onDark, this.onTap});

  final ReplyRef reply;
  final String Function(String userId) nameOf;

  /// Inside a coloured text bubble (rather than on a white media card).
  final bool onDark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = onDark ? context.palette.onBubble : context.palette.textPrimary;
    return GestureDetector(
      key: const Key('reply-quote'),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: onDark ? context.palette.onBubble.withValues(alpha: 0.16) : context.palette.listBackground,
          borderRadius: BorderRadius.circular(4),
        ),
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                color: onDark ? context.palette.onBubble.withAlpha(0xB3) : context.palette.replyAccent,
              ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 10, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EmojiText(
                        nameOf(reply.from),
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: foreground),
                      ),
                      EmojiText(
                        reply.text ?? 'Message',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, height: 1.3, color: foreground.withValues(alpha: 0.85)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reactions under a message: each emoji with how many chose it. The user's
/// own are highlighted; tapping one adds it to the user's reactions, or takes
/// it back if it is theirs.
class _Reactions extends StatelessWidget {
  const _Reactions({required this.message, required this.me, required this.nameOf, this.onReact});

  final ChatMessage message;
  final String me;
  final String Function(String userId) nameOf;
  final void Function(String emoji, bool remove)? onReact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final MapEntry(key: emoji, value: users) in message.reactions.entries)
          Tooltip(
            message: [for (final user in users) user == me ? 'You' : nameOf(user)].join(', '),
            child: InkWell(
              key: ValueKey('reaction-$emoji'),
              borderRadius: BorderRadius.circular(12),
              onTap: onReact == null ? null : () => onReact!(emoji, users.contains(me)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: users.contains(me) ? context.palette.replyPanel : context.palette.listBackground,
                  border: Border.all(
                    color: users.contains(me) ? context.palette.replyAccent : context.palette.fieldBorder,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: emoji,
                        style: const TextStyle(fontSize: 15, fontFamilyFallback: emojiOnlyFallback),
                      ),
                      TextSpan(
                        text: ' ${users.length}',
                        style: TextStyle(fontSize: 12.5, color: context.palette.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A bubble without content: a message this device has no keys for (yet),
/// or one its sender deleted.
class _FadedBubble extends StatelessWidget {
  const _FadedBubble({
    super.key,
    required this.color,
    required this.showTail,
    required this.onLeft,
    required this.icon,
    required this.text,
    this.tooltip,
  });

  final Color color;
  final bool showTail;
  final bool onLeft;
  final IconData icon;
  final String text;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final faded = color.withValues(alpha: 0.55);
    final look = BubbleLook.of(context);
    final bubble = CustomPaint(
      painter: showTail ? _TailPainter.of(color: faded, onLeft: onLeft) : null,
      child: Container(
        decoration: BoxDecoration(color: faded, borderRadius: _Bubble._radius),
        padding: look.bubblePadding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: look.textSize, color: context.palette.onBubble),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: look.textStyle.copyWith(color: context.palette.onBubble, fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? bubble : Tooltip(message: tooltip, child: bubble);
  }
}

/// A sticker, as large as the game shows them: [image], its picture (see
/// [stickerImage]).
class _StickerBody extends StatelessWidget {
  const _StickerBody({required this.sticker, required this.image, this.onTap});

  final StickerRef sticker;
  final Widget image;
  final VoidCallback? onTap;

  static const size = 160.0;

  @override
  Widget build(BuildContext context) {
    final body = Semantics(
      label: 'Sticker',
      image: true,
      child: SizedBox.square(key: ValueKey('sticker-${sticker.key}'), dimension: size, child: image),
    );
    return onTap == null
        ? body
        : GestureDetector(
            onTap: onTap,
            child: MouseRegion(cursor: SystemMouseCursors.click, child: body),
          );
  }
}

/// A GIF message, playing; it opens in the viewer.
class _GifBody extends ConsumerWidget {
  const _GifBody({required this.envelope, required this.gif});

  final Envelope envelope;
  final GifRef gif;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = gif.width, h = gif.height;
    final aspect = (w != null && h != null && w > 0 && h > 0) ? (w / h).clamp(0.5, 2.5) : 1.0;
    // Until the setting is read, nothing goes to the provider.
    final autoLoad = switch (ref.watch(gifAutoLoadProvider)) {
      AsyncData(:final value) => value,
      AsyncError() => true,
      _ => false,
    };
    return GestureDetector(
      onTap: () => MediaViewerScreen.open(context, envelope),
      child: SizedBox(
        width: 240,
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GifView(gif: gif, autoLoad: autoLoad),
                const Positioned(left: 6, bottom: 6, child: GifBadge()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Image or video preview: the sender-made thumbnail, sized to the media's
/// aspect ratio; an animated image (up to [maxInlineAnimationBytes]) plays.
/// Tapping opens the full-screen viewer.
class _VisualMediaBody extends ConsumerWidget {
  const _VisualMediaBody({required this.envelope, required this.media, this.isVideo = false});

  final Envelope envelope;
  final MediaRef media;
  final bool isVideo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = media.width, h = media.height;
    final aspect = (w != null && h != null && w > 0 && h > 0) ? (w / h).clamp(0.6, 2.0) : 4 / 3;
    final thumb = media.thumb;
    final thumbBytes = thumb == null ? null : ref.watch(mediaBytesProvider(mediaKey(thumb))).value;
    final animated = !isVideo && _animatedImages.contains(media.mime) && media.size <= maxInlineAnimationBytes;
    final shown = (animated ? ref.watch(mediaBytesProvider(mediaKey(media))).value : null) ?? thumbBytes;
    return GestureDetector(
      onTap: () => MediaViewerScreen.open(context, envelope),
      child: SizedBox(
        width: 300,
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (shown != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(shown, fit: BoxFit.cover, gaplessPlayback: true),
                )
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.palette.listSelected,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              if (isVideo || shown == null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(color: Color(0x55000000), shape: BoxShape.circle),
                    child: Icon(
                      isVideo ? Icons.play_arrow_rounded : Icons.image_outlined,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              if (animated && media.mime == 'image/gif') const Positioned(left: 8, bottom: 8, child: GifBadge()),
              if (isVideo && media.durationMs != null)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      formatDuration(Duration(milliseconds: media.durationMs!)),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Images that may be animated: shown in full rather than as a thumbnail.
const _animatedImages = {'image/gif', 'image/webp'};

/// File name and size; tapping downloads the file (with progress) and saves
/// it. Received files are never opened automatically.
class _FileBody extends ConsumerStatefulWidget {
  const _FileBody({required this.envelope, required this.media});

  final Envelope envelope;
  final MediaRef media;

  @override
  ConsumerState<_FileBody> createState() => _FileBodyState();
}

class _FileBodyState extends ConsumerState<_FileBody> {
  double? _progress;
  var _downloading = false;

  Future<void> _save() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    await saveMedia(context, ref, widget.media, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
    if (mounted) {
      setState(() {
        _downloading = false;
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    // Audio (and video sent as a file) plays in the viewer, which saves too.
    final playable = media.mime.startsWith('audio/') || media.mime.startsWith('video/');
    final duration = media.durationMs;
    return InkWell(
      onTap: playable ? () => MediaViewerScreen.open(context, widget.envelope) : _save,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: context.palette.replyAccent, shape: BoxShape.circle),
              child: _downloading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        value: _progress,
                        strokeWidth: 2.5,
                        color: context.palette.onAccent,
                      ),
                    )
                  : Icon(playable ? Icons.play_arrow_rounded : Icons.download, color: context.palette.onAccent),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    media.name ?? 'File',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.palette.textPrimary, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (duration != null) formatDuration(Duration(milliseconds: duration)),
                      formatBytes(media.size),
                    ].join(' · '),
                    style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.message, required this.showTime, this.onRetry});

  final ChatMessage message;
  final bool showTime;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    switch (message.state) {
      case DeliveryState.pending:
        return Icon(Icons.schedule, size: 14, color: context.palette.textMuted);
      case DeliveryState.failed:
        return IconButton(
          tooltip: 'Retry',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.error, size: 18, color: context.palette.failed),
          onPressed: onRetry,
        );
      case DeliveryState.sent:
        final label = [if (message.edited) 'edited', if (showTime) formatClock(message.sentAt)].join(' ');
        if (label.isEmpty) return const SizedBox.shrink();
        return Text(label, style: TextStyle(fontSize: 11, color: context.palette.textMuted));
    }
  }
}

/// Small triangle next to the top of the first bubble in a group, pointing at
/// the avatar (incoming) or the screen edge (outgoing).
class _TailPainter extends CustomPainter {
  const _TailPainter({required this.color, required this.onLeft}) : top = 10;

  /// The tail of a message's first bubble: on someone else's, beside their
  /// picture, a little higher, so that it points at about its middle.
  const _TailPainter.of({required this.color, required this.onLeft}) : top = onLeft ? 7 : 10;

  final Color color;
  final bool onLeft;

  /// How far below the bubble's top the tail starts.
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    const depth = 6.0, height = 9.0;
    final path = Path();
    if (onLeft) {
      path
        ..moveTo(1, top)
        ..lineTo(-depth, top + height / 2)
        ..lineTo(1, top + height);
    } else {
      path
        ..moveTo(size.width - 1, top)
        ..lineTo(size.width + depth, top + height / 2)
        ..lineTo(size.width - 1, top + height);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color || old.onLeft != onLeft || old.top != top;
}
