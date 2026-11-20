import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../calls/call_connection.dart';
import '../../calls/call_controller.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';

/// How loud [users] play here: a slider for each one's voice, and one for
/// their shared screen's sound while it has some. A menu of [menus]'s
/// navigator, [at] a place on the screen (global).
Future<void> showVolumes(BuildContext menus, {required Offset at, required List<String> users}) async {
  final overlay = Navigator.of(menus).overlay!.context.findRenderObject()! as RenderBox;
  final place = overlay.globalToLocal(at);
  await showMenu<void>(
    context: menus,
    position: RelativeRect.fromRect(place & Size.zero, Offset.zero & overlay.size),
    constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
    items: [_VolumesEntry(users: users)],
  );
}

/// Just under [context]'s widget, on the screen: where its menu goes.
Offset below(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(box.size.bottomLeft(Offset.zero));
}

class _VolumesEntry extends PopupMenuEntry<void> {
  const _VolumesEntry({required this.users});

  final List<String> users;

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(void value) => false;

  @override
  State<_VolumesEntry> createState() => _VolumesEntryState();
}

class _VolumesEntryState extends State<_VolumesEntry> {
  @override
  Widget build(BuildContext context) => _Volumes(users: widget.users);
}

/// Those of the users still in the call, as they come and go.
class _Volumes extends ConsumerWidget {
  const _Volumes({required this.users});

  final List<String> users;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(callControllerProvider.select((view) => view.room.peers));
    final volumes = ref.watch(peerVolumesProvider);
    final here = [
      for (final user in users)
        if (peers.any((p) => p.user == user)) user,
    ];
    if (here.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Nobody else is in the call', style: TextStyle(color: context.palette.textSecondary)),
      );
    }
    return Padding(
      key: const Key('call-volumes'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final user in here)
            _PersonVolume(
              user: user,
              volume: volumes[user] ?? const PeerVolume(),
              screenSound: peers.any((p) => p.user == user && p.screenSound && !p.unwatchedScreen),
            ),
        ],
      ),
    );
  }
}

class _PersonVolume extends ConsumerWidget {
  const _PersonVolume({required this.user, required this.volume, required this.screenSound});

  final String user;
  final PeerVolume volume;

  /// Their shared screen has sound: its own slider.
  final bool screenSound;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volumes = ref.read(peerVolumesProvider.notifier);
    final me = ref.watch(chatRepositoryProvider).me;
    final name = ref.watch(profilesProvider).value?[user]?.displayName ?? UserId.fallbackName(user, me: me);
    Widget slider(String what, String label, IconData icon, double value, PeerVolume Function(double) apply) => Row(
      children: [
        Icon(icon, size: 18, color: context.palette.textSecondary),
        Expanded(
          child: Slider(
            key: ValueKey('call-volume-$what-$user'),
            value: value.clamp(0, PeerVolume.most),
            max: PeerVolume.most,
            // Ten per cent a step: as they send (100%) is one.
            divisions: (PeerVolume.most * 10).round(),
            semanticFormatterCallback: (value) => '$label ${(value * 100).round()}%',
            // Heard at once, kept once let go.
            onChanged: (value) => volumes.set(user, apply(value), keep: false),
            onChangeEnd: (value) => volumes.set(user, apply(value)),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(value * 100).round()}%',
            key: ValueKey('call-volume-$what-$user-value'),
            textAlign: TextAlign.end,
            style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Avatar(id: user, label: name, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, color: context.palette.textPrimary),
                ),
              ),
            ],
          ),
          slider('voice', 'Voice', Icons.mic, volume.voice, (value) => volume.copyWith(voice: value)),
          if (screenSound)
            slider(
              'screen',
              "Screen's sound",
              Icons.screen_share,
              volume.screen,
              (value) => volume.copyWith(screen: value),
            ),
        ],
      ),
    );
  }
}
