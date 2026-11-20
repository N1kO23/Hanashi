import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A video in a call, a camera or a shared screen, as this device has it.
abstract class CallVideo {
  /// Shows it: [BoxFit.cover] fills the box (cameras), [BoxFit.contain]
  /// shows all of it (screens). [mirror] for one's own camera.
  Widget view({BoxFit fit = BoxFit.cover, bool mirror = false});

  /// Its size, as its sender says, if known: which way a phone is turned
  /// for it, full screen.
  Size? get size;
}

/// How this device's shared screen goes out: no bigger than [height] on its
/// shorter side ("1080p"; null: as the screen is), at [fps] frames a second,
/// with a bitrate to match, or at most [maxBitrate] (bits a second) where
/// one is set.
class ShareQuality {
  const ShareQuality({this.height = 1080, this.fps = 15, this.maxBitrate});

  final int? height;
  final int fps;
  final int? maxBitrate;

  /// What there is to choose from.
  static const heights = <int?>[720, 1080, 1440, null];
  static const rates = [5, 15, 30, 60];
  static const bitrates = <int?>[null, 1000000, 2500000, 5000000, 8000000, 12000000, 20000000, 30000000];

  /// The bitrate for a picture of [width] by [height] at [fps]: 0.08 bits a
  /// pixel each frame, as LiveKit's screen presets give 1080p, from 0.3 up
  /// to 12 Mbit/s.
  static int bitrate(int width, int height, int fps) =>
      (width * height * fps * 0.08).round().clamp(300 * 1000, 12 * 1000 * 1000);

  /// The bitrate a picture of [width] by [height] goes at: [maxBitrate] where
  /// set, else the one for its size and frame rate.
  int bitrateFor(int width, int height) => maxBitrate ?? bitrate(width, height, fps);

  @override
  bool operator ==(Object other) =>
      other is ShareQuality && other.height == height && other.fps == fps && other.maxBitrate == maxBitrate;

  @override
  int get hashCode => Object.hash(height, fps, maxBitrate);

  @override
  String toString() =>
      '${height == null ? 'screen' : '${height}p'}@$fps${maxBitrate == null ? '' : ', ${maxBitrate! ~/ 1000} kbit/s'}';
}

