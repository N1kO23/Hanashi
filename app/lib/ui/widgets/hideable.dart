import 'package:flutter/widgets.dart';

/// [child], faded out and out of the way while [hidden].
class Hideable extends StatelessWidget {
  const Hideable({super.key, required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: hidden,
    child: AnimatedOpacity(opacity: hidden ? 0 : 1, duration: const Duration(milliseconds: 200), child: child),
  );
}
