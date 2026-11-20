import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../chat/bubble_look.dart';
import '../chat/message_bubble.dart';
import '../theme/hanashi_theme.dart';

/// How chat bubbles look on this device: a sample of the chat, which follows
/// the sliders for text size, line spacing and padding as they move, and a
/// way back to the default.
class ChatLookSettings extends ConsumerStatefulWidget {
  const ChatLookSettings({super.key});

  @override
  ConsumerState<ChatLookSettings> createState() => _ChatLookSettingsState();
}

class _ChatLookSettingsState extends ConsumerState<ChatLookSettings> {
  /// While a slider moves: shown, not stored yet.
  BubbleLook? _draft;

  static final _time = DateTime(2026, 3, 24, 18, 30);
  static final _theirs = ChatMessage(
    envelope: Envelope.text(
      conv: 'preview',
      from: 'kumiko@hanashi',
      text: 'Sota, there is a new cafe near the station. Shall we go after class?',
      now: _time,
    ),
  );
  static final _mine = ChatMessage(
    envelope: Envelope.text(conv: 'preview', from: 'sota@hanashi', text: 'Sounds good! See you there.', now: _time),
  );

  Future<void> _save(BubbleLook look) async {
    await ref.read(bubbleLookProvider.notifier).set(look);
    if (mounted) setState(() => _draft = null);
  }

  @override
  Widget build(BuildContext context) {
    final look = _draft ?? ref.watch(bubbleLookProvider).value ?? const BubbleLook();

    Widget slider({
      required String key,
      required IconData icon,
      required String label,
      required double value,
      required String shown,
      required ({double min, double max, double step}) range,
      required BubbleLook Function(double value) apply,
    }) => ListTile(
      leading: Icon(icon, color: context.palette.textSecondary),
      title: Text(label),
      trailing: Text(shown, style: TextStyle(color: context.palette.textSecondary)),
      subtitle: Slider(
        key: Key(key),
        value: value,
        min: range.min,
        max: range.max,
        divisions: ((range.max - range.min) / range.step).round(),
        label: shown,
        onChanged: (v) => setState(() => _draft = apply(BubbleLook.fit(v, range)!)),
        onChangeEnd: (v) => _save(apply(BubbleLook.fit(v, range)!)),
      ),
    );

    return Column(
      children: [
        Container(
          key: const Key('chat-look-preview'),
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          padding: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: context.palette.chatBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.palette.divider),
          ),
          // A sample, not a chat: nothing in it reacts.
          child: IgnorePointer(
            child: BubbleLookScope(
              look: look,
              child: Column(
                children: [
                  MessageBubble(message: _theirs, isMine: false, senderName: 'Kumiko'),
                  MessageBubble(message: _mine, isMine: true, senderName: 'Sota'),
                ],
              ),
            ),
          ),
        ),
        slider(
          key: 'chat-text-size',
          icon: Icons.format_size,
          label: 'Text size',
          value: look.textSize,
          shown: look.textSize.round().toString(),
          range: BubbleLook.textSizes,
          apply: (v) => look.copyWith(textSize: v),
        ),
        slider(
          key: 'chat-line-spacing',
          icon: Icons.format_line_spacing,
          label: 'Line spacing',
          value: look.lineSpacing,
          shown: look.lineSpacing.toStringAsFixed(2),
          range: BubbleLook.lineSpacings,
          apply: (v) => look.copyWith(lineSpacing: v),
        ),
        slider(
          key: 'chat-padding',
          icon: Icons.padding_outlined,
          label: 'Bubble padding',
          value: look.padding,
          shown: look.padding.round().toString(),
          range: BubbleLook.paddings,
          apply: (v) => look.copyWith(padding: v),
        ),
        if (!look.isDefault)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                key: const Key('chat-look-reset'),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset'),
                onPressed: () => _save(const BubbleLook()),
              ),
            ),
          ),
      ],
    );
  }
}
