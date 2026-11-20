// Checks the desktop shell against the real desktop session (Linux):
// the tray icon, closing to the tray, and system notifications.
//   flutter test integration_test/desktop_shell_test.dart -d linux
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/desktop/tray.dart';
import 'package:hanashi/notifications/local_notifier.dart';
import 'package:hanashi/notifications/notification_center.dart';
import 'package:hanashi/ui/window/window_controls.dart';

/// The tray items the desktop knows about (StatusNotifierItem protocol).
Future<List<String>> trayItems() async {
  final result = await Process.run('dbus-send', [
    '--session',
    '--print-reply',
    '--dest=org.kde.StatusNotifierWatcher',
    '/StatusNotifierWatcher',
    'org.freedesktop.DBus.Properties.Get',
    'string:org.kde.StatusNotifierWatcher',
    'string:RegisteredStatusNotifierItems',
  ]);
  return [for (final m in RegExp(r'string "([^"]+)"').allMatches(result.stdout as String)) m[1]!];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('tray icon, close to tray, system notifications', (tester) async {
    if (!Platform.isLinux) return;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Hanashi'))));
    final hasTrayHost = (await tester.runAsync(trayItems))!.isNotEmpty;

    final before = (await tester.runAsync(trayItems))!;
    await tester.runAsync(() async {
      await initDesktopWindow();
      await DesktopTray.install();
    });
    // Let the test runner close the app afterwards (the tray keeps it alive).
    addTearDown(DesktopTray.uninstall);
    if (hasTrayHost) {
      // The icon shows up in the desktop's tray.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      List<String> after;
      do {
        after = (await tester.runAsync(trayItems))!;
        await tester.pump(const Duration(milliseconds: 100));
      } while (after.length <= before.length && DateTime.now().isBefore(deadline));
      expect(after.toSet().difference(before.toSet()), hasLength(1), reason: 'Hanashi registers one tray item');
    }

    // Closing the window (title bar X, Alt+F4) keeps the app running, hidden.
    await tester.runAsync(() async {
      // The tray's close listener takes hold a moment after it is added
      // (nativeapi sets it up on the window's own thread); a person never
      // closes the window that soon after the app starts.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(appWindow!.isVisible, isTrue);
      await NativeWindowControls(appWindow!).close();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(appWindow!.isVisible, isFalse);
      // Notifications pop up only when the app is not in the foreground.
      expect(WidgetsBinding.instance.lifecycleState, isNot(AppLifecycleState.resumed));
      await DesktopTray.showWindow();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(appWindow!.isVisible, isTrue);
    });

    // A message notification goes to the desktop's notification server.
    final monitor = (await tester.runAsync(
      () => Process.start('dbus-monitor', ['--session', "interface='org.freedesktop.Notifications',member='Notify'"]),
    ))!;
    final seen = StringBuffer();
    monitor.stdout.transform(utf8.decoder).listen(seen.write);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500)); // Monitor ready.
      final notifier = await LocalNotifier.create();
      await notifier.show(
        ChatNotification(
          conversationId: 'hanashi-test',
          title: 'Kumiko (Hanashi test)',
          isGroup: false,
          unread: 1,
          lines: [NotificationLine(sender: 'Kumiko', text: 'Notification check, Sota!', time: DateTime.now())],
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await notifier.cancel('hanashi-test');
    });
    monitor.kill();
    expect(seen.toString(), contains('Kumiko (Hanashi test)'));
    expect(seen.toString(), contains('Notification check, Sota!'));
    expect(seen.toString(), contains('im.received'));
  });
}
