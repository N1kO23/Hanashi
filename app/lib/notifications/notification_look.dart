import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hashlib/hashlib.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/themes/app_theme.dart';
import '../data/themes/builtin_themes.dart';

/// What new messages and contact requests sound like, from the theme shown
/// (see [ThemeAssets.messageSound]).
@immutable
sealed class MessageSound {
  const MessageSound();
}

/// No sound of the theme's own: the system's.
final class SystemSound extends MessageSound {
  const SystemSound();

  @override
  bool operator ==(Object other) => other is SystemSound;

  @override
  int get hashCode => 0;
}

/// A sound bundled with the app, an asset. Android's is the system's: a
/// notification channel plays no asset.
final class BundledSound extends MessageSound {
  const BundledSound(this.asset);

  final String asset;

  @override
  bool operator ==(Object other) => other is BundledSound && other.asset == asset;

  @override
  int get hashCode => asset.hashCode;
}

/// A sound of an installed theme: its file, and on Android 9 and later its
/// content URI ([androidUri]; without one, Android's is the system's).
final class FileSound extends MessageSound {
  const FileSound(this.path, {this.androidUri});

  final String path;
  final String? androidUri;

  @override
  bool operator ==(Object other) => other is FileSound && other.path == path && other.androidUri == androidUri;

  @override
  int get hashCode => Object.hash(path, androidUri);
}

/// What notifications sound and look like, from the theme shown.
@immutable
class NotificationLook {
  const NotificationLook({this.sound = const SystemSound(), this.icon});

  final MessageSound sound;

  /// The app's icon on Linux notifications.
  final ThemeSource? icon;

  @override
  bool operator ==(Object other) => other is NotificationLook && other.sound == sound && other.icon == icon;

  @override
  int get hashCode => Object.hash(sound, icon);
}

/// What decides whether this device can play a theme's sound file in its
/// notifications: Android's API level and the app's package, whose
/// FileProvider (see `AndroidManifest.xml`) serves `<support dir>/themes/`.
@immutable
class SoundPlatform {
  const SoundPlatform({this.supportDir, this.sdkInt, this.packageName});

  final Directory? supportDir;
  final int? sdkInt;
  final String? packageName;

  static Future<SoundPlatform> load(Directory supportDir) async {
    if (!Platform.isAndroid) return SoundPlatform(supportDir: supportDir);
    try {
      final (device, package) = await (DeviceInfoPlugin().androidInfo, PackageInfo.fromPlatform()).wait;
      return SoundPlatform(supportDir: supportDir, sdkInt: device.version.sdkInt, packageName: package.packageName);
    } on Object {
      // Theme sounds then play as the system's.
      return SoundPlatform(supportDir: supportDir);
    }
  }
}

/// How [theme]'s notifications sound and look on this device.
NotificationLook notificationLookOf(AppTheme theme, SoundPlatform platform) => NotificationLook(
  sound: switch (theme.assets.messageSound) {
    AssetSource(:final asset) => BundledSound(asset),
    FileSource(:final path) => FileSound(path, androidUri: _contentUri(path, platform)),
    null => const SystemSound(),
  },
  icon: theme.assets.appIcon ?? defaultTheme.assets.appIcon,
);

/// [path]'s content URI, if Android plays one from a notification channel
/// without the app granting it (Android 9 and later).
String? _contentUri(String path, SoundPlatform platform) {
  final (dir, sdk, package) = (platform.supportDir, platform.sdkInt, platform.packageName);
  if (dir == null || sdk == null || sdk < 28 || package == null) return null;
  final themes = '${dir.path}/themes/';
  if (!path.startsWith(themes)) return null;
  return 'content://$package.themes/themes/${path.substring(themes.length)}';
}

/// How one kind of notification ([kind]: `messages` or `contacts`) sounds on
/// one platform (see [planSound]).
@immutable
class SoundPlan {
  const SoundPlan({
    this.androidChannel = '',
    this.androidSound,
    this.linuxSound,
    this.linuxSuppress = false,
    this.silenced = false,
    this.inApp,
  });

  /// Android's channel for the audible ones: a channel keeps the sound it was
  /// made with, so each sound has one of its own, and its ID says which.
  final String androidChannel;
  final AndroidNotificationSound? androidSound;

  final LinuxNotificationSound? linuxSound;

  /// The Linux notification server must not play a sound of its own: the app
  /// plays one.
  final bool linuxSuppress;

  /// Windows and macOS: the notification is silent, the app plays the sound.
  final bool silenced;

  /// What the app plays itself, as media_kit takes it; null for none.
  final String? inApp;
}

/// Android channels this app makes for audible message and contact
/// notifications (see [SoundPlan.androidChannel]).
final soundChannelPattern = RegExp(r'^(messages|contacts)_(default|[0-9a-f]{8})$');

/// How [sound] plays for [kind] notifications on [platform]. Windows plays a
/// notification's own sound file only for MSIX installs, and macOS only from
/// the app bundle, so the app plays it there itself; so it does on Linux
/// for a file, or if the notification server plays no sounds at all
/// ([linuxServerPlays] false: dunst, mako).
SoundPlan planSound(
  MessageSound sound, {
  required String kind,
  required TargetPlatform platform,
  bool linuxServerPlays = true,
}) => switch (platform) {
  TargetPlatform.android => switch (sound) {
    FileSound(androidUri: final uri?) => SoundPlan(
      androidChannel: '${kind}_${sha256.convert(utf8.encode(uri)).hex().substring(0, 8)}',
      androidSound: UriAndroidNotificationSound(uri),
    ),
    _ => SoundPlan(androidChannel: '${kind}_default'),
  },
  TargetPlatform.linux => switch (sound) {
    BundledSound(:final asset) when linuxServerPlays => SoundPlan(linuxSound: AssetsLinuxSound(asset)),
    BundledSound(:final asset) => SoundPlan(inApp: 'asset:///$asset'),
    FileSound(:final path) => SoundPlan(inApp: path, linuxSuppress: true),
    SystemSound() => SoundPlan(linuxSound: linuxServerPlays ? ThemeLinuxSound('message-new-instant') : null),
  },
  TargetPlatform.windows || TargetPlatform.macOS => switch (sound) {
    BundledSound(:final asset) => SoundPlan(inApp: 'asset:///$asset', silenced: true),
    FileSound(:final path) => SoundPlan(inApp: path, silenced: true),
    SystemSound() => const SoundPlan(),
  },
  // iOS keeps to the system's sound.
  _ => const SoundPlan(),
};
