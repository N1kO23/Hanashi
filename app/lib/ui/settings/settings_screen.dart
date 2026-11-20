import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../calls/call_connection.dart';
import '../../calls/call_controller.dart';
import '../../calls/push_to_talk.dart';
import '../../calls/voice_gate.dart';
import '../../data/models.dart';
import '../../data/remote/api_client.dart';
import '../../data/server_chat_repository.dart';
import '../../diagnostics/app_log.dart';
import '../../e2ee/secure_store.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../profile/edit_profile_dialog.dart';
import '../profile/profile_card.dart';
import '../widgets/format.dart';
import '../widgets/list_header.dart';
import '../widgets/presence.dart';
import 'appearance_settings.dart';
import 'log_view.dart';
import 'chat_look_settings.dart';
import 'notification_settings.dart';

/// Account, encryption, notifications, appearance, signed-in devices and
/// sign-out.
class SettingsPane extends ConsumerWidget {
  const SettingsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    final me = ref.watch(chatRepositoryProvider).me;
    final connection = ref.watch(connectionProvider).value;
    final problem = ref.watch(connectionProblemProvider).value;
    final devices = ref.watch(devicesProvider);

    return Material(
      color: context.palette.listBackground,
      child: ListView(
        children: [
          const ListHeader(title: 'Account'),
          if (me.isNotEmpty)
            _ProfileTile(userId: me, fallbackName: account?.displayName ?? me.split('@').first, server: account?.serverUrl),
          if (me.isNotEmpty) _StatusTile(userId: me),
          ListTile(
            leading: Icon(
              Icons.circle,
              size: 14,
              color: connection == ConnectionStatus.online ? context.palette.success : context.palette.textSecondary,
            ),
            title: Text(switch (connection) {
              ConnectionStatus.online => 'Connected',
              ConnectionStatus.offline => 'Offline - messages are sent when the connection returns',
              ConnectionStatus.updateRequired => 'Update needed - messages are sent after updating',
              _ => 'Connecting...',
            }),
            subtitle: connection != ConnectionStatus.online && problem != null
                ? Text(problem, key: const Key('connection-problem'))
                : null,
          ),
          const ListHeader(title: 'Encryption'),
          const _EncryptionTiles(),
          const ListHeader(title: 'Notifications'),
          const NotificationSettings(),
          const ListHeader(title: 'Appearance'),
          const AppearanceSettings(),
          const ListHeader(title: 'Chat text'),
          const ChatLookSettings(),
          const ListHeader(title: 'GIFs'),
          const _GifSettings(),
          const ListHeader(title: 'Links'),
          const _LinkSettings(),
          const _LinkSourceSettings(),
          // Where this device gates its voice, and the server has calls.
          if ((ref.watch(callsAvailableProvider).value ?? false) &&
              (ref.watch(voiceGateAvailableProvider).value ?? false)) ...[
            const ListHeader(title: 'Voice'),
            const _VoiceSettings(),
          ],
          // Not on iPhones yet; only where the server has video.
          if (!Platform.isIOS && (ref.watch(videoAvailableProvider).value ?? false)) ...[
            const ListHeader(title: 'Screen sharing'),
            const _ShareQualitySettings(),
          ],
          const ListHeader(title: 'Privacy'),
          const _TypingSettings(),
          const ListHeader(title: 'Diagnostics'),
          const _LogSettings(),
          ListHeader(
            title: 'Signed-in devices',
            trailing: ListHeaderButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(devicesProvider),
              child: Icon(Icons.refresh, size: 20, color: context.palette.incomingBubble),
            ),
          ),
          ...devices.when(
            loading: () => const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [ListTile(title: Text('Could not load devices: $e'))],
            data: (list) => [for (final d in list) _DeviceTile(device: d)],
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: const Text('Sign out of this device'),
              style: OutlinedButton.styleFrom(foregroundColor: context.palette.failed),
              onPressed: () async {
                final confirmed = await _confirm(
                  context,
                  'Sign out?',
                  'Chats stay on the server and your other devices. This device forgets them until you sign in again.',
                  'Sign out',
                );
                if (!confirmed) return;
                final repository = ref.read(chatRepositoryProvider);
                // The last messages' keys belong in the backup before the session ends.
                if (repository is ServerChatRepository) await repository.flushKeyBackup();
                await ref.read(accountProvider.notifier).signOut();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether GIFs from KLIPY load in chats by themselves.
class _GifSettings extends ConsumerWidget {
  const _GifSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoLoad = ref.watch(gifAutoLoadProvider).value;
    return SwitchListTile(
      key: const Key('gifs-autoload'),
      secondary: Icon(Icons.gif_box_outlined, color: context.palette.textSecondary),
      title: const Text('Load GIFs from KLIPY automatically'),
      subtitle: const Text('KLIPY sees your IP address when a GIF loads. Off: tap a GIF to load it.'),
      value: autoLoad ?? true,
      onChanged: autoLoad == null ? null : (value) => ref.read(gifAutoLoadProvider.notifier).set(value),
    );
  }
}

/// How this device shares its screen in calls: how big, how smooth, and how
/// much upload it may take.
class _ShareQualitySettings extends ConsumerWidget {
  const _ShareQualitySettings();

  static String heightName(int? height) => height == null ? 'As the screen is' : '${height}p';

  static String bitrateName(int? bitrate) => bitrate == null ? 'Automatic' : '${_megabits(bitrate)} Mbit/s';

  /// 1, 2.5, 8.8.
  static String _megabits(int bitrate) {
    final megabits = bitrate / 1000000;
    return megabits == megabits.roundToDouble() ? '${megabits.round()}' : megabits.toStringAsFixed(1);
  }

  /// One of [options] (null among them, perhaps, [unset] in its key), or
  /// nothing if dismissed.
  static Future<(T,)?> _choose<T>(
    BuildContext context, {
    required String title,
    required String key,
    required List<T> options,
    required T now,
    required String Function(T) name,
    String unset = 'screen',
  }) => showDialog<(T,)>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final option in options)
          SimpleDialogOption(
            key: Key('$key-${option ?? unset}'),
            onPressed: () => Navigator.pop(context, (option,)),
            child: Text(option == now ? '${name(option)} (now)' : name(option)),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(shareQualityProvider).value;
    final controller = ref.read(shareQualityProvider.notifier);
    final height = quality?.height ?? 1080;
    final fps = quality?.fps ?? 15;
    final maxBitrate = quality?.maxBitrate;
    final automatic = _megabits(ShareQuality.bitrate(height * 16 ~/ 9, height, fps));
    final screen = quality?.height == null ? ' for a 1080p screen, more for a bigger one' : '';
    final upload = maxBitrate == null
        ? 'up to about $automatic Mbit/s of your upload, as the resolution and frame rate need$screen'
        : 'up to ${bitrateName(maxBitrate)} of your upload';
    return Column(
      children: [
        ListTile(
          key: const Key('share-resolution'),
          leading: Icon(Icons.aspect_ratio, color: context.palette.textSecondary),
          title: const Text('Resolution'),
          subtitle: Text(heightName(quality?.height)),
          enabled: quality != null,
          onTap: () async {
            final choice = await _choose<int?>(
              context,
              title: 'Resolution',
              key: 'share-resolution',
              options: ShareQuality.heights,
              now: quality?.height,
              name: heightName,
            );
            if (choice != null) await controller.setHeight(choice.$1);
          },
        ),
        ListTile(
          key: const Key('share-fps'),
          leading: Icon(Icons.speed, color: context.palette.textSecondary),
          title: const Text('Frame rate'),
          subtitle: Text('$fps frames a second'),
          enabled: quality != null,
          onTap: () async {
            final choice = await _choose<int>(
              context,
              title: 'Frame rate',
              key: 'share-fps',
              options: ShareQualityController.rates,
              now: fps,
              name: (rate) => '$rate frames a second',
            );
            if (choice != null) await controller.setFps(choice.$1);
          },
        ),
        ListTile(
          key: const Key('share-bitrate'),
          leading: Icon(Icons.upload, color: context.palette.textSecondary),
          title: const Text('Maximum bitrate'),
          subtitle: Text(bitrateName(maxBitrate)),
          enabled: quality != null,
          onTap: () async {
            final choice = await _choose<int?>(
              context,
              title: 'Maximum bitrate',
              key: 'share-bitrate',
              options: ShareQuality.bitrates,
              now: maxBitrate,
              name: bitrateName,
              unset: 'auto',
            );
            if (choice != null) await controller.setMaxBitrate(choice.$1);
          },
        ),
        Padding(
          key: const Key('share-quality-note'),
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Text(
            'From your next share. It takes $upload. More keeps motion sharper, where your upload has it. '
            '30 or 60 frames a second suit motion (games, videos); 5 or 15 keep text sharp with less upload.',
            style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// When the microphone lets the voice out (its voice gate), with a meter:
/// live during a call, or while the microphone is tried here.
class _VoiceSettings extends ConsumerStatefulWidget {
  const _VoiceSettings();

  @override
  ConsumerState<_VoiceSettings> createState() => _VoiceSettingsState();
}

class _VoiceSettingsState extends ConsumerState<_VoiceSettings> {
  late final VoiceGate _gate = ref.read(voiceGateProvider);
  StreamSubscription<VoiceLevel>? _levels;
  VoiceLevel? _level;
  var _testing = false;
  var _starting = false;

  /// The threshold while it is dragged, before it is kept.
  double? _dragged;

  @override
  void initState() {
    super.initState();
    _levels = _gate.levels.listen((level) {
      if (mounted) setState(() => _level = level);
    });
  }

  @override
  void dispose() {
    unawaited(_levels?.cancel());
    if (_testing) unawaited(_gate.stopTest());
    super.dispose();
  }

  Future<void> _toggleTest() async {
    if (_testing) {
      setState(() => _testing = false);
      await _gate.stopTest();
      return;
    }
    setState(() {
      _starting = true;
      _level = null;
    });
    try {
      await _gate.startTest();
      if (mounted) {
        setState(() => _testing = true);
      } else {
        await _gate.stopTest();
      }
    } on MicrophoneTestException catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(voiceGateSettingsProvider).value;
    final controller = ref.read(voiceGateSettingsProvider.notifier);
    final inCall = ref.watch(callControllerProvider.select((view) => view.phase.inCall));
    // A call takes the microphone over from a test (and ends it).
    ref.listen(callControllerProvider.select((view) => view.phase.inCall), (_, inCall) {
      if (inCall && _testing) setState(() => _testing = false);
    });
    final pushToTalk = settings?.pushToTalk ?? false;
    final automatic = settings?.automatic ?? true;
    final threshold = _dragged ?? settings?.threshold ?? const VoiceGateSettings().threshold;
    final level = inCall || _testing ? _level : null;
    // A threshold to set or to see: not for push to talk.
    final settable = !pushToTalk && !automatic && settings != null;
    const range = VoiceGateSettings.highest - VoiceGateSettings.lowest;
    final track = _MeterTrack(
      palette: context.palette,
      level: level == null ? null : ((level.level - VoiceGateSettings.lowest) / range).clamp(0.0, 1.0),
      open: level?.open ?? false,
    );
    final shown = pushToTalk
        ? null
        : automatic
        ? level?.threshold
        : threshold;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedButton<bool>(
            key: const Key('voice-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('When you speak'), icon: Icon(Icons.graphic_eq)),
              ButtonSegment(value: true, label: Text('Push to talk'), icon: Icon(Icons.record_voice_over)),
            ],
            selected: {pushToTalk},
            onSelectionChanged: settings == null ? null : (chosen) => controller.setPushToTalk(chosen.first),
          ),
        ),
        if (!pushToTalk)
          SwitchListTile(
            key: const Key('voice-automatic'),
            secondary: Icon(Icons.graphic_eq, color: context.palette.textSecondary),
            title: const Text('Set the sensitivity automatically'),
            subtitle: const Text("Your voice goes out once it's clearly louder than the sounds around you"),
            value: automatic,
            onChanged: settings == null ? null : controller.setAutomatic,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 10,
                    trackShape: track,
                    thumbColor: context.palette.incomingBubble,
                    disabledThumbColor: context.palette.textMuted,
                    // Automatic, the threshold shows only once there is a
                    // level to hold to it; push to talk has none.
                    thumbShape: pushToTalk || automatic && level == null ? SliderComponentShape.noThumb : null,
                    overlayColor: context.palette.incomingBubble.withValues(alpha: 0.12),
                    valueIndicatorColor: context.palette.incomingBubble,
                  ),
                  child: Slider(
                    key: Key(settable ? 'voice-threshold' : 'voice-meter'),
                    value:
                        (pushToTalk
                                ? VoiceGateSettings.lowest
                                : automatic
                                ? level?.threshold ?? VoiceGateSettings.lowest
                                : threshold)
                            .clamp(VoiceGateSettings.lowest, VoiceGateSettings.highest),
                    min: VoiceGateSettings.lowest,
                    max: VoiceGateSettings.highest,
                    divisions: range.round(),
                    label: '${threshold.round()} dB',
                    semanticFormatterCallback: (value) => '${value.round()} decibels',
                    onChanged: !settable
                        ? null
                        : (value) {
                            setState(() => _dragged = value);
                            // Heard at once, kept once let go.
                            _gate.configure(settings.copyWith(threshold: value.roundToDouble()));
                          },
                    onChangeEnd: !settable
                        ? null
                        : (value) async {
                            await controller.setThreshold(value);
                            if (mounted) setState(() => _dragged = null);
                          },
                  ),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  shown == null ? '' : '${shown.round()} dB',
                  key: const Key('voice-threshold-value'),
                  textAlign: TextAlign.end,
                  style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        if (pushToTalk && settings != null) ...[
          if (!ref.watch(callOnPhoneProvider))
            ListTile(
              key: const Key('push-key'),
              leading: Icon(Icons.keyboard_outlined, color: context.palette.textSecondary),
              title: const Text('Key'),
              subtitle: Text(settings.pushKeyName ?? 'None yet: choose one'),
              trailing: Text('Change', style: TextStyle(color: context.palette.outgoingBubble)),
              onTap: () async {
                final key = await showDialog<(int, String)>(context: context, builder: (_) => const _PushKeyDialog());
                if (key != null) await controller.setPushKey(key.$1, key.$2);
              },
            ),
          const _DesktopKeyTile(),
        ],
        if (!inCall)
          ListTile(
            key: const Key('voice-test'),
            leading: Icon(_testing ? Icons.stop_circle_outlined : Icons.mic_none, color: context.palette.textSecondary),
            title: Text(_testing ? 'Stop the test' : 'Test your microphone'),
            subtitle: Text(_testing ? 'Speak, and see the bar' : 'Nothing is sent anywhere'),
            enabled: !_starting && settings != null,
            onTap: _toggleTest,
          ),
        Padding(
          key: const Key('voice-note'),
          padding: const EdgeInsets.fromLTRB(72, 4, 16, 12),
          child: Text(
            '${inCall ? 'The bar shows your microphone in this call. ' : ''}'
            '${pushToTalk ? 'The others hear you, and see you speaking, only while you hold the key, or the talk button in the call.' : 'The others hear you, and see you speaking, only while the bar is green.'}',
            style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// Asks for the push-to-talk key: the next one pressed, by where it is on
/// the keyboard (whatever the layout), with what it is called. Esc goes
/// back.
class _PushKeyDialog extends StatelessWidget {
  const _PushKeyDialog();

  static String _name(KeyEvent event) {
    final label = event.logicalKey.keyLabel;
    if (label.trim().isNotEmpty) return label;
    return event.physicalKey.debugName ?? 'Key ${event.physicalKey.usbHidUsage.toRadixString(16)}';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('push-key-dialog'),
    title: const Text('Press the key to talk with'),
    content: Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.handled;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.pop(context);
        } else {
          Navigator.pop(context, (event.physicalKey.usbHidUsage, _name(event)));
        }
        return KeyEventResult.handled;
      },
      child: const Text(
        "Hold it during calls to be heard. One you don't type with works best: F13, Scroll Lock, Pause.",
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
  );
}

/// The push-to-talk key in every app, which the desktop keeps (Linux): set
/// up here once (the desktop asks which key), changed in the desktop's own
/// settings. Where it can't be, says why.
class _DesktopKeyTile extends ConsumerStatefulWidget {
  const _DesktopKeyTile();

  @override
  ConsumerState<_DesktopKeyTile> createState() => _DesktopKeyTileState();
}

class _DesktopKeyTileState extends ConsumerState<_DesktopKeyTile> {
  var _busy = false;

  Future<void> _with(Future<void> Function(DesktopKey key) use) async {
    final open = ref.read(desktopKeyProvider);
    if (open == null || _busy) return;
    setState(() => _busy = true);
    try {
      final key = await open();
      try {
        await use(key);
      } finally {
        await key.close();
      }
    } on DesktopShortcutException catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text("Your desktop's keys: $e")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      ref.invalidate(desktopKeyStateProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopKeyStateProvider);
    if (ref.watch(desktopKeyProvider) == null || state.hasValue && state.value == null) return const SizedBox.shrink();
    final known = state.value;
    final key = known?.key;
    final icon = Icon(Icons.desktop_windows_outlined, color: context.palette.textSecondary);
    if (known == null) {
      return ListTile(
        key: Key('push-desktop'),
        leading: icon,
        title: Text('In other apps'),
        subtitle: Text('Asking your desktop...'),
      );
    }
    if (known.unavailable case final why?) {
      return ListTile(
        key: const Key('push-desktop'),
        leading: icon,
        enabled: false,
        title: Text('Only while ${context.appName} is in front'),
        subtitle: Text(why),
      );
    }
    return ListTile(
      key: const Key('push-desktop'),
      leading: icon,
      enabled: !_busy,
      title: Text(key == null ? 'In other apps too' : 'In other apps: $key'),
      subtitle: Text(
        key == null ? 'Your desktop asks you which key, once' : "Your desktop keeps it: change it in its settings",
      ),
      onTap: () => _with((desktop) async {
        if (key != null) return desktop.change();
        final pushKey = ref.read(voiceGateSettingsProvider).value?.pushKey;
        final bound = await desktop.bind(preferred: pushKey == null ? null : desktopKeyName(pushKey));
        await ref.read(voiceGateSettingsProvider.notifier).setDesktopKey(bound != null);
        if (bound == null && context.mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('Your desktop has no key for it yet')));
        }
      }),
    );
  }
}

/// The slider's track as a meter of the microphone: [level] (0 to 1) as
/// far as it reaches, green while the voice goes out ([open]).
class _MeterTrack extends SliderTrackShape with BaseSliderTrackShape {
  const _MeterTrack({required this.palette, required this.level, required this.open});

  /// The colours it is drawn in: a shape has no context to read them from.
  final HanashiPalette palette;
  final double? level;
  final bool open;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    context.canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), Paint()..color = palette.divider);
    final level = this.level;
    if (level == null || level <= 0) return;
    final reach = Rect.fromLTWH(rect.left, rect.top, rect.width * level, rect.height);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(reach, radius),
      Paint()..color = open ? palette.online : palette.offline,
    );
  }
}

/// Whether links get a preview before they are sent.
class _LinkSettings extends ConsumerWidget {
  const _LinkSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previews = ref.watch(linkPreviewsProvider).value;
    return SwitchListTile(
      key: const Key('link-previews'),
      secondary: Icon(Icons.link, color: context.palette.textSecondary),
      title: const Text('Link previews'),
      subtitle: const Text(
        'Before you send a link, this device fetches its title, picture and any video or GIF (up to 25 MB), '
        'so the website sees your IP address. Those you send it to do not contact the website, '
        'unless they choose to load a video from it.',
      ),
      value: previews ?? true,
      onChanged: previews == null ? null : (value) => ref.read(linkPreviewsProvider.notifier).set(value),
    );
  }
}

/// Whether a link's video or GIF that did not come with the message can be
/// loaded from its site.
class _LinkSourceSettings extends ConsumerWidget {
  const _LinkSourceSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(linkSourcesProvider).value;
    return SwitchListTile(
      key: const Key('link-sources'),
      secondary: Icon(Icons.travel_explore, color: context.palette.textSecondary),
      title: const Text('Load link videos from websites'),
      subtitle: const Text(
        "A link's video or GIF that did not come with the message (one too large to send, say) can be opened "
        "here instead of on the website. You're asked each time, and the website sees your IP address.",
      ),
      value: load ?? false,
      onChanged: load == null ? null : (value) => ref.read(linkSourcesProvider.notifier).set(value),
    );
  }
}

/// Whether others see the user typing.
class _TypingSettings extends ConsumerWidget {
  const _TypingSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final send = ref.watch(typingNotificationsProvider).value;
    return SwitchListTile(
      key: const Key('typing-notifications'),
      secondary: Icon(Icons.keyboard_outlined, color: context.palette.textSecondary),
      title: const Text("Show when I'm typing"),
      subtitle: const Text(
        "Others in a chat see that you are typing a message. Off: from this device they don't; "
        'you still see when they are typing.',
      ),
      value: send ?? true,
      onChanged: send == null ? null : (value) => ref.read(typingNotificationsProvider.notifier).set(value),
    );
  }
}

/// How much the app logs, and the log itself.
class _LogSettings extends ConsumerWidget {
  const _LogSettings();

  static const _choices = [LogLevel.warning, LogLevel.info, LogLevel.debug];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(logLevelProvider);
    return Column(
      children: [
        ListTile(
          key: const Key('log-level'),
          leading: Icon(Icons.bug_report_outlined, color: context.palette.textSecondary),
          title: const Text('Log detail'),
          subtitle: Text(
            '${logLevelName(level)}. The log records what this device does with the server and the encryption, '
            'to find out what went wrong. Detailed also records each request and message ID. It names your '
            'contacts, chats and devices, but holds no messages or keys.',
          ),
          onTap: () async {
            final choice = await showDialog<LogLevel>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Log detail'),
                children: [
                  for (final option in _choices)
                    SimpleDialogOption(
                      key: Key('log-level-${option.name}'),
                      onPressed: () => Navigator.pop(context, option),
                      child: Text(option == level ? '${logLevelName(option)} (now)' : logLevelName(option)),
                    ),
                ],
              ),
            );
            if (choice != null) await ref.read(logLevelProvider.notifier).set(choice);
          },
        ),
        ListTile(
          key: const Key('log-view'),
          leading: Icon(Icons.article_outlined, color: context.palette.textSecondary),
          title: const Text('View log'),
          subtitle: const Text('Copy it, or save it to a file, to send with a bug report'),
          onTap: () => showLog(context),
        ),
      ],
    );
  }
}

