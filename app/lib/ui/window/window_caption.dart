import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/hanashi_theme.dart';
import 'window_controls.dart';

/// Makes [child] move the window when dragged and toggle maximize when
/// double-clicked, like a native title bar. Does nothing on phones.
///
/// Keep buttons outside of it: a double-click detector holds every single
/// tap until the double-click timeout, so buttons inside would feel slow.
class WindowDragArea extends ConsumerWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(windowControlsProvider);
    if (controls == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => controls.startDragging(),
      onDoubleTap: controls.toggleMaximize,
      child: child,
    );
  }
}

/// Minimize, maximize/restore and close, drawn in the app's own title bars.
/// Empty on phones.
class WindowButtons extends ConsumerWidget {
  const WindowButtons({super.key, this.color, this.height = 56});

  /// The buttons' icons; by default the palette's for the title bar.
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(windowControlsProvider);
    if (controls == null) return const SizedBox.shrink();
    final maximized = ref.watch(windowMaximizedProvider).value ?? false;
    final color = this.color ?? context.palette.onHeader;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          tooltip: 'Minimize',
          icon: Icons.remove_rounded,
          color: color,
          height: height,
          onPressed: controls.minimize,
        ),
        _CaptionButton(
          tooltip: maximized ? 'Restore' : 'Maximize',
          icon: maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: maximized ? 18 : 22,
          color: color,
          height: height,
          onPressed: controls.toggleMaximize,
        ),
        _CaptionButton(
          tooltip: 'Close',
          icon: Icons.close_rounded,
          iconSize: 32,
          color: color,
          height: height,
          hoverColor: context.palette.failed,
          onPressed: controls.close,
        ),
      ],
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.height,
    required this.onPressed,
    this.iconSize = 24,
    this.hoverColor,
  });

  final String tooltip;
  final IconData icon;
  final double iconSize;
  final Color color;
  final double height;
  final Color? hoverColor;
  final VoidCallback onPressed;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: widget.height,
            height: widget.height,
            color: _hovered ? (widget.hoverColor ?? widget.color.withValues(alpha: 0.18)) : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: widget.color),
          ),
        ),
      ),
    );
  }
}
