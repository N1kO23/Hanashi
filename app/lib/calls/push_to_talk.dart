import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_controller.dart';

/// Push to talk: the voice goes out while something is held. A key while
/// Hanashi is in front, the desktop's own key in every app (Linux, see
/// [DesktopShortcut]), or a talk button in the call. The state is whether
/// any of them is held; the voice gate opens with it.
final pushToTalkProvider = NotifierProvider<PushToTalkController, bool>(PushToTalkController.new);

class PushToTalkController extends Notifier<bool> {
  /// What holds it now: the key, the desktop's key, buttons.
  final _held = <Object>{};

  /// The key while Hanashi is in front.
  static const keyboard = #keyboard;

  /// The desktop's key, in every app.
  static const desktop = #desktop;

  @override
  bool build() {
    final settings = ref.watch(voiceGateSettingsProvider).value;
    final key = settings != null && settings.pushToTalk ? settings.pushKey : null;
    if (key != null) {
      bool handle(KeyEvent event) {
        if (event.physicalKey.usbHidUsage != key) return false;
        if (event is KeyDownEvent) hold(keyboard, true);
        if (event is KeyUpEvent) hold(keyboard, false);
        // It still does whatever else it does (types, where it types).
        return false;
      }

      HardwareKeyboard.instance.addHandler(handle);
      ref.onDispose(() => HardwareKeyboard.instance.removeHandler(handle));
    }
    // Settings changed while something was held: let go.
    if (_held.isNotEmpty) {
      _held.clear();
      ref.read(voiceGateProvider).push(false);
    }
    return false;
  }

  /// [source] is held ([down]) or let go.
  void hold(Object source, bool down) {
    if (!ref.mounted) return;
    final changed = down ? _held.add(source) : _held.remove(source);
    if (!changed) return;
    final held = _held.isNotEmpty;
    if (held == state) return;
    state = held;
    ref.read(voiceGateProvider).push(held);
  }

  /// Nothing holds it any more (the call is over).
  void releaseAll() {
    _held.clear();
    if (!ref.mounted || !state) return;
    state = false;
    ref.read(voiceGateProvider).push(false);
  }
}

/// A session of the desktop's push-to-talk key for Hanashi, in every app
/// ([DesktopShortcut]; a fake in tests).
abstract class DesktopKey {
  /// The key, asking the user the first time (offering [preferred]); null
  /// if none.
  Future<String?> bind({String? preferred});

  /// The key, without asking: null if none (yet).
  Future<String?> current();

  /// Opens the desktop's own settings for the key.
  Future<void> change();

  /// True while it is held, false once let go (after [bind]).
  Stream<bool> get held;

  Future<void> close();
}

/// Opens a session of the desktop's key, where there can be one (Linux);
/// throws a [DesktopShortcutException] saying why not.
final desktopKeyProvider = Provider<Future<DesktopKey> Function()?>(
  (ref) => Platform.isLinux ? () => DesktopShortcut.open() : null,
);

/// What the desktop says of the key, for Settings: the key, or none yet;
/// or why there can be none ([DesktopKeyState.unavailable]).
final desktopKeyStateProvider = FutureProvider.autoDispose<DesktopKeyState?>((ref) async {
  final open = ref.watch(desktopKeyProvider);
  if (open == null) return null;
  try {
    final key = await open();
    try {
      return DesktopKeyState(key: await key.current());
    } finally {
      await key.close();
    }
  } on DesktopShortcutException catch (e) {
    return DesktopKeyState(unavailable: e.message);
  }
});

class DesktopKeyState {
  const DesktopKeyState({this.key, this.unavailable});

  final String? key;

  /// Why the desktop can have no key for Hanashi.
  final String? unavailable;
}