/// The user's name, picture and status, with a button to change them;
/// tapping it shows the profile as others see it.
class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.userId, required this.fallbackName, this.server});

  final String userId;

  /// The name from signing in, until the profile list has the user.
  final String fallbackName;
  final String? server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(profilesProvider.select((p) => p.value?[userId]?.displayName)) ?? fallbackName;
    return ListTile(
      key: const Key('own-profile'),
      leading: PresenceAvatar(id: userId, label: name),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(server == null ? userId : '$userId\n$server'),
      isThreeLine: server != null,
      onTap: () => showProfileCard(context, userId),
      trailing: IconButton(
        key: const Key('edit-profile'),
        tooltip: 'Edit profile',
        icon: Icon(Icons.edit_outlined, color: context.palette.textSecondary),
        onPressed: () => showEditProfile(context, userId: userId, name: name),
      ),
    );
  }
}

/// How the user appears to the people they chat with: online (or idle when
/// away), in focus, or invisible.
class _StatusTile extends ConsumerWidget {
  const _StatusTile({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(presenceModeProvider).value ?? PresenceMode.auto;
    final shown = switch (mode) {
      PresenceMode.auto => ref.watch(presenceOfProvider(userId)),
      PresenceMode.focus => Presence.focus,
      PresenceMode.invisible => Presence.offline,
    };
    Future<void> choose(PresenceMode mode) async {
      try {
        await ref.read(chatRepositoryProvider).setPresenceMode(mode);
      } on ApiException catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }

    return PopupMenuButton<PresenceMode>(
      key: const Key('presence-mode'),
      tooltip: 'Change status',
      initialValue: mode,
      onSelected: choose,
      itemBuilder: (_) => [
        for (final option in PresenceMode.values)
          PopupMenuItem(
            key: Key('presence-mode-${option.name}'),
            value: option,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: StatusBadge(
                presence: switch (option) {
                  PresenceMode.auto => Presence.online,
                  PresenceMode.focus => Presence.focus,
                  PresenceMode.invisible => Presence.offline,
                },
                size: 16,
              ),
              title: Text(presenceModeLabel(option)),
              subtitle: Text(presenceModeHint(option)),
            ),
          ),
      ],
      child: ListTile(
        leading: SizedBox(
          width: 44,
          child: Center(
            child: StatusBadge(presence: shown, size: 18, label: presenceModeLabel(mode)),
          ),
        ),
        title: Text('Status: ${mode == PresenceMode.auto ? presenceLabel(shown) : presenceModeLabel(mode)}'),
        subtitle: Text(presenceModeHint(mode)),
        trailing: Icon(Icons.expand_more, color: context.palette.textSecondary),
      ),
    );
  }
}

