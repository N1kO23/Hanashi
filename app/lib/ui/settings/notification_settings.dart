import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../calls/call_controller.dart';
import '../../desktop/autostart.dart';
import '../../notifications/notification_center.dart';
import '../../push/push_service.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';

/// Notification settings, how pushes reach the phone (Android), and
/// starting with the computer (desktop).
class NotificationSettings extends ConsumerStatefulWidget {
  const NotificationSettings({super.key});

  @override
  ConsumerState<NotificationSettings> createState() => _NotificationSettingsState();
}

class _NotificationSettingsState extends ConsumerState<NotificationSettings> {
  bool? _autostart;
  String? _distributor;

  /// Calls may ring full screen over the lock screen (Android 14 asks).
  bool? _fullScreen;
  AppLifecycleListener? _back;

  @override
  void initState() {
    super.initState();
    if (PushService.supported) {
      _loadFullScreen();
      // Back from the system's setting.
      _back = AppLifecycleListener(onResume: _loadFullScreen);
    }
    if (Autostart.supported) {
      Autostart.isEnabled().then((enabled) {
        if (mounted) setState(() => _autostart = enabled);
      });
    }
    _loadDistributor();
  }

  @override
  void dispose() {
    _back?.dispose();
    super.dispose();
  }

  Future<void> _loadFullScreen() async {
    final allowed = await ref.read(callWindowProvider).canRingFullScreen();
    if (mounted) setState(() => _fullScreen = allowed);
  }

  Future<void> _loadDistributor() async {
    final current = await PushService.current();
    if (mounted) setState(() => _distributor = current);
  }

  Future<void> _save(NotificationPreferences preferences) =>
      ref.read(notificationPreferencesProvider.notifier).save(preferences);

  Future<void> _chooseDistributor() async {
    final available = await PushService.distributors();
    if (!mounted) return;
    if (available.isEmpty) {
      _showMessage('Install a UnifiedPush app such as ntfy, or use a phone with Google Play services.');
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Deliver notifications with'),
        children: [
          for (final d in available)
            SimpleDialogOption(onPressed: () => Navigator.pop(context, d), child: Text(_distributorName(d))),
        ],
      ),
    );
    if (choice == null) return;
    final vapidKey = await ref.read(vapidKeyProvider.future);
    if (vapidKey == null) {
      _showMessage('This server does not support push notifications.');
      return;
    }
    await PushService.use(choice, vapidKey: vapidKey);
    await _loadDistributor();
  }

  Future<void> _setAutostart(bool enabled) async {
    try {
      await Autostart.setEnabled(enabled);
      setState(() => _autostart = enabled);
    } on Exception catch (e) {
      _showMessage('$e');
    }
  }

  void _showMessage(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _distributorName(String? distributor) => switch (distributor) {
    null => 'Not set up',
    PushService.builtInDistributor => 'Google Play services (built in)',
    'io.heckel.ntfy' => 'ntfy',
    'org.unifiedpush.distributor.nextpush' => 'NextPush',
    'org.unifiedpush.distributor.sunup' => 'Sunup',
    final other => other,
  };

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(notificationPreferencesProvider).value ?? const NotificationPreferences();
    final hasDisplay = ref.watch(notificationDisplayProvider) != null;
    return Column(
      children: [
        SwitchListTile(
          key: const Key('notifications-enabled'),
          secondary: Icon(Icons.notifications_outlined, color: context.palette.textSecondary),
          title: const Text('Show notifications'),
          subtitle: Text('For new messages while you are not looking at ${context.appName}'),
          value: preferences.enabled,
          onChanged: !hasDisplay
              ? null
              : (enabled) async {
                  if (enabled) await ref.read(notificationDisplayProvider)?.requestPermission();
                  await _save(preferences.copyWith(enabled: enabled));
                },
        ),
        SwitchListTile(
          key: const Key('notifications-preview'),
          secondary: Icon(Icons.visibility_outlined, color: context.palette.textSecondary),
          title: const Text('Show sender and message'),
          subtitle: const Text('Off: only "New message"'),
          value: preferences.preview,
          onChanged: !hasDisplay || !preferences.enabled
              ? null
              : (preview) => _save(preferences.copyWith(preview: preview)),
        ),
        for (final kind in NotifyKind.values)
          _KindTile(
            kind: kind,
            style: preferences.styleOf(kind),
            enabled: hasDisplay && preferences.enabled,
            onChanged: (style) => _save(preferences.withStyle(kind, style)),
          ),
        ListTile(
          leading: Icon(Icons.do_not_disturb_on_outlined, color: context.palette.textSecondary),
          title: const Text('While you are in Focus'),
          subtitle: const Text('Notifications wait, and show without a sound once Focus ends'),
        ),
        if (PushService.supported)
          ListTile(
            leading: Icon(Icons.cloud_sync_outlined, color: context.palette.textSecondary),
            title: Text('While ${context.appName} is closed'),
            subtitle: Text(
              _distributor == null
                  ? 'Not set up: install a UnifiedPush app such as ntfy to get notifications while ${context.appName} is closed'
                  : 'Delivered by ${_distributorName(_distributor)}',
            ),
            onTap: _chooseDistributor,
          ),
        if (_fullScreen == false && (ref.watch(callsAvailableProvider).value ?? false))
          ListTile(
            key: const Key('calls-full-screen'),
            leading: Icon(Icons.phone_locked_outlined, color: context.palette.warning),
            title: const Text('Calls on the lock screen'),
            subtitle: const Text('Calls ring only as a notification. Tap to let them show full screen'),
            onTap: () => ref.read(callWindowProvider).allowRingingFullScreen(),
          ),
        if (Autostart.supported)
          SwitchListTile(
            secondary: Icon(Icons.login, color: context.palette.textSecondary),
            title: const Text('Start when you log in'),
            subtitle: Text('Closing the window keeps ${context.appName} running in the tray'),
            value: _autostart ?? false,
            onChanged: _autostart == null ? null : _setAutostart,
          ),
      ],
    );
  }
}

