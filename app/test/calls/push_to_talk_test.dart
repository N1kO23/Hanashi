import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/calls/push_to_talk.dart';

/// The desktop portal as a test has it, on a bus of its own: the host
/// registry and GlobalShortcuts, answering as xdg-desktop-portal and KDE's
/// backend do (a dialog the first time a shortcut is bound, the key kept
/// after; answers as Response signals on the request's path).
class _Portal extends DBusObject {
  _Portal(this.bus) : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  final DBusClient bus;

  /// Register fails so, if set (as for an app without a desktop file).
  String? notRegistered;
  final registered = <String>[];

  /// The key the user gives in the dialog the first time; null: they say no.
  String? given;

  /// The key kept, once given.
  String? key;
  var dialogs = 0;
  final offered = <String?>[];
  var configured = 0;
  final sessions = <DBusObjectPath>[];
  final closed = <DBusObjectPath>[];

  static const _shortcuts = 'org.freedesktop.portal.GlobalShortcuts';

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final values = methodCall.values;
    switch ((methodCall.interface, methodCall.name)) {
      case ('org.freedesktop.host.portal.Registry', 'Register'):
        if (notRegistered case final why?) {
          return DBusMethodErrorResponse('org.freedesktop.portal.Error.Failed', [DBusString(why)]);
        }
        registered.add(values[0].asString());
        return DBusMethodSuccessResponse();
      case (_shortcuts, 'CreateSession'):
        final options = values[0].asStringVariantDict();
        final session = DBusObjectPath(
          '/org/freedesktop/portal/desktop/session/${_sender(methodCall)}/${options['session_handle_token']!.asString()}',
        );
        sessions.add(session);
        await bus.registerObject(_Session(session, this));
        return _answer(methodCall, options, {'session_handle': DBusString(session.value)});
      case (_shortcuts, 'BindShortcuts'):
        final shortcut = values[1].asArray().single.asStruct();
        offered.add(shortcut[1].asStringVariantDict()['preferred_trigger']?.asString());
        final options = values[3].asStringVariantDict();
        if (key == null) {
          dialogs++;
          key = given;
          if (key == null) return _answer(methodCall, options, const {}, code: 1);
        }
        return _answer(methodCall, options, {'shortcuts': _keys()});
      case (_shortcuts, 'ListShortcuts'):
        return _answer(methodCall, values[1].asStringVariantDict(), {'shortcuts': _keys()});
      case (_shortcuts, 'ConfigureShortcuts'):
        configured++;
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  DBusArray _keys() => DBusArray(DBusSignature('(sa{sv})'), [
    DBusStruct([
      const DBusString(DesktopShortcut.id),
      DBusDict.stringVariant({
        'description': const DBusString('Push to talk in Hanashi calls'),
        'trigger_description': DBusString(key ?? ''),
      }),
    ]),
  ]);

  /// The request's path in the reply, the answer after it.
  DBusMethodResponse _answer(
    DBusMethodCall methodCall,
    Map<String, DBusValue> options,
    Map<String, DBusValue> results, {
    int code = 0,
  }) {
    final request = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/${_sender(methodCall)}/${options['handle_token']!.asString()}',
    );
    Timer.run(
      () => bus.emitSignal(
        destination: methodCall.sender,
        path: request,
        interface: 'org.freedesktop.portal.Request',
        name: 'Response',
        values: [DBusUint32(code), DBusDict.stringVariant(results)],
      ),
    );
    return DBusMethodSuccessResponse([request]);
  }

  static String _sender(DBusMethodCall methodCall) => methodCall.sender!.substring(1).replaceAll('.', '_');

  /// The user holds the key ([down]) or lets go, as [session] has it.
  Future<void> press(DBusObjectPath session, bool down) => bus.emitSignal(
    path: path,
    interface: _shortcuts,
    name: down ? 'Activated' : 'Deactivated',
    values: [session, const DBusString(DesktopShortcut.id), const DBusUint64(0), DBusDict.stringVariant(const {})],
  );
}

class _Session extends DBusObject {
  _Session(super.path, this.portal);

