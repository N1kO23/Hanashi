import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/app.dart';
import 'package:hanashi/data/chat_repository.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/data/remote/link_previews.dart';
import 'package:hanashi/data/themes/appearance.dart';
import 'package:hanashi/data/themes/builtin_themes.dart';
import 'package:hanashi/data/themes/theme_library.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/window/window_controls.dart';

/// Fixed "now" so that rendered times and dates never change.
final testNow = DateTime(2026, 10, 22, 18, 30);

MockChatRepository testRepository() =>
    MockChatRepository(latency: Duration.zero, autoReply: false, now: testNow);

/// [linkPreviews] makes link previews; by default, there are none to be
/// had (tests never go online).
Widget testApp(
  ChatRepository repository, {
  WindowControls? windowControls,
  LinkPreviewFetcher? linkPreviews,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: [
    appGateProvider.overrideWithValue(AppGate.ready),
    chatRepositoryProvider.overrideWithValue(repository),
    secureStoreProvider.overrideWithValue(MemorySecureStore()),
    clockProvider.overrideWithValue(() => testNow),
    windowControlsProvider.overrideWithValue(windowControls),
    linkPreviewFetcherProvider.overrideWithValue(
      linkPreviews ?? LinkPreviewFetcher(client: MockClient((_) async => http.Response('', 404))),
    ),
    ...overrides,
  ],
  child: const HanashiApp(),
);

/// Records window actions instead of touching a real window.
class FakeWindowControls implements WindowControls {
  final calls = <String>[];
  var maximized = false;
  final _changes = StreamController<bool>.broadcast(sync: true);

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> toggleMaximize() async {
    calls.add('toggleMaximize');
    maximized = !maximized;
    _changes.add(maximized);
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> startDragging() async => calls.add('startDragging');

  @override
  Future<void> setFullScreen(bool fullScreen) async => calls.add(fullScreen ? 'fullScreen' : 'leaveFullScreen');

  @override
  Stream<bool> watchMaximized() async* {
    yield maximized;
    yield* _changes.stream;
  }
}

/// The themes of a device that shows [theme] in [mode], kept in memory.
Override themesShowing({String theme = defaultThemeId, ThemeMode mode = ThemeMode.system}) {
  final library = ThemeLibrary.load(null);
  unawaited(library.setAppearance(Appearance(themeId: theme, mode: mode)));
  return themeLibraryProvider.overrideWithValue(library);
}

Future<void> setSurfaceSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Loads Roboto and Material Icons from the Flutter SDK, and the quick
/// reactions' emoji, so golden images show real text instead of the test
/// font's boxes.
Future<void> loadRealFonts() async {
  final fontsDir = _flutterFontsDir();
  Future<ByteData> font(String name) async =>
      ByteData.sublistView(await File('${fontsDir.path}/$name').readAsBytes());

  final roboto = FontLoader('Roboto');
  for (final style in ['Regular', 'Medium', 'Bold', 'Italic', 'BoldItalic']) {
    roboto.addFont(font('Roboto-$style.ttf'));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(font('MaterialIcons-Regular.otf'))).load();
  final emoji = File('test/fonts/NotoColorEmoji-reactions.ttf').readAsBytes();
  await (FontLoader('Noto Color Emoji')..addFont(emoji.then(ByteData.sublistView))).load();
}

Directory _flutterFontsDir() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidates = [
    if (root != null) Directory(root),
    // flutter_tester lives at <root>/bin/cache/artifacts/engine/<platform>/.
    File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent,
  ];
  for (final dir in candidates) {
    final fonts = Directory('${dir.path}/bin/cache/artifacts/material_fonts');
    if (fonts.existsSync()) return fonts;
  }
  throw StateError('Could not locate the Flutter SDK material_fonts directory');
}
