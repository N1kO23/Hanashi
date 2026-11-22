import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../emojis/custom_emoji_image.dart';
import '../theme/hanashi_theme.dart';

/// One emoji: with a skin tone, joined (👨‍👩‍👧), a flag or a keycap (1️⃣).
/// Not a character that is text unless asked to be an emoji (©, ❤ without
/// U+FE0F), nor a plain digit, # or *.
const _oneEmoji =
    r'[#*0-9]\uFE0F?\u20E3'
    r'|\p{Regional_Indicator}{2}'
    r'|(?:\p{Emoji_Presentation}|\p{Extended_Pictographic}(?=[\uFE0F\p{Emoji_Modifier}]))'
    r'[\uFE0F\p{Emoji_Modifier}\u{E0020}-\u{E007F}]*'
    r'(?:\u200D\p{Extended_Pictographic}[\uFE0F\p{Emoji_Modifier}\u{E0020}-\u{E007F}]*)*';
final _emoji = RegExp(_oneEmoji, unicode: true);
final _emojiRun = RegExp('(?:$_oneEmoji)+', unicode: true);

/// How many emoji [text] is, if it is nothing else (but spaces). `:name:` of
/// one of the [custom] ones counts as one.
int? emojiOnlyCount(String text, {Set<String> custom = const {}}) {
  var count = 0;
  final rest = StringBuffer();
  var at = 0;
  for (final found in CustomEmoji.find(text, custom.contains)) {
    rest
      ..write(text.substring(at, found.start))
      ..write(' ');
    count++;
    at = found.end;
  }
  rest.write(text.substring(at));
  final left = rest.toString().replaceAllMapped(_emoji, (_) {
    count++;
    return '';
  });
  return count > 0 && left.trim().isEmpty ? count : null;
}

/// How much larger than the text around it a custom emoji is.
const customEmojiScale = 1.25;

/// Emoji in the colour emoji font. Ordinary text falls back to fonts with
/// black-and-white emoji first (DejaVu Sans, on Linux); see
/// [emojiOnlyFallback] for why the emoji font is not among them.
const emojiStyle = TextStyle(fontFamily: 'Noto Color Emoji', fontFamilyFallback: emojiOnlyFallback);

/// [text] with its emoji in [emojiStyle]; null if it has none.
TextSpan? emojiSpan(String text, {TextStyle? style}) =>
    _emojiRun.hasMatch(text) ? TextSpan(style: style, children: _runs(text)) : null;

/// [text] in runs of emoji (in [emojiStyle]) and the rest; all of them in
/// [style] and tappable with [recognizer], if given.
List<TextSpan> _runs(String text, {TextStyle? style, GestureRecognizer? recognizer}) {
  final spans = <TextSpan>[];
  var at = 0;
  for (final match in _emojiRun.allMatches(text)) {
    if (match.start > at) {
      spans.add(TextSpan(text: text.substring(at, match.start), style: style, recognizer: recognizer));
    }
    spans.add(TextSpan(text: match[0], style: style?.merge(emojiStyle) ?? emojiStyle, recognizer: recognizer));
    at = match.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: style, recognizer: recognizer));
  return spans;
}

/// A [Text] of what someone wrote, its emoji in colour, and `:name:` of one
/// of its custom [emojis] as that one's picture. With [onLink], web addresses
/// in it are underlined (and show no custom emoji), and tapping one calls
/// [onLink]; with [onEmoji], tapping a custom emoji calls that.
class EmojiText extends StatefulWidget {
  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.onLink,
    this.emojis = const {},
    this.onEmoji,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final ValueChanged<Uri>? onLink;

  /// Custom emojis, by name.
  final Map<String, MediaRef> emojis;
  final void Function(String name, MediaRef picture)? onEmoji;

  @override
  State<EmojiText> createState() => _EmojiTextState();
}

class _EmojiTextState extends State<EmojiText> {
  static const _linkStyle = TextStyle(decoration: TextDecoration.underline);

  /// The links in the text, each with its own recognizer (kept across
  /// rebuilds, so that a tap in progress is not lost).
  var _links = const <(TextLink, TapGestureRecognizer)>[];