/// Whether one kind of message notifies on this device, and with a sound.
class _KindTile extends StatelessWidget {
  const _KindTile({required this.kind, required this.style, required this.enabled, required this.onChanged});

  final NotifyKind kind;
  final NotifyStyle style;
  final bool enabled;
  final ValueChanged<NotifyStyle> onChanged;

  static String _label(NotifyKind kind) => switch (kind) {
    NotifyKind.direct => 'Direct messages',
    NotifyKind.group => 'Group messages',
    NotifyKind.replies => 'Replies to you in groups',
    NotifyKind.reactions => 'Reactions to your messages',
    NotifyKind.requests => 'Contact requests',
  };

  static String _styleLabel(NotifyStyle style) => switch (style) {
    NotifyStyle.sound => 'With a sound',
    NotifyStyle.silent => 'Silent',
    NotifyStyle.off => 'Off',
  };

  static IconData _icon(NotifyStyle style) => switch (style) {
    NotifyStyle.sound => Icons.volume_up_outlined,
    NotifyStyle.silent => Icons.volume_off_outlined,
    NotifyStyle.off => Icons.notifications_off_outlined,
  };

  @override
  Widget build(BuildContext context) => PopupMenuButton<NotifyStyle>(
    key: Key('notify-kind-${kind.name}'),
    enabled: enabled,
    tooltip: _label(kind),
    initialValue: style,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final option in NotifyStyle.values.reversed)
        PopupMenuItem(
          key: Key('notify-style-${kind.name}-${option.name}'),
          value: option,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_icon(option)),
            title: Text(_styleLabel(option)),
          ),
        ),
    ],
    child: ListTile(
      enabled: enabled,
      leading: Icon(_icon(style), color: context.palette.textSecondary),
      title: Text(_label(kind)),
      subtitle: Text(_styleLabel(style)),
      trailing: Icon(Icons.expand_more, color: context.palette.textSecondary),
    ),
  );
}
