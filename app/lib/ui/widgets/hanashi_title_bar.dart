import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/hanashi_theme.dart';
import '../window/window_caption.dart';

/// The app's mark and name at the start of the title bar: the theme's (see
/// [HanashiBranding]), or else the name in text.
class HanashiLogo extends StatelessWidget {
  const HanashiLogo({super.key, this.height = 30});

  final double height;

  @override
  Widget build(BuildContext context) {
    final HanashiBranding(:appName, :logo, :wordmark) = context.branding;
    return Semantics(
      label: appName,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (logo != null) ...[
            Image(image: logo, height: height, filterQuality: FilterQuality.medium),
            SizedBox(width: height * 0.3),
          ],
          if (wordmark != null)
            Image(image: wordmark, height: height * 0.74, filterQuality: FilterQuality.medium)
          else
            ExcludeSemantics(
              child: Text(
                appName,
                style: TextStyle(
                  color: context.palette.onHeader,
                  fontSize: height * 0.72,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pink title bar with the logo. On desktop it is also the window's title
/// bar: drag to move, double-click to maximize, and window buttons on the right.
class HanashiTitleBar extends StatelessWidget {
  const HanashiTitleBar({super.key, this.trailing = const []});

  static const height = 56.0;

  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final header = context.palette.header;
    // The status bar is drawn over it: its icons stand out from the header,
    // whatever the theme's brightness.
    final darkHeader = ThemeData.estimateBrightnessForColor(header) == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: darkHeader ? Brightness.light : Brightness.dark,
        statusBarBrightness: darkHeader ? Brightness.dark : Brightness.light,
      ),
      child: _bar(header),
    );
  }

  Widget _bar(Color header) {
    return Container(
      color: header,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: height,
          // Only the empty part is the drag area: inside a double-click
          // detector, button taps would wait for the double-click timeout.
          child: Row(
            children: [
              const Expanded(
                child: WindowDragArea(child: Row(children: [SizedBox(width: 18), HanashiLogo(), Spacer()])),
              ),
              ...trailing,
              const WindowButtons(height: height),
            ],
          ),
        ),
      ),
    );
  }
}
