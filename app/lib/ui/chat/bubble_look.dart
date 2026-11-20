import 'package:flutter/widgets.dart';

/// How the chat's bubbles are set: the size of their text, the spacing of its
/// lines, and the padding around it. Each device keeps its own, as screens
/// differ (see `bubbleLookProvider`); the defaults are close to the game.
@immutable
class BubbleLook {
  const BubbleLook({this.textSize = defaultTextSize, this.lineSpacing = defaultLineSpacing, this.padding = defaultPadding});

  /// The look of the bubbles at [context] (see [BubbleLookScope]).
  static BubbleLook of(BuildContext context) => BubbleLookScope.of(context);

  static const defaultTextSize = 18.0;
  static const defaultLineSpacing = 1.3;
  static const defaultPadding = 7.0;

  /// What can be chosen, as (min, max, step).
  static const textSizes = (min: 12.0, max: 28.0, step: 1.0);
  static const lineSpacings = (min: 1.0, max: 1.8, step: 0.05);
  static const paddings = (min: 2.0, max: 16.0, step: 1.0);

  /// The text's size, in logical pixels.
  final double textSize;

  /// Line height, as a multiple of [textSize].
  final double lineSpacing;

  /// Above and below the text; at the sides it is 4 more.
  final double padding;

  /// Message text, as large and as spaced as set; its colour is the
  /// palette's (`onBubble` on a bubble).
  TextStyle get textStyle => TextStyle(fontSize: textSize, height: lineSpacing);

  /// One line of text: what a bubble is as tall as, at the least.
  double get lineHeight => textSize * lineSpacing;

  EdgeInsets get bubblePadding => EdgeInsets.symmetric(horizontal: padding + 4, vertical: padding);

  bool get isDefault => this == const BubbleLook();

  BubbleLook copyWith({double? textSize, double? lineSpacing, double? padding}) => BubbleLook(
    textSize: textSize ?? this.textSize,
    lineSpacing: lineSpacing ?? this.lineSpacing,
    padding: padding ?? this.padding,
  );

  /// Kept to what can be chosen, and to its steps; null where [value] is
  /// none (or not a number), which means the default.
  static double? fit(double? value, ({double min, double max, double step}) range) {
    if (value == null || value.isNaN) return null;
    final steps = ((value.clamp(range.min, range.max) - range.min) / range.step).round();
    return double.parse((range.min + steps * range.step).toStringAsFixed(2));
  }

  @override
  bool operator ==(Object other) =>
      other is BubbleLook && other.textSize == textSize && other.lineSpacing == lineSpacing && other.padding == padding;

  @override
  int get hashCode => Object.hash(textSize, lineSpacing, padding);

  @override
  String toString() => 'BubbleLook($textSize, $lineSpacing, $padding)';
}

/// The [BubbleLook] of the chat bubbles below it. Without one they take the
/// default.
class BubbleLookScope extends InheritedWidget {
  const BubbleLookScope({super.key, required this.look, required super.child});

  final BubbleLook look;

  static BubbleLook of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BubbleLookScope>()?.look ?? const BubbleLook();

  @override
  bool updateShouldNotify(BubbleLookScope oldWidget) => look != oldWidget.look;
}