  final _Portal portal;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.freedesktop.portal.Session' && methodCall.name == 'Close') {
      portal.closed.add(path);
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  late DBusServer server;
  late Directory dir;
  late DBusAddress address;
  late DBusClient portalBus;
  late _Portal portal;

  setUp(() async {
    server = DBusServer();
    dir = await Directory.systemTemp.createTemp('hanashi-dbus');
    address = await server.listenAddress(DBusAddress.unix(dir: dir));
    portalBus = DBusClient(address);
    await portalBus.requestName('org.freedesktop.portal.Desktop');
    portal = _Portal(portalBus);
    await portalBus.registerObject(portal);
  });

  tearDown(() async {
    await portalBus.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  test(
    'the key in every app: asked for once, under Hanashi\'s name; held and let go; the session closed after',
    () async {
      portal.given = 'F13';
      final key = await DesktopShortcut.open(client: DBusClient(address));
      expect(portal.registered, [DesktopShortcut.appId], reason: 'told first, on its own connection');
      expect(await key.current(), isNull, reason: 'none yet, and nobody asked');
      expect(portal.dialogs, 0);
      expect(await key.bind(preferred: 'F13'), 'F13');
      expect(portal.dialogs, 1);
      expect(portal.offered, ['F13']);

      final held = <bool>[];
      final listening = key.held.listen(held.add);
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 250 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      // Its match rules in place first: one more round trip.
      await key.current();
      // Another app's session is none of its business.
      await portal.press(DBusObjectPath('/org/freedesktop/portal/desktop/session/1_99/other'), true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(held, isEmpty);
      // Held, then let go (by a person: not in the same moment).
      await portal.press(portal.sessions.single, true);
      await until(() => held.isNotEmpty);
      expect(held, [true]);
      await portal.press(portal.sessions.single, false);
      await until(() => held.length == 2);
      expect(held, [true, false]);

      await key.change();
      expect(portal.configured, 1);
      await listening.cancel();
      await key.close();
      expect(portal.closed, portal.sessions);

      // The next call's session: the key kept, nobody asked again.
      final again = await DesktopShortcut.open(client: DBusClient(address));
      expect(await again.bind(preferred: 'F13'), 'F13');
      expect(portal.dialogs, 1);
      await again.close();
    },
  );

  test('said no in the dialog: no key, and not asked as an error', () async {
    final key = await DesktopShortcut.open(client: DBusClient(address));
    expect(await key.bind(), isNull);
    expect(portal.offered, [null]);
    await key.close();
  });

  test("Hanashi not installed with its desktop file: says so, and opens nothing", () async {
    portal.notRegistered = "App info not found for 'app.nullpointr.hanashi'";
    await expectLater(
      DesktopShortcut.open(client: DBusClient(address)),
      throwsA(isA<DesktopShortcutException>().having((e) => e.message, 'message', contains('desktop file'))),
    );
    expect(portal.sessions, isEmpty);
  });

  test('a desktop without the portal: says so', () async {
    await portalBus.releaseName('org.freedesktop.portal.Desktop');
    await expectLater(
      DesktopShortcut.open(client: DBusClient(address)),
      throwsA(isA<DesktopShortcutException>().having((e) => e.message, 'message', contains('no shortcuts'))),
    );
  });

  test('the key offered to the desktop by its name there', () {
    expect(desktopKeyName(PhysicalKeyboardKey.f13.usbHidUsage), 'F13');
    expect(desktopKeyName(PhysicalKeyboardKey.keyA.usbHidUsage), 'a');
    expect(desktopKeyName(PhysicalKeyboardKey.keyZ.usbHidUsage), 'z');
    expect(desktopKeyName(PhysicalKeyboardKey.digit1.usbHidUsage), '1');
    expect(desktopKeyName(PhysicalKeyboardKey.digit0.usbHidUsage), '0');
    expect(desktopKeyName(PhysicalKeyboardKey.backquote.usbHidUsage), 'grave');
    expect(desktopKeyName(PhysicalKeyboardKey.pause.usbHidUsage), 'Pause');
    // A modifier alone is no shortcut there.
    expect(desktopKeyName(PhysicalKeyboardKey.controlRight.usbHidUsage), isNull);
  });
}
