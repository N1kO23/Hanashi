import 'package:material_ui/material_ui.dart';

import '../theme/hanashi_theme.dart';

/// Orange-red rounded square with the unread count, as in Hanashi; grey
/// for a muted chat.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count, this.size = 24, this.muted = false});

  final int count;
  final double size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minWidth: size),
      height: size,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? context.palette.offline : context.palette.unreadBadge,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: context.palette.onAccent,
          fontSize: size * 0.58,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
  }
}
