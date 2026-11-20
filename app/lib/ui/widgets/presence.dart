import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import 'avatar.dart';

String presenceLabel(Presence presence) => switch (presence) {
  Presence.online => 'Online',
  Presence.idle => 'Idle',
  Presence.focus => 'Focus',
  Presence.offline => 'Offline',
};

/// The user's own status as they chose it, in a few words.
String presenceModeLabel(PresenceMode mode) => switch (mode) {
  PresenceMode.auto => 'Online',
  PresenceMode.focus => 'Focus',
  PresenceMode.invisible => 'Invisible',
};

String presenceModeHint(PresenceMode mode) => switch (mode) {
  PresenceMode.auto => 'Idle after ${UserActivity.idleAfter.inMinutes} minutes away',
  PresenceMode.focus => 'Others see that you are focusing',
  PresenceMode.invisible => 'You appear offline, and still see who is online',
};

/// A user's status as a badge at the corner of their picture, where the
/// game's messenger shows a student's rank: green when online, an amber moon
/// when idle, a pink bar in focus, a grey ring when offline.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.presence, this.size = 14, this.label});

  final Presence presence;
  final double size;

  /// What the tooltip says, if not [presenceLabel].
  final String? label;

  @override
  Widget build(BuildContext context) {
    final border = max(2.0, size * 0.12);
    final inner = size - 2 * border;
    return Tooltip(
      message: label ?? presenceLabel(presence),
      child: Container(
        key: Key('status-${presence.name}'),
        width: size,
        height: size,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: switch (presence) {
            Presence.online => context.palette.online,
            Presence.idle => context.palette.idle,
            Presence.focus => context.palette.focus,
            Presence.offline => context.palette.offline,
          },
          shape: BoxShape.circle,
          border: Border.all(color: context.palette.surface, width: border),
        ),
        child: switch (presence) {
          Presence.online => null,
          // A crescent moon: a white bite out of the top left.
          Presence.idle => Align(
            alignment: const Alignment(-1.5, -1.5),
            child: Container(
              width: inner * 0.7,
              height: inner * 0.7,
              decoration: BoxDecoration(color: context.palette.surface, shape: BoxShape.circle),
            ),
          ),
          Presence.focus => Container(
            width: inner * 0.6,
            height: max(1.5, inner * 0.18),
            decoration: BoxDecoration(color: context.palette.surface, borderRadius: BorderRadius.circular(inner)),
          ),
          Presence.offline => Container(
            width: inner * 0.42,
            height: inner * 0.42,
            decoration: BoxDecoration(color: context.palette.surface, shape: BoxShape.circle),
          ),
        },
      ),
    );
  }
}

/// [Avatar] with the user's [StatusBadge], which is left out while they are
/// offline unless [showOffline]. A group never has one.
class PresenceAvatar extends ConsumerWidget {
  const PresenceAvatar({
    super.key,
    required this.id,
    required this.label,
    this.picture,
    this.size = 44,
    this.showOffline = false,
    this.statusLabel,
  });

  final String id;
  final String label;
  final MediaRef? picture;
  final double size;
  final bool showOffline;

  /// What the badge's tooltip says, if not the status.
  final String? statusLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatar = Avatar(id: id, label: label, picture: picture, size: size);
    final presence = ref.watch(presenceOfProvider(id));
    if (presence == Presence.offline && !showOffline) return avatar;
    final badge = max(12.0, size * 0.3);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -badge * 0.08,
          bottom: -badge * 0.08,
          child: StatusBadge(presence: presence, size: badge, label: statusLabel),
        ),
      ],
    );
  }
}