/// Why the desktop has no push-to-talk key for Hanashi in every app, in
/// words for the user.
class DesktopShortcutException implements Exception {
  const DesktopShortcutException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The push-to-talk key in every app, kept by the desktop: the XDG desktop
/// portal's GlobalShortcuts (KDE Plasma, GNOME), on Linux. The desktop asks
/// the user once which key, files it under Hanashi's app ID, and tells while
/// it is held. Hanashi keeps a session open only during calls, so the key is
/// the desktop's to give elsewhere the rest of the time.
///
/// The desktop knows the app ID only from an installed desktop file
/// (`app.nullpointr.hanashi.desktop`, which the packages install): without
/// it there is no key in every app, rather than one filed under whatever ran
/// Hanashi (a terminal, an editor), or asked for at every call.
class DesktopShortcut implements DesktopKey {
  DesktopShortcut._(this._client, this._session);

  static const appId = 'app.nullpointr.hanashi';
  static const id = 'push-to-talk';
  static const _portal = 'org.freedesktop.portal.Desktop';
  static const _shortcuts = 'org.freedesktop.portal.GlobalShortcuts';
  static final _desktop = DBusObjectPath('/org/freedesktop/portal/desktop');
  static var _tokens = 0;

  final DBusClient _client;
  final DBusObjectPath _session;

