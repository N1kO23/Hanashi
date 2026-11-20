import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/themes/app_theme.dart';
import 'package:hanashi/data/themes/builtin_themes.dart';
import 'package:hanashi/notifications/notification_look.dart';
import 'package:hanashi/ui/theme/hanashi_theme.dart';

const _files = '/data/user/0/app.nullpointr.hanashi/files';

AppTheme _installed({String? sound = '$_files/themes/mine/messageSound.ogg', String? icon}) => AppTheme(
  id: 'mine',
  title: 'Mine',
  light: HanashiPalette.light,
  dark: HanashiPalette.dark,
  assets: ThemeAssets(
    messageSound: sound == null ? null : FileSource(sound),
    appIcon: icon == null ? null : FileSource(icon),
  ),
  origin: ThemeOrigin.imported,
);

SoundPlatform _android(int sdk) =>
    SoundPlatform(supportDir: Directory(_files), sdkInt: sdk, packageName: 'app.nullpointr.hanashi');

void main() {
  group('a theme\'s look', () {
    test('a sound bundled with the app: its asset', () {
      const bundled = AppTheme(
        id: 'bundled',
        title: 'Bundled',
        light: HanashiPalette.light,
        dark: HanashiPalette.dark,
        assets: ThemeAssets(
          messageSound: AssetSource('assets/sounds/chime.wav'),
          appIcon: AssetSource('assets/branding/chime.png'),
        ),
        origin: ThemeOrigin.builtIn,
      );
      final look = notificationLookOf(bundled, _android(34));
      expect(look.sound, const BundledSound('assets/sounds/chime.wav'));
      expect(look.icon, const AssetSource('assets/branding/chime.png'));
    });

    test("an installed theme's sound: its content URI from Android 9", () {
      for (final sdk in [28, 34]) {
        expect(
          notificationLookOf(_installed(), _android(sdk)).sound,
          const FileSound(
            '$_files/themes/mine/messageSound.ogg',
            androidUri: 'content://app.nullpointr.hanashi.themes/themes/mine/messageSound.ogg',
          ),
        );
      }
      for (final platform in [_android(26), _android(27), SoundPlatform(supportDir: Directory(_files))]) {
        expect(
          notificationLookOf(_installed(), platform).sound,
          const FileSound('$_files/themes/mine/messageSound.ogg'),
        );
      }
      // Not one of the themes the app's FileProvider serves.
      expect(
        notificationLookOf(_installed(sound: '/elsewhere/a.ogg'), _android(34)).sound,
        const FileSound('/elsewhere/a.ogg'),
      );
    });

    test("no sound of the theme's own: the system's; no icon: Default's", () {
      final look = notificationLookOf(_installed(sound: null), _android(34));
      expect(look.sound, const SystemSound());
      expect(look.icon, defaultTheme.assets.appIcon);
      expect(
        notificationLookOf(defaultTheme, const SoundPlatform()),
        const NotificationLook(icon: AssetSource('assets/branding/icon_default.png')),
      );
      expect(
        notificationLookOf(_installed(icon: '/x/appIcon.png'), const SoundPlatform()).icon,
        const FileSource('/x/appIcon.png'),
      );
    });
  });

  group('Android', () {
    SoundPlan plan(MessageSound sound, [String kind = 'messages']) =>
        planSound(sound, kind: kind, platform: TargetPlatform.android);

    test('a file: a channel of its own, named by its URI', () {
      const uri = 'content://app.nullpointr.hanashi.themes/themes/mine/messageSound.ogg';
      final file = plan(const FileSound('/x', androidUri: uri));
      expect(file.androidChannel, matches(RegExp(r'^messages_[0-9a-f]{8}$')));
      expect(file.androidSound, isA<UriAndroidNotificationSound>().having((s) => s.sound, 'sound', uri));
      expect(plan(const FileSound('/x', androidUri: uri)).androidChannel, file.androidChannel);
      expect(plan(const FileSound('/x', androidUri: '$uri.2')).androidChannel, isNot(file.androidChannel));
      expect(
        plan(const FileSound('/x', androidUri: uri), 'contacts').androidChannel,
        'contacts_${file.androidChannel.substring('messages_'.length)}',
      );
    });

    test("the system's sound, also for a file Android cannot play, and for an asset", () {
      for (final sound in [const SystemSound(), const FileSound('/x'), const BundledSound('a.wav')]) {
        final system = plan(sound);
        expect(system.androidChannel, 'messages_default');
        expect(system.androidSound, isNull);
        expect(system.inApp, isNull);
      }
    });

    test("the channels it tidies are this app's audible ones only", () {
      for (final id in ['messages_default', 'contacts_default', 'messages_0123abcd', 'contacts_0123abcd']) {
        expect(soundChannelPattern.hasMatch(id), isTrue, reason: id);
      }
      for (final id in [
        'messages_silent',
        'contacts_silent',
        'calls_ring',
        'calls_missed',
        'calls_ongoing',
        'messages',
        'messages_sound',
        'contacts_sound',
        'messages_0123ABCD',
        'messages_0123abcde',
      ]) {
        expect(soundChannelPattern.hasMatch(id), isFalse, reason: id);
      }
    });
  });

  group('Linux', () {
    SoundPlan plan(MessageSound sound, {bool serverPlays = true}) =>
        planSound(sound, kind: 'messages', platform: TargetPlatform.linux, linuxServerPlays: serverPlays);

    test('the notification server plays a bundled sound; the app does if it plays none', () {
      final bundled = plan(const BundledSound('assets/sounds/chime.wav'));
      expect(
        bundled.linuxSound,
        isA<AssetsLinuxSound>().having((s) => s.relativePath, 'path', 'assets/sounds/chime.wav'),
      );
      expect(bundled.inApp, isNull);
      expect(bundled.linuxSuppress, isFalse);
      final quiet = plan(const BundledSound('assets/sounds/chime.wav'), serverPlays: false);
      expect(quiet.linuxSound, isNull);
      expect(quiet.inApp, 'asset:///assets/sounds/chime.wav');
    });

    test("a file: the app plays it, and the server none of its own", () {
      for (final serverPlays in [true, false]) {
        final file = plan(const FileSound('/t/messageSound.ogg'), serverPlays: serverPlays);
        expect(file.inApp, '/t/messageSound.ogg');
        expect(file.linuxSound, isNull);
        expect(file.linuxSuppress, isTrue);
      }
    });

    test("no sound of the theme's own: the desktop's", () {
      expect(
        plan(const SystemSound()).linuxSound,
        isA<ThemeLinuxSound>().having((s) => s.name, 'name', 'message-new-instant'),
      );
      final quiet = plan(const SystemSound(), serverPlays: false);
      expect(quiet.linuxSound, isNull);
      expect(quiet.inApp, isNull);
    });
  });

  test('Windows and macOS: the app plays a theme\'s sound, over a silent notification', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      final bundled = planSound(const BundledSound('assets/sounds/chime.wav'), kind: 'messages', platform: platform);
      expect(bundled.silenced, isTrue);
      expect(bundled.inApp, 'asset:///assets/sounds/chime.wav');
      final file = planSound(const FileSound(r'C:\t\messageSound.wav'), kind: 'messages', platform: platform);
      expect(file.silenced, isTrue);
      expect(file.inApp, r'C:\t\messageSound.wav');
      final system = planSound(const SystemSound(), kind: 'messages', platform: platform);
      expect(system.silenced, isFalse);
      expect(system.inApp, isNull);
    }
  });

  test("iOS: the system's sound", () {
    final plan = planSound(
      const BundledSound('assets/sounds/chime.wav'),
      kind: 'messages',
      platform: TargetPlatform.iOS,
    );
    expect(plan.silenced, isFalse);
    expect(plan.inApp, isNull);
  });
}
