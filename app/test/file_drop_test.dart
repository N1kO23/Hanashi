import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:hanashi/ui/chat/file_drop.dart';

import 'support/test_app.dart';

/// Notes what would be sent, and the file's bytes at that moment.
class _Recording extends MockChatRepository {
  _Recording() : super(latency: Duration.zero, autoReply: false, now: testNow);

  final sent = <({String conv, String name, Uint8List bytes})>[];

  @override
  Future<void> sendAttachment(String conversationId, {required String path, required String name, String? replyTo}) async =>
      sent.add((conv: conversationId, name: name, bytes: File(path).readAsBytesSync()));
}

final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_drop_'));
  tearDown(() => dir.delete(recursive: true));

  Future<_Recording> openClubRoom(WidgetTester tester) async {
    final repository = _Recording();
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(repository));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    return repository;
  }

  /// A call from the platform side of a plugin.
  Future<void> fromPlatform(WidgetTester tester, String channel, String method, [Object? arguments]) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  void clipboardHolds(WidgetTester tester, {List<String> files = const [], Uint8List? image, String? text}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    const pasteboard = MethodChannel('pasteboard');
    messenger.setMockMethodCallHandler(pasteboard, (call) async => switch (call.method) {
      'files' => files,
      'image' => image,
      _ => null,
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => switch (call.method) {
      'Clipboard.hasStrings' => {'value': text != null},
      'Clipboard.getData' => text == null ? null : {'text': text},
      _ => null,
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pasteboard, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  Future<void> paste(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-field')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  /// Pumps until [finder] shows; files are read and written outside the
  /// test's fake clock.
  Future<void> pumpUntilShown(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(finder, findsOneWidget);
  }

  testWidgets('files dropped on a chat go out once confirmed; folders and links do not', (tester) async {
    final repository = await openClubRoom(tester);
    final photo = File('${dir.path}/cat.png')..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
    final notes = File('${dir.path}/notes.txt')..writeAsStringSync('Meeting at five.');
    final at = tester.getCenter(find.byType(FileDropTarget));

    await fromPlatform(tester, 'desktop_drop', 'entered', [at.dx, at.dy]);
    await tester.pump();
    expect(find.text('Drop files to send them to Club Room'), findsOneWidget);
    // GTK says the drag left just before the drop.
    await fromPlatform(tester, 'desktop_drop', 'exited');
    await tester.pump();
    expect(find.byKey(const Key('file-drop-overlay')), findsNothing);
    await fromPlatform(tester, 'desktop_drop', 'performOperation_linux', [
      [photo.uri, notes.uri, dir.uri, 'https://example.com/cat.png'].join('\n'),
      [at.dx, at.dy],
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Only files can be sent, not folders or links'), findsOneWidget);
    expect(find.text('Send 2 files to Club Room?'), findsOneWidget);
    expect(find.text('cat.png'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send-files-confirm')));
    await tester.pumpAndSettle();
    expect([for (final s in repository.sent) (s.conv, s.name)], [('club', 'cat.png'), ('club', 'notes.txt')]);

    // Changed their mind: nothing goes out.
    await fromPlatform(tester, 'desktop_drop', 'performOperation_linux', ['${notes.uri}', [at.dx, at.dy]]);
    await tester.pumpAndSettle();
    expect(find.text('Send to Club Room?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.sent, hasLength(2));
  }, variant: _desktop);

  testWidgets('a pasted image goes out as a picture once confirmed; text pastes as usual', (tester) async {
    final repository = await openClubRoom(tester);
    // As Windows hands it out.
    clipboardHolds(tester, image: img.encodeBmp(img.Image(width: 6, height: 4)));
    await paste(tester);
    await pumpUntilShown(tester, find.byKey(const Key('send-files-dialog')));
    expect(find.text('Send to Club Room?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send-files-confirm')));
    await tester.pumpAndSettle();
    final sent = repository.sent.single;
    expect(sent.name, matches(RegExp(r'^Pasted image \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d\.png$')));
    final png = img.decodePng(sent.bytes)!;
    expect((png.width, png.height), (6, 4));

    // Text, also next to an image (as spreadsheets copy cells), is text.
    clipboardHolds(tester, image: img.encodePng(img.Image(width: 2, height: 2)), text: 'Snacks at five');
    await paste(tester);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'Snacks at five');
    expect(find.byKey(const Key('send-files-dialog')), findsNothing);
    expect(repository.sent, hasLength(1));
  }, variant: _desktop);

  testWidgets('files copied in a file manager paste as files', (tester) async {
    final repository = await openClubRoom(tester);
    final notes = File('${dir.path}/notes.txt')..writeAsStringSync('Meeting at five.');
    clipboardHolds(tester, files: [notes.path, '${dir.path}/gone.txt'], text: notes.path);
    await paste(tester);
    await pumpUntilShown(tester, find.byKey(const Key('send-files-dialog')));
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send-files-confirm')));
    await tester.pumpAndSettle();
    expect([for (final s in repository.sent) (s.name, String.fromCharCodes(s.bytes))], [('notes.txt', 'Meeting at five.')]);
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, isEmpty);
  }, variant: _desktop);
}
