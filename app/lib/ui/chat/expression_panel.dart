import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../theme/hanashi_theme.dart';

/// How the emoji picker looks, in the composer and when reacting.
/// [backspace] adds a key that deletes from the message being written.
Config emojiPickerConfig(HanashiPalette palette, {required double height, bool backspace = false}) => Config(
  height: height,
  emojiViewConfig: EmojiViewConfig(
    columns: 8,
    emojiSizeMax: 30,
    backgroundColor: palette.surface,
    noRecents: Text('Emoji you use show up here', style: TextStyle(fontSize: 15, color: palette.textMuted)),
  ),
  categoryViewConfig: CategoryViewConfig(
    backgroundColor: palette.listBackground,
    indicatorColor: palette.replyAccent,
    iconColorSelected: palette.replyAccent,
    iconColor: palette.textMuted,
    backspaceColor: palette.replyAccent,
  ),
  bottomActionBarConfig: BottomActionBarConfig(
    showBackspaceButton: backspace,
    backgroundColor: palette.listBackground,
    buttonColor: palette.listBackground,
    buttonIconColor: palette.textSecondary,
  ),
  skinToneConfig: SkinToneConfig(dialogBackgroundColor: palette.surface),
  searchViewConfig: SearchViewConfig(backgroundColor: palette.listBackground, buttonIconColor: palette.textMuted),
);

/// Where a tab's choices go: emoji into the message being written, GIFs and
/// stickers out as messages of their own.
class ExpressionTarget {
  const ExpressionTarget({required this.text, this.conversationId, this.onGif, this.onSticker});

  /// The composer's text, edited at the cursor.
  final TextEditingController text;

  /// The chat being written in (a group's custom emojis show for it).
  final String? conversationId;

  /// Sends a GIF; without it, there is no GIF tab.
  final ValueChanged<GifRef>? onGif;

  /// Sends a sticker; without it, there is no sticker tab.
  final ValueChanged<StickerRef>? onSticker;
}

/// One tab of the [ExpressionPanel]: a kind of thing to put into a chat.
class ExpressionTab {
  const ExpressionTab({required this.id, required this.icon, required this.label, required this.build});

  final String id;
  final IconData icon;
  final String label;
  final Widget Function(BuildContext context, ExpressionTarget target, double height) build;
}

/// Emoji, inserted where the cursor is.
final emojiTab = ExpressionTab(
  id: 'emoji',
  icon: Icons.emoji_emotions_outlined,
  label: 'Emoji',
  build: (context, target, height) => EmojiPicker(
    key: const Key('composer-emoji-picker'),
    textEditingController: target.text,
    config: emojiPickerConfig(context.palette, height: height, backspace: true),
  ),
);

/// What the composer can open under the input: emoji, GIFs and stickers, as
/// [tabs]. Their row shows once there are two.
class ExpressionPanel extends StatefulWidget {
  ExpressionPanel({super.key, required this.target, List<ExpressionTab>? tabs, this.height = 300})
    : tabs = tabs ?? [emojiTab];

  final ExpressionTarget target;
  final List<ExpressionTab> tabs;
  final double height;

  @override
  State<ExpressionPanel> createState() => _ExpressionPanelState();
}

class _ExpressionPanelState extends State<ExpressionPanel> {
  var _selected = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    final tab = tabs[_selected.clamp(0, tabs.length - 1)];
    return Material(
      key: const Key('expression-panel'),
      color: context.palette.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tab.build(context, widget.target, widget.height),
          if (tabs.length > 1)
            Container(
              color: context.palette.listBackground,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final (i, t) in tabs.indexed)
                    IconButton(
                      key: ValueKey('expression-tab-${t.id}'),
                      tooltip: t.label,
                      isSelected: i == _selected,
                      color: context.palette.textMuted,
                      selectedIcon: Icon(t.icon, color: context.palette.replyAccent),
                      icon: Icon(t.icon),
                      onPressed: () => setState(() => _selected = i),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