class _EncryptionTiles extends ConsumerWidget {
  const _EncryptionTiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(encryptionProvider.notifier);
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }

    final store = ref.watch(secureStoreProvider);
    return Column(
      children: [
        if (store is SwitchableSecureStore && store.current is FileSecureStore) _KeysInFileTile(store: store),
        FutureBuilder(
          future: controller.fingerprint(),
          builder: (context, snapshot) => ListTile(
            leading: Icon(Icons.lock, color: context.palette.success),
            title: const Text('End-to-end encryption is on'),
            subtitle: Text(
              snapshot.data == null ? 'This device is verified' : 'Your security key: ${snapshot.data}',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.key_outlined, color: context.palette.textSecondary),
          title: const Text('Create a new recovery key'),
          subtitle: const Text('Use this if you lost yours. The old key stops working.'),
          onTap: () async {
            if (await _confirm(
              context,
              'Create a new recovery key?',
              'Your current recovery key will stop working. Store the new one safely.',
              'Create',
            )) {
              await run(controller.newRecoveryKey);
            }
          },
        ),
        ListTile(
          leading: Icon(Icons.restart_alt, color: context.palette.failed),
          title: Text('Reset encryption', style: TextStyle(color: context.palette.failed)),
          subtitle: const Text('New identity: other devices must verify again and contacts are warned.'),
          onTap: () async {
            if (await _confirm(
              context,
              'Reset encryption?',
              'You get a new identity and recovery key. Your other devices must be verified again, '
                  'and your contacts are told that your security key changed.',
              'Reset',
            )) {
              await run(() => controller.setUp(reset: true));
            }
          },
        ),
      ],
    );
  }
}

