import 'package:material_ui/material_ui.dart';

import '../theme/hanashi_theme.dart';

/// Section title above the chat and contact lists ("Unread Messages (16)").
class ListHeader extends StatelessWidget {
  const ListHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.only(left: 20, right: 12),
      color: context.palette.listBackground,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: context.palette.textHeading),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// White rounded button with a soft shadow, like Hanashi's sort controls.
class ListHeaderButton extends StatelessWidget {
  const ListHeaderButton({super.key, required this.child, this.onPressed, this.tooltip});

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: context.palette.surface,
      elevation: 1.5,
      shadowColor: context.palette.shadow.withAlpha(0x33),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Container(
          height: 36,
          constraints: const BoxConstraints(minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: tooltip == null ? button : Tooltip(message: tooltip, child: button),
    );
  }
}

/// The sort menu of a list's header: the order it is in, and the others to pick.
class ListSortMenu<T> extends StatelessWidget {
  const ListSortMenu({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onSelected,
  });

  final T value;
  final List<T> options;
  final String Function(T option) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: 'Sort',
    initialValue: value,
    onSelected: onSelected,
    itemBuilder: (_) => [for (final o in options) PopupMenuItem(value: o, child: Text(labelOf(o)))],
    child: IgnorePointer(
      child: ListHeaderButton(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(labelOf(value), style: TextStyle(color: context.palette.textHeading, fontSize: 14)),
            const SizedBox(width: 6),
            Icon(Icons.arrow_drop_down, size: 20, color: context.palette.incomingBubble),
          ],
        ),
      ),
    ),
  );
}

/// A band naming one part of a list ("Today's Birthdays"), as the game's
/// student list has.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Container(
    height: 30,
    color: context.palette.replyPanel,
    padding: const EdgeInsets.only(left: 14),
    child: Row(
      children: [
        Container(width: 3, height: 15, color: context.palette.replyAccent),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 14.5, color: context.palette.textHeading)),
      ],
    ),
  );
}