/// An app whose sound a shared screen can have (Linux).
class SoundApp {
  const SoundApp({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is SoundApp && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A screen or window this device could share, for a picker.
class ScreenSource {
  ScreenSource({required this.id, required this.name, required this.window, Uint8List? thumbnail})
    : thumbnail = ValueNotifier(thumbnail);

  final String id;
  final String name;

  /// A window, not a whole screen.
  final bool window;

  /// A small picture of it (JPEG), once there is one.
  final ValueNotifier<Uint8List?> thumbnail;
}

/// How loud this device plays someone: their voice, and their shared
/// screen's sound. 1 is as they send it, 0 silent, and up to [most] (four
/// times as loud).
class PeerVolume {
  const PeerVolume({this.voice = 1, this.screen = 1});

  final double voice;
  final double screen;

  static const most = 4.0;

  PeerVolume copyWith({double? voice, double? screen}) =>
      PeerVolume(voice: voice ?? this.voice, screen: screen ?? this.screen);

  @override
  bool operator ==(Object other) => other is PeerVolume && other.voice == voice && other.screen == screen;

  @override
  int get hashCode => Object.hash(voice, screen);

  @override
  String toString() => 'voice ${(voice * 100).round()}%, screen ${(screen * 100).round()}%';
}

/// Someone else's device in a call, as this device hears it.
class CallPeer {
  const CallPeer({
    required this.user,
    required this.device,
    this.speaking = false,
    this.muted = false,
    this.deafened = false,
    this.encrypted = true,
    this.decrypting = true,
    this.camera,
    this.screen,
    this.unwatchedScreen = false,
    this.screenSound = false,
    this.screenSoundOff = false,
  });

  final String user;
  final String device;
  final bool speaking;

  /// Its microphone is off.
  final bool muted;

  /// It hears nobody, as it says.
  final bool deafened;

  /// Its camera, while on; its shared screen, while it shares one that this
  /// device watches.
  final CallVideo? camera;
  final CallVideo? screen;

  /// It shares a screen this device doesn't watch: none of it comes, picture
  /// or sound, until it does (see [CallConnection.watchScreen]).
  final bool unwatchedScreen;

  /// Its shared screen has sound (it is on), which this device does not play
  /// while [screenSoundOff].
  final bool screenSound;
  final bool screenSoundOff;

  /// Its audio comes encrypted; one that does not is never played.
  final bool encrypted;

  /// This device can decrypt its audio (it has the key that is in use).
  final bool decrypting;
}

/// What goes on in a call's room, as the connection tells it.
class CallRoomState {
  const CallRoomState({
    this.peers = const [],
    this.encrypted = false,
    this.speaking = false,
    this.camera,
    this.sharing = false,
    this.shareSound,
    this.shareSoundFrom,
    this.shareSoundMissing,
    this.ownScreen,
  });

  final List<CallPeer> peers;

  /// This device's camera, while on (for a picture of oneself).
  final CallVideo? camera;

  /// This device shares a screen (it may stop by itself: the system's own
  /// "Stop sharing", a window closed).
  final bool sharing;

  /// Whether the shared screen's sound is on; null where it has none.
  final bool? shareSound;

  /// The one app whose sound it has, or null for every app's.
  final SoundApp? shareSoundFrom;

  /// Why the shared screen has no sound, where it could have.
  final String? shareSoundMissing;

  /// This device's shared screen, as it goes out (a picture of it).
  final CallVideo? ownScreen;

  /// This device's audio goes out encrypted.
  final bool encrypted;

  /// This device's user is speaking.
  final bool speaking;
}

/// Why a device could not get into a call, in words for its user.
class CallConnectionException implements Exception {
  const CallConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A device's connection to a call's room: LiveKit in the app, a fake in
/// tests. Audio is end-to-end encrypted with keys the app gives it, one for
/// each epoch of the chat's group, by index (`epoch % 16`).
abstract class CallConnection {
  /// Opens the microphone, asking for leave to where the system does. Called
  /// before the call starts, so nobody is rung for a call this device cannot
  /// speak in. Throws a [CallConnectionException] if it cannot, closed
  /// already then.
  Future<void> openMicrophone();

  /// Gets into the room at [url] with [token], encrypting with [key] at
  /// [keyIndex] from the start. The microphone goes out once its audio is
  /// encrypted, unless [muted].
  ///
  /// Throws a [CallConnectionException] if it cannot, closed already then.
  Future<void> connect({
    required String url,
    required String token,
    required Uint8List key,
    required int keyIndex,
    bool muted = false,
  });

  /// A key for another epoch: audio sent with it can be decrypted at once.
  Future<void> addKey(Uint8List key, int keyIndex);

  /// Sends with the key at [keyIndex] from now on.
  Future<void> sendWithKey(int keyIndex);

  Future<void> setMuted(bool muted);

  /// Plays nobody's audio while [deafened], and tells the others so.
  Future<void> setDeafened(bool deafened);

  /// Through the speaker rather than the earpiece (phones).
  Future<void> setSpeaker(bool on);

  /// Turns the camera on or off. Throws a [CallConnectionException] if it
  /// cannot be used.
  Future<void> setCamera(bool on);

  /// The other camera, on phones: front or back.
  Future<void> switchCamera();

  /// Screens and windows to pick one to share from; none where the system
  /// has a picker of its own (Wayland's portal, Android).
  Future<List<ScreenSource>> screenSources();

  /// Asks the system for leave to share the screen, where it asks (Android,
  /// each time); false if the user said no.
  Future<bool> allowScreenSharing();

  /// Shares [source], or for null what the system's own picker gives, at
  /// [quality]. Throws a [CallConnectionException] if it cannot.
  Future<void> shareScreen(ScreenSource? source, {ShareQuality quality = const ShareQuality()});

  Future<void> stopSharing();

  /// The shared screen's sound on or off, where it has sound.
  Future<void> setShareSound(bool on);

  /// The apps whose sound the shared screen can have now.
  Future<List<SoundApp>> soundApps();

  /// The shared screen's sound from [app] only, or (null) from every app.
  Future<void> shareSoundFrom(SoundApp? app);

  /// Plays [peer]'s shared screen's sound on this device, or not ([off]).
  Future<void> setScreenSoundOff(CallPeer peer, bool off);

  /// Watches [peer]'s shared screen, or no longer ([watch] false): only a
  /// screen watched comes to this device. Watching ends with the share.
  Future<void> watchScreen(CallPeer peer, bool watch);

  /// Plays each user's devices as loud as [volumes] has them (by user), now
  /// and as their audio comes; everyone else as they send it.
  Future<void> setVolumes(Map<String, PeerVolume> volumes);

  /// What goes on in the room, as it changes.
  Stream<CallRoomState> get states;

  /// Completes once the room is gone for good (not while reconnecting).
  Future<void> get closed;

  Future<void> disconnect();
}