  @override
  void initState() {
    super.initState();
    _findLinks();
  }

  @override
  void didUpdateWidget(EmojiText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || (old.onLink == null) != (widget.onLink == null)) _findLinks();
  }

  @override
  void dispose() {
    _forgetLinks();
    super.dispose();
  }

  void _findLinks() {
    _forgetLinks();
    if (widget.onLink == null) return;
    _links = [
      for (final link in findLinks(widget.text))
        (link, TapGestureRecognizer()..onTap = () => widget.onLink?.call(link.uri)),
    ];
  }

  WidgetSpan _customEmoji(String name, double size) {
    final picture = widget.emojis[name]!;
    final onEmoji = widget.onEmoji;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Tooltip(
        message: ':$name:',
        // On a mouse only: a long press is the message's.
        triggerMode: TooltipTriggerMode.manual,
        child: MouseRegion(
          cursor: onEmoji == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: GestureDetector(
            // Also before its picture is here.
            behavior: HitTestBehavior.opaque,
            onTap: onEmoji == null ? null : () => onEmoji(name, picture),
            child: CustomEmojiImage(key: ValueKey('custom-emoji-$name'), name: name, picture: picture, size: size),
          ),
        ),
      ),
    );
  }

  /// Where the text shows one of its custom emojis; none in a link, which
  /// reads as it is.
  List<({int start, int end, String name})> _customIn(String text) => [
    for (final found in CustomEmoji.find(text, widget.emojis.containsKey))
      if (!_links.any((l) => found.start < l.$1.end && l.$1.start < found.end)) found,
  ];

  void _forgetLinks() {
    for (final (_, recognizer) in _links) {
      recognizer.dispose();
    }
    _links = const [];
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final emojis = widget.emojis;
    final custom = emojis.isEmpty ? const <({int start, int end, String name})>[] : _customIn(text);
    if (_links.isEmpty && custom.isEmpty) {
      final span = emojiSpan(text);
      return span == null
          ? Text(
              text,
              style: widget.style,
              maxLines: widget.maxLines,
              overflow: widget.overflow,
              textAlign: widget.textAlign,
            )
          : Text.rich(
              span,
              style: widget.style,
              maxLines: widget.maxLines,
              overflow: widget.overflow,
              textAlign: widget.textAlign,
            );
    }
    final size = (DefaultTextStyle.of(context).style.merge(widget.style).fontSize ?? 14) * customEmojiScale;
    // The text from [start] to [end], none of it a link, with its custom emojis.
    var next = 0;
    List<InlineSpan> plain(int start, int end) {
      final spans = <InlineSpan>[];
      var at = start;
      for (; next < custom.length && custom[next].end <= end; next++) {
        final (start: from, end: to, :name) = custom[next];
        spans
          ..addAll(_runs(text.substring(at, from)))
          ..add(_customEmoji(name, size));
        at = to;
      }
      return spans..addAll(_runs(text.substring(at, end)));
    }

    final spans = <InlineSpan>[];
    var at = 0;
    for (final (link, recognizer) in _links) {
      spans
        ..addAll(plain(at, link.start))
        ..addAll(_runs(text.substring(link.start, link.end), style: _linkStyle, recognizer: recognizer));
      at = link.end;
    }
    spans.addAll(plain(at, text.length));
    return Text.rich(
      TextSpan(children: spans),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
  }
}

/// A text field's controller that shows the emoji typed in colour.
class EmojiEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    TextSpan part(String text, [TextStyle? style]) =>
        emojiSpan(text, style: style) ?? TextSpan(text: text, style: style);
    if (!withComposing || !value.isComposingRangeValid) return part(text, style);
    // Being typed with an input method: underlined, as by default.
    final composing = value.composing;
    return TextSpan(
      style: style,
      children: [
        part(composing.textBefore(text)),
        part(composing.textInside(text), const TextStyle(decoration: TextDecoration.underline)),
        part(composing.textAfter(text)),
      ],
    );
  }
}