/// The keys are in a file (there was no keyring); moves them into a keyring
/// once there is one.
class _KeysInFileTile extends StatefulWidget {
  const _KeysInFileTile({required this.store});

  final SwitchableSecureStore store;

  @override
  State<_KeysInFileTile> createState() => _KeysInFileTileState();
}

class _KeysInFileTileState extends State<_KeysInFileTile> {
  var _busy = false;

  Future<void> _move() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final keyring = PlatformSecureStore();
    String message;
    if (await keyring.isAvailable()) {
      await widget.store.moveTo(keyring);
      message = 'Your keys are in the keyring now.';
    } else {
      message = 'Still no keyring available.';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // Gone once moved.
    if (widget.store.current is! FileSecureStore) return const SizedBox.shrink();
    return ListTile(
      key: const Key('keys-in-file'),
      leading: Icon(Icons.warning_amber_rounded, color: context.palette.warning),
      title: const Text('Your keys are kept in a file'),
      subtitle: const Text(
        'There was no system keyring. Anyone who can read your files can read your keys. '
        'Once a keyring runs, move them there.',
      ),
      isThreeLine: true,
      trailing: TextButton(onPressed: _busy ? null : _move, child: const Text('Move to keyring')),
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.device});

  final DeviceInfo device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastSeen = DateTime.fromMillisecondsSinceEpoch(device.lastSeenAt);
    return ListTile(
      leading: Icon(switch (device.platform) {
        'android' || 'ios' => Icons.smartphone,
        'linux' || 'macos' || 'windows' => Icons.computer,
        _ => Icons.devices_other,
      }, color: context.palette.textSecondary),
      title: Text(device.name),
      subtitle: Text(
        device.current ? 'This device' : 'Last active ${formatDay(lastSeen)} ${formatClock(lastSeen)}',
      ),
      trailing: device.current
          ? null
          : IconButton(
              tooltip: 'Sign out this device',
              icon: Icon(Icons.remove_circle_outline, color: context.palette.failed),
              onPressed: () async {
                final confirmed = await _confirm(
                  context,
                  'Sign out "${device.name}"?',
                  'That device will stop receiving messages until it signs in again.',
                  'Sign out device',
                );
                if (!confirmed) return;
                try {
                  await ref.read(chatRepositoryProvider).revokeDevice(device.id);
                } on ApiException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
                ref.invalidate(devicesProvider);
              },
            ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.failed),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
