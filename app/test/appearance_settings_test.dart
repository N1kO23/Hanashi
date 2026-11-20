import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/themes/appearance.dart';
import 'package:hanashi/data/themes/app_theme.dart';
import 'package:hanashi/data/themes/builtin_themes.dart';
import 'package:hanashi/data/themes/theme_library.dart';
import 'package:hanashi/data/themes/theme_package.dart';
import 'package:hanashi/data/themes/theme_store.dart';
import 'package:hanashi/launcher/theme_launcher.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/settings/appearance_settings.dart';
import 'package:hanashi/ui/settings/settings_screen.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';
import 'package:hanashi/ui/widgets/hanashi_title_bar.dart';

import 'support/test_app.dart';
import 'support/themes.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi-appearance-'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Pumps until [done]; files are read and written outside the test's fake
  /// clock.
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(done(), isTrue);
  }

  Future<void> pumpUntilShown(WidgetTester tester, Finder finder) async {
    await pumpUntil(tester, () => finder.evaluate().isNotEmpty);
    expect(finder, findsOneWidget);
  }

  /// What `appearance.json` says, once it says it.
  Future<void> expectAppearanceFile(WidgetTester tester, Map<String, Object?> expected) async {
    Object? read() {
      try {
        return jsonDecode(File('${dir.path}/${ThemeLibrary.fileName}').readAsStringSync());
      } on Object {
        return null;
      }
    }

    await pumpUntil(tester, () => jsonEncode(read()) == jsonEncode(expected));
    // Nothing left of writing it.
    expect(dir.listSync().where((entry) => entry.path.contains('${ThemeLibrary.fileName}.')), isEmpty);
  }

  /// Installs a theme file's theme, before the library is read.
  Future<void> install(WidgetTester tester, Uint8List file) =>
      tester.runAsync(() => ThemeStore(Directory('${dir.path}/themes')).install(readThemePackageNow(file)));

  /// The section by itself, in an app that follows the theme chosen.
  Widget section(ThemeLibrary library, {Future<String?> Function()? pick}) => ProviderScope(
    overrides: [themeLibraryProvider.overrideWithValue(library)],
    child: Consumer(
      builder: (context, ref, _) => MaterialApp(
        theme: ref.watch(themeDataProvider).light,
        home: Scaffold(
          body: ListView(children: [AppearanceSettings(pickFile: pick ?? () async => null)]),
        ),
      ),
    ),
  );

  testWidgets('Settings: the mode and the theme change the app as they are chosen', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await install(
      tester,
      syntheticThemeBytes(
        light: {'header': '#336699'},
        dark: {'header': '#223344'},
        assets: {'logo': 'logo.png'},
        extra: {'appName': 'Test Chat'},
      ),
    );
    final library = ThemeLibrary.load(dir);
    await tester.pumpWidget(testApp(testRepository(), overrides: [themeLibraryProvider.overrideWithValue(library)]));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('appearance-mode'));
    await tester.scrollUntilVisible(
      mode,
      200,
      scrollable: find.descendant(of: find.byType(SettingsPane), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    BuildContext settings() => tester.element(find.byType(SettingsPane));
    Finder logo(Finder what) => find.descendant(of: find.byType(HanashiLogo), matching: what);
    Finder checked(String id) =>
        find.descendant(of: find.byKey(ValueKey('theme-$id')), matching: find.byIcon(Icons.check));
    // Default: the app's name, no picture.
    expect(Theme.of(settings()).brightness, Brightness.light);
    expect(logo(find.byType(Image)), findsNothing);
    expect(logo(find.text(appTitle)), findsOneWidget);
    expect(checked(defaultThemeId), findsOneWidget);

    await tester.tap(find.descendant(of: mode, matching: find.text('Dark')));
    await tester.pumpAndSettle();
    expect(Theme.of(settings()).brightness, Brightness.dark);
    expect(settings().palette, HanashiPalette.dark);
    expect(library.appearance, const Appearance(themeId: defaultThemeId, mode: ThemeMode.dark));

    // A theme with a logo and a name for the app: both, the name written (the
    // theme has no wordmark), in the theme's dark colours; Settings say it.
    await tester.tap(find.byKey(const ValueKey('theme-test-theme')));
    await tester.pumpAndSettle();
    expect(logo(find.byType(Image)), findsOneWidget);
    expect(logo(find.text('Test Chat')), findsOneWidget);
    expect(logo(find.text(appTitle)), findsNothing);
    // Android's list of recent apps shows it.
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Test Chat');
    expect(settings().palette.header, const Color(0xFF223344));
    expect(checked('test-theme'), findsOneWidget);
    expect(checked(defaultThemeId), findsNothing);
    await expectAppearanceFile(tester, {'theme': 'test-theme', 'mode': 'dark'});

    await tester.tap(find.descendant(of: mode, matching: find.text('System')));
    await tester.pumpAndSettle();
    expect(Theme.of(settings()).brightness, Brightness.light);
    expect(settings().palette.header, const Color(0xFF336699));
  });

  testWidgets('theme files: added, replaced only if the user says so, and removed', (tester) async {
    final library = ThemeLibrary.load(dir);
    String? picked;
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(section(library, pick: () async => picked));
    await tester.pumpAndSettle();
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Built in'), findsNWidgets(builtInThemes.length));
    // Built-in themes have no menu to remove them.
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // Picking no file adds nothing.
    await tester.tap(find.byKey(const Key('import-theme')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    // A theme's file adds it, and shows it.
    picked = (File('${dir.path}/theme.zip')..writeAsBytesSync(syntheticThemeBytes())).path;
    await tester.tap(find.byKey(const Key('import-theme')));
    await tester.pump();
    // Busy meanwhile.
    expect(tester.widget<ListTile>(find.byKey(const Key('import-theme'))).enabled, isFalse);
    await pumpUntilShown(tester, find.text('Added the theme Test theme'));
    expect(tester.widget<ListTile>(find.byKey(const Key('import-theme'))).enabled, isTrue);
    final mine = find.byKey(const ValueKey('theme-test-theme'));
    expect(find.descendant(of: mine, matching: find.text('Hanashi tests')), findsOneWidget);
    expect(find.descendant(of: mine, matching: find.byIcon(Icons.check)), findsOneWidget);
    expect(library.appearance.themeId, 'test-theme');
    expect(tester.element(mine).palette.header, const Color(0xFF336699));

    // One the user has: only if they say so.
    picked = (File('${dir.path}/newer.zip')..writeAsBytesSync(syntheticThemeBytes(title: 'Test theme 2'))).path;
    await tester.tap(find.byKey(const Key('import-theme')));
    await pumpUntilShown(tester, find.text('Replace "Test theme"?'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Test theme'), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-theme')));
    await pumpUntilShown(tester, find.text('Replace "Test theme"?'));
    await tester.tap(find.text('Replace'));
    await pumpUntilShown(tester, find.text('Added the theme Test theme 2'));
    expect(find.text('Test theme 2'), findsOneWidget);
    expect(find.text('Test theme'), findsNothing);

    // Anything else says what is wrong with it.
    picked = (File('${dir.path}/notes.zip')..writeAsStringSync('not a zip')).path;
    await tester.tap(find.byKey(const Key('import-theme')));
    await pumpUntilShown(tester, find.text('This is not a theme: it has no pack.json'));

    // Gone from its menu: Default shows in its place.
    await tester.tap(find.byKey(const ValueKey('theme-menu-test-theme')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove theme…'));
    await tester.pumpAndSettle();
    expect(find.text('Remove "Test theme 2"?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await pumpUntil(tester, () => find.byKey(const ValueKey('theme-test-theme')).evaluate().isEmpty);
    expect(
      find.descendant(of: find.byKey(const ValueKey('theme-$defaultThemeId')), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(library.appearance.themeId, defaultThemeId);
    expect(Directory('${dir.path}/themes/test-theme').existsSync(), isFalse);
  });

  testWidgets("Add to home screen: the theme shown, where the launcher takes shortcuts", (tester) async {
    await install(tester, syntheticThemeBytes(extra: {'appName': 'Test Chat'}));
    File('${dir.path}/${ThemeLibrary.fileName}').writeAsStringSync(jsonEncode({'theme': 'test-theme'}));
    final library = ThemeLibrary.load(dir);
    final launcher = _FakeLauncher();
    await setSurfaceSize(tester, const Size(400, 860));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [themeLibraryProvider.overrideWithValue(library), themeLauncherProvider.overrideWithValue(launcher)],
        child: MaterialApp(
          home: Scaffold(body: ListView(children: const [AppearanceSettings()])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pin = find.byKey(const Key('pin-theme'));
    expect(find.descendant(of: pin, matching: find.textContaining('Test Chat')), findsOneWidget);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect([for (final theme in launcher.pinned) theme.id], ['test-theme']);

    // Where the launcher takes none, it is not offered.
    launcher.canPin = false;
    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('again'),
        overrides: [themeLibraryProvider.overrideWithValue(library), themeLauncherProvider.overrideWithValue(launcher)],
        child: MaterialApp(
          home: Scaffold(body: ListView(children: const [AppearanceSettings()])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pin-theme')), findsNothing);
  });
}

class _FakeLauncher implements ThemeLauncher {
  var canPin = true;
  final pinned = <AppTheme>[];

  @override
  Future<bool> supported() async => canPin;

  @override
  Future<bool> pin(AppTheme theme) async {
    pinned.add(theme);
    return true;
  }

  @override
  Future<void> follow(AppTheme theme) async {}
}
