import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/ui/home/home_shell.dart';
import 'package:hanashi/ui/widgets/hanashi_title_bar.dart';

import 'support/test_app.dart';

/// A phone held upright, with a status bar and a navigation bar that the app
/// draws under (as on Android 15 and later).
Future<void> uprightPhone(WidgetTester tester) async {
  await setSurfaceSize(tester, const Size(400, 800));
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
}

void main() {
  testWidgets('back from a chat returns to the list instead of closing the app', (tester) async {
    // With predictive back (Android 16), Android asks ahead whether the app
    // handles back; if not, back closes it.
    final handlesBack = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') handlesBack.add(call.arguments as bool);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await uprightPhone(tester);
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    expect(handlesBack.last, isTrue);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-field')), findsNothing);
    expect(find.text('Club Room'), findsOneWidget);
    // On the list, back leaves the app as usual.
    expect(handlesBack.last, isFalse);
  });

  testWidgets('back from a profile returns to the contacts', (tester) async {
    await uprightPhone(tester);
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aiko'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-name')), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-name')), findsNothing);
    expect(find.text('Aiko'), findsOneWidget);
  });

  testWidgets('upright, the lists start right under the header', (tester) async {
    await uprightPhone(tester);
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.byType(HanashiTitleBar)).dy, 24 + HanashiTitleBar.height);
    for (final tab in HomeTab.values) {
      await tester.tap(find.byTooltip(tab.label));
      await tester.pumpAndSettle();
      // The status bar's height again, at the top of the list, was the gap.
      final list = find.byType(ListView).first;
      final padding = tester.renderObject<RenderSliverPadding>(
        find.descendant(of: list, matching: find.byType(SliverPadding)).first,
      );
      expect(padding.resolvedPadding!.top, 0, reason: tab.label);
    }
  });

  testWidgets('a photo opens in the middle of the screen', (tester) async {
    await uprightPhone(tester);
    final repository = testRepository();
    await tester.pumpWidget(testApp(repository));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.image_outlined).first);
    // The page transition; the spinner itself never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Loading (the demo has no files): the spinner sits where the photo
    // will, in the middle of the screen, under the see-through title bar.
    final spinner = tester.getCenter(find.byType(CircularProgressIndicator));
    expect(spinner, const Offset(200, 400));
  });
}
