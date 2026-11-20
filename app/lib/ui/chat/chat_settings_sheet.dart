import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/format.dart';

Future<void> showChatSettings(BuildContext context, String conversationId) => showDialog<void>(
  context: context,
  builder: (_) => ChatSettingsDialog(conversationId: conversationId),
);

/// How long a chat can be muted for; [Duration.zero]: until the user
/// unmutes it (a null choice would be none at all).
const muteDurations = <(String, Duration)>[
  ('For 1 hour', Duration(hours: 1)),
  ('For 8 hours', Duration(hours: 8)),
  ('For 1 day', Duration(days: 1)),
  ('For 1 week', Duration(days: 7)),
  ('Until I unmute it', Duration.zero),
];

/// The widget key of a choice from [muteDurations].
String muteKey(Duration duration) => 'chat-mute-${duration == Duration.zero ? 'forever' : duration.inMinutes}';

/// [settings] muted for [duration] from [now] (see [muteDurations]).
ChatSettings mutedFor(ChatSettings settings, Duration duration, DateTime now) => duration == Duration.zero
    ? settings.edit(notify: ChatNotify.off, mutedUntil: null, sound: settings.sound)
    : settings.edit(
        notify: settings.notify == ChatNotify.off ? null : settings.notify,
        mutedUntil: now.add(duration).millisecondsSinceEpoch,
        sound: settings.sound,
      );

/// [settings] not muted, otherwise as they were.
ChatSettings unmuted(ChatSettings settings) => settings.edit(
  notify: settings.notify == ChatNotify.off ? null : settings.notify,
  mutedUntil: null,
  sound: settings.sound,
);

/// One chat's own settings, the same on all of the user's devices (see
/// [ChatSettings]), in sections: so far, its notifications. Settings added
/// later get sections of their own here.
class ChatSettingsDialog extends ConsumerStatefulWidget {
  const ChatSettingsDialog({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatSettingsDialog> createState() => _ChatSettingsDialogState();
}

class _ChatSettingsDialogState extends ConsumerState<ChatSettingsDialog> {
  var _busy = false;
  String? _error;

  Future<void> _save(ChatSettings settings) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(chatRepositoryProvider).setChatSettings(widget.conversationId, settings);
    } on ApiException catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  /// "Muted until 19:30", "Muted until 10/29, 19:30", or "Muted".
  static String _mutedText(ChatSettings settings, DateTime now) {
    final until = settings.mutedUntil;
    if (settings.notify == ChatNotify.off || until == null) return 'Muted';
    final time = DateTime.fromMillisecondsSinceEpoch(until);
    final day = formatListTime(time, now: now);
    final clock = formatClock(time);
    return day == clock ? 'Muted until $clock' : 'Muted until $day, $clock';
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(chatSettingsOfProvider(widget.conversationId));
    final title = ref.watch(conversationProvider(widget.conversationId))?.title;
    final now = ref.watch(clockProvider)();
    final muted = settings.mutedAt(now);
    final notify = settings.notify == ChatNotify.off ? null : settings.notify;
    final sections = [
      _Section(
        title: 'Notifications',
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              muted ? Icons.notifications_off_outlined : Icons.notifications_active_outlined,
              color: context.palette.textSecondary,
            ),
            title: Text(muted ? _mutedText(settings, now) : 'Not muted', key: const Key('chat-muted')),
            trailing: muted
                ? TextButton(
                    key: const Key('chat-unmute'),
                    onPressed: _busy ? null : () => _save(unmuted(settings)),
                    child: const Text('Unmute'),
                  )
                : PopupMenuButton<Duration>(
                    key: const Key('chat-mute'),
                    enabled: !_busy,
                    tooltip: 'Mute',
                    itemBuilder: (_) => [
                      for (final (label, duration) in muteDurations)
                        PopupMenuItem(key: Key(muteKey(duration)), value: duration, child: Text(label)),
                    ],
                    onSelected: (duration) => _save(mutedFor(settings, duration, now)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(
                        'Mute',
                        style: TextStyle(color: context.palette.replyAccent, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<ChatNotify?>(
            // Rebuilt when another device changes it.
            key: ValueKey('chat-notify-$notify'),
            initialValue: notify,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Notify about'),
            items: const [
              DropdownMenuItem(value: null, child: Text('As in your settings')),
              DropdownMenuItem(value: ChatNotify.all, child: Text('Every message')),
              DropdownMenuItem(value: ChatNotify.replies, child: Text('Replies and reactions to you')),
            ],
            onChanged: _busy || settings.notify == ChatNotify.off
                ? null
                : (value) =>
                      _save(settings.edit(notify: value, mutedUntil: settings.mutedUntil, sound: settings.sound)),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<bool?>(
            key: ValueKey('chat-sound-${settings.sound}'),
            initialValue: settings.sound,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Sound'),
            items: const [
              DropdownMenuItem(value: null, child: Text('As in your settings')),
              DropdownMenuItem(value: true, child: Text('With a sound')),
              DropdownMenuItem(value: false, child: Text('Silent')),
            ],
            onChanged: _busy
                ? null
                : (value) =>
                      _save(settings.edit(notify: settings.notify, mutedUntil: settings.mutedUntil, sound: value)),
          ),
        ],
      ),
    ];

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Chat settings'),
          if (title != null) Text(title, style: TextStyle(fontSize: 14, color: context.palette.textSecondary)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, section) in sections.indexed) ...[if (i > 0) const SizedBox(height: 20), section],
              const SizedBox(height: 12),
              Text(
                'These settings are end-to-end encrypted and the same on all your devices.',
                style: TextStyle(fontSize: 12.5, color: context.palette.textMuted),
              ),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: context.palette.failed)),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

/// One kind of settings, under a heading.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          title,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.palette.replyAccent),
        ),
      ),
      ...children,
    ],
  );
}