  /// A session of the desktop's shortcuts for Hanashi, on a connection of
  /// its own ([client], else the session bus): the app ID can be told only
  /// before anything else is asked on it. Throws a
  /// [DesktopShortcutException] where there is none.
  static Future<DesktopShortcut> open({DBusClient? client}) async {
    final bus = client ?? DBusClient.session();
    try {
      try {
        await bus.callMethod(
          destination: _portal,
          path: _desktop,
          interface: 'org.freedesktop.host.portal.Registry',
          name: 'Register',
          values: [const DBusString(appId), DBusDict.stringVariant(const {})],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException catch (e) {
        throw DesktopShortcutException(switch (e.errorName) {
          'org.freedesktop.DBus.Error.ServiceUnknown' => 'Your desktop has no shortcuts for apps',
          'org.freedesktop.DBus.Error.UnknownMethod' ||
          'org.freedesktop.DBus.Error.UnknownInterface' => "Your desktop can't tell Hanashi apart from other apps",
          _ when '$e'.contains('not found') =>
            "Hanashi isn't installed with its desktop file, so your desktop can't keep a key for it",
          _ => "Your desktop didn't take Hanashi's name: ${e.errorName}",
        });
      }
      final created = await _request(
        bus,
        (token) => bus.callMethod(
          destination: _portal,
          path: _desktop,
          interface: _shortcuts,
          name: 'CreateSession',
          values: [
            DBusDict.stringVariant({
              'handle_token': DBusString(token),
              'session_handle_token': DBusString('${token}s'),
            }),
          ],
          replySignature: DBusSignature('o'),
        ),
      );
      final handle = created['session_handle'];
      if (handle == null) throw const DesktopShortcutException('Your desktop gave no shortcuts session');
      return DesktopShortcut._(bus, DBusObjectPath(handle.asString()));
    } on DBusMethodResponseException catch (e) {
      await bus.close();
      throw DesktopShortcutException(
        e.errorName == 'org.freedesktop.DBus.Error.UnknownMethod' ||
                e.errorName == 'org.freedesktop.DBus.Error.UnknownInterface'
            ? 'Your desktop has no shortcuts for apps'
            : 'Your desktop has no shortcuts for Hanashi: ${e.errorName}',
      );
    } catch (e) {
      await bus.close();
      rethrow;
    }
  }

  /// The key for push to talk, asking the user the first time (the desktop's
  /// own dialog, offering [preferred]); later, the one they gave. Null if
  /// none: they gave none, or said no.
  @override
  Future<String?> bind({String? preferred}) async {
    try {
      final results = await _request(
        _client,
        (token) => _client.callMethod(
          destination: _portal,
          path: _desktop,
          interface: _shortcuts,
          name: 'BindShortcuts',
          values: [
            _session,
            DBusArray(DBusSignature('(sa{sv})'), [
              DBusStruct([
                const DBusString(id),
                DBusDict.stringVariant({
                  'description': const DBusString('Push to talk in Hanashi calls'),
                  'preferred_trigger': ?(preferred == null ? null : DBusString(preferred)),
                }),
              ]),
            ]),
            const DBusString(''),
            DBusDict.stringVariant({'handle_token': DBusString(token)}),
          ],
          replySignature: DBusSignature('o'),
        ),
      );
      return _trigger(results);
    } on _Cancelled {
      return null;
    }
  }

  /// The key the desktop has for push to talk, without asking anyone: null
  /// if none (yet).
  @override
  Future<String?> current() async {
    try {
      final results = await _request(
        _client,
        (token) => _client.callMethod(
          destination: _portal,
          path: _desktop,
          interface: _shortcuts,
          name: 'ListShortcuts',
          values: [
            _session,
            DBusDict.stringVariant({'handle_token': DBusString(token)}),
          ],
          replySignature: DBusSignature('o'),
        ),
      );
      return _trigger(results);
    } on _Cancelled {
      return null;
    }
  }

  /// Opens the desktop's own settings for Hanashi's keys (portal version
  /// 2), to choose another.
  @override
  Future<void> change() => _client.callMethod(
    destination: _portal,
    path: _desktop,
    interface: _shortcuts,
    name: 'ConfigureShortcuts',
    values: [_session, const DBusString(''), DBusDict.stringVariant(const {})],
    replySignature: DBusSignature(''),
  );

  /// True while the desktop's key is held, false once let go.
  @override
  Stream<bool> get held {
    final subscriptions = <StreamSubscription<DBusSignal>>[];
    late final StreamController<bool> held;
    held = StreamController<bool>(
      onListen: () {
        for (final (name, down) in [('Activated', true), ('Deactivated', false)]) {
          subscriptions.add(
            DBusSignalStream(_client, interface: _shortcuts, name: name, path: _desktop)
                .where((s) => s.values.length >= 2 && s.values[0] == _session && s.values[1] == const DBusString(id))
                .listen((_) => held.add(down)),
          );
        }
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
    return held.stream;
  }

  /// The session over (the key is the desktop's again), and the connection.
  @override
  Future<void> close() async {
    try {
      await _client.callMethod(
        destination: _portal,
        path: _session,
        interface: 'org.freedesktop.portal.Session',
        name: 'Close',
        replySignature: DBusSignature(''),
      );
    } on DBusMethodResponseException {
      // Gone already.
    }
    await _client.close();
  }

  static String? _trigger(Map<String, DBusValue> results) {
    final shortcuts = results['shortcuts'];
    if (shortcuts is! DBusArray) return null;
    for (final shortcut in shortcuts.children) {
      if (shortcut is! DBusStruct || shortcut.children.length < 2) continue;
      if (shortcut.children[0] != const DBusString(id)) continue;
      final described = shortcut.children[1].asStringVariantDict()['trigger_description']?.asString() ?? '';
      return described.isEmpty ? null : described;
    }
    return null;
  }

  /// One of the portal's requests: the answer comes as a Response signal on
  /// the request's own path, which follows from the connection's name and
  /// [call]'s token. Listened to before the call.
  static Future<Map<String, DBusValue>> _request(
    DBusClient client,
    Future<DBusMethodSuccessResponse> Function(String token) call,
  ) async {
    final token = 'hanashi${++_tokens}';
    final sender = client.uniqueName.replaceFirst(':', '').replaceAll('.', '_');
    final path = DBusObjectPath('/org/freedesktop/portal/desktop/request/$sender/$token');
    final answered = DBusSignalStream(
      client,
      interface: 'org.freedesktop.portal.Request',
      name: 'Response',
      path: path,
      signature: DBusSignature('ua{sv}'),
    ).first;
    final reply = await call(token);
    final asked = reply.returnValues.first.asObjectPath();
    // An older portal may answer on a path of its own.
    final response = asked == path
        ? await answered
        : await DBusSignalStream(
            client,
            interface: 'org.freedesktop.portal.Request',
            name: 'Response',
            path: asked,
            signature: DBusSignature('ua{sv}'),
          ).first;
    final code = response.values[0].asUint32();
    if (code == 1) throw const _Cancelled();
    if (code != 0) throw const DesktopShortcutException("Your desktop didn't do it");
    return response.values[1].asStringVariantDict();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// The desktop's name for [key] (the XDG shortcut format: a keysym name), to
/// offer it as the key in every app; null where there is no plain one.
/// Modifiers alone are no shortcut there.
String? desktopKeyName(int usbHidUsage) {
  final key = PhysicalKeyboardKey(usbHidUsage);
  final named = _desktopNames[key];
  if (named != null) return named;
  // Letters and digits by their HID usage: a = 0x04 ... z = 0x1d, 1 = 0x1e
  // ... 9 = 0x26, 0 = 0x27, in the keyboard page (0x0007_00xx).
  final usage = usbHidUsage & 0xffff;
  if (usbHidUsage >> 16 == 0x7 && usage >= 0x04 && usage <= 0x1d) {
    return String.fromCharCode(0x61 + usage - 0x04);
  }
  if (usbHidUsage >> 16 == 0x7 && usage >= 0x1e && usage <= 0x27) return usage == 0x27 ? '0' : '${usage - 0x1d}';
  return null;
}

final _desktopNames = <PhysicalKeyboardKey, String>{
  PhysicalKeyboardKey.f1: 'F1',
  PhysicalKeyboardKey.f2: 'F2',
  PhysicalKeyboardKey.f3: 'F3',
  PhysicalKeyboardKey.f4: 'F4',
  PhysicalKeyboardKey.f5: 'F5',
  PhysicalKeyboardKey.f6: 'F6',
  PhysicalKeyboardKey.f7: 'F7',
  PhysicalKeyboardKey.f8: 'F8',
  PhysicalKeyboardKey.f9: 'F9',
  PhysicalKeyboardKey.f10: 'F10',
  PhysicalKeyboardKey.f11: 'F11',
  PhysicalKeyboardKey.f12: 'F12',
  PhysicalKeyboardKey.f13: 'F13',
  PhysicalKeyboardKey.f14: 'F14',
  PhysicalKeyboardKey.f15: 'F15',
  PhysicalKeyboardKey.f16: 'F16',
  PhysicalKeyboardKey.f17: 'F17',
  PhysicalKeyboardKey.f18: 'F18',
  PhysicalKeyboardKey.f19: 'F19',
  PhysicalKeyboardKey.f20: 'F20',
  PhysicalKeyboardKey.f21: 'F21',
  PhysicalKeyboardKey.f22: 'F22',
  PhysicalKeyboardKey.f23: 'F23',
  PhysicalKeyboardKey.f24: 'F24',
  PhysicalKeyboardKey.backquote: 'grave',
  PhysicalKeyboardKey.scrollLock: 'Scroll_Lock',
  PhysicalKeyboardKey.pause: 'Pause',
  PhysicalKeyboardKey.insert: 'Insert',
  PhysicalKeyboardKey.home: 'Home',
  PhysicalKeyboardKey.end: 'End',
  PhysicalKeyboardKey.pageUp: 'Prior',
  PhysicalKeyboardKey.pageDown: 'Next',
  PhysicalKeyboardKey.contextMenu: 'Menu',
  PhysicalKeyboardKey.printScreen: 'Print',
  PhysicalKeyboardKey.numpad0: 'KP_0',
  PhysicalKeyboardKey.numpad1: 'KP_1',
  PhysicalKeyboardKey.numpad2: 'KP_2',
  PhysicalKeyboardKey.numpad3: 'KP_3',
  PhysicalKeyboardKey.numpad4: 'KP_4',
  PhysicalKeyboardKey.numpad5: 'KP_5',
  PhysicalKeyboardKey.numpad6: 'KP_6',
  PhysicalKeyboardKey.numpad7: 'KP_7',
  PhysicalKeyboardKey.numpad8: 'KP_8',
  PhysicalKeyboardKey.numpad9: 'KP_9',
};
