import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import '../diagnostics/app_log.dart';
import '../e2ee/primitives.dart';
import 'call_connection.dart';
import 'voice_gate.dart';

const _log = Log('call');

/// A key provider that never takes the trailer LiveKit's server sends: a
/// frame ending with it would be played without decryption, so the server
/// could put sound of its own into an encrypted call.
///
/// It also tells LiveKit which key sends ([sendIndex]). In shared-key mode
/// LiveKit's own always says 0, and its encrypted data messages (who
/// speaks) would go out with whatever key is at 0, if any.
class _OwnKeyProvider extends BaseKeyProvider {
  _OwnKeyProvider(BaseKeyProvider made) : super(made.keyProvider, made.options);

  var sendIndex = 0;

  @override
  int getLatestIndex(String participantId) => sendIndex;

  @override
  Future<void> setSifTrailer(Uint8List trailer) async {}
}

/// Whose audio this device cannot decrypt, as far as it is worth telling.
///
/// Once a sender mutes, LiveKit's server puts a second of silence of its own
/// into the track, ending with the trailer this device never takes (see
/// [_OwnKeyProvider]): it fails to decrypt and is dropped, as it should be.
/// So a failure counts only while the audio is unmuted, and only once nothing
/// has decrypted for [grace]. LiveKit tells only of changes (failing,
/// decrypting again), so a failure from before unmuting counts from the
/// unmuting.
@visibleForTesting
class UnheardAudio {
  UnheardAudio({this.grace = const Duration(seconds: 2), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration grace;
  final DateTime Function() _clock;

  /// Since when frames of each (by identity) fail to decrypt, or since their
  /// audio came back.
  final _failing = <String, DateTime>{};

  /// Its frames fail to decrypt: a key missing, or frames not from a member.
  void failed(String identity) => _failing.putIfAbsent(identity, _clock);

  /// Its frames decrypt again, or it has gone.
  void decrypted(String identity) => _failing.remove(identity);

  /// Its audio is there to hear again: unmuted, or subscribed to.
  void audible(String identity) {
    if (_failing.containsKey(identity)) _failing[identity] = _clock();
  }

  /// How long until [identity]'s audio counts as unheard: zero once it does,
  /// null while it decrypts or is [muted].
  Duration? unheardIn(String identity, {required bool muted}) {
    final since = _failing[identity];
    if (since == null || muted) return null;
    final left = since.add(grace).difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }
}

/// A track's video, shown with LiveKit's renderer (which also tells LiveKit
/// how big it is shown: adaptive stream).
class _LiveKitVideo implements CallVideo {
  _LiveKitVideo(this.track);

  final VideoTrack track;

  @override
  Size? size;

  @override
  Widget view({BoxFit fit = BoxFit.cover, bool mirror = false}) => VideoTrackRenderer(
    track,
    key: ObjectKey(track),
    fit: fit == BoxFit.contain ? VideoViewFit.contain : VideoViewFit.cover,
    mirrorMode: mirror ? VideoViewMirrorMode.mirror : VideoViewMirrorMode.off,
  );
}

/// A call's room in LiveKit, its audio and video end-to-end encrypted with
/// the keys the app gives it (see docs/calls.md): one shared key per epoch of
/// the chat's group, by index. The only place that knows LiveKit.
class LiveKitConnection implements CallConnection {
  LiveKitConnection([this._gate = const NoVoiceGate()]);

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  _OwnKeyProvider? _keys;

  /// The microphone's voice gate: what it lets out is what the others hear,
  /// and while it is open this device's user speaks, for everyone. Where
  /// there is none, LiveKit's hearing says who speaks.
  final VoiceGate _gate;
  StreamSubscription<bool>? _gateOpens;
  var _gated = false;
  var _voiceOpen = false;

  /// Whether WebRTC hands the gate the microphone's audio, checked while
  /// it is unmuted: the frames gated at the last look.
  Timer? _gateCheck;
  int? _framesGated;

  /// What the others were last told: speaking, or not.
  var _toldSpeaking = false;
  Future<void> _telling = Future.value();
  var _tellingFailed = false;

  /// Who speaks, as each device tells (by identity). The others' as LiveKit
  /// hears them: devices without a gate, and older Hanashis.
  final _peerSpeaking = <String, bool>{};

  /// The microphone, open before the room is (see [openMicrophone]).
  LocalAudioTrack? _microphone;

  /// The shared screen, while there is one.
  LocalVideoTrack? _screen;

  /// Its sound, where it has one (Linux), on or off, from one app or all;
  /// else why it has none, where it could have.
  LocalAudioTrack? _screenSound;
  var _screenSoundOn = false;
  SoundApp? _screenSoundFrom;
  String? _screenSoundMissing;

  /// Peers (by identity) whose shared screen's sound this device does not
  /// play.
  final _screenSoundOff = <String>{};

  /// Peers (by identity) whose shared screen this device watches: the others'
  /// come to it not at all (see [watchScreen]).
  final _watching = <String>{};

  /// How loud each user plays here (see [setVolumes]).
  final _volumes = <String, PeerVolume>{};

  /// The volume each remote audio track was last given, by track; one not
  /// here plays as it came.
  final _trackVolumes = <String, double>{};
  var _cameraPosition = CameraPosition.front;

  /// The videos shown, one for each track, kept while the track is there.
  final _videos = <VideoTrack, _LiveKitVideo>{};

  /// Thumbnails coming for the screens and windows last listed.
  final _thumbnails = <StreamSubscription<Uint8List>>[];

  static const _capture = AudioCaptureOptions(noiseSuppression: true, echoCancellation: true, autoGainControl: true);
  final _states = StreamController<CallRoomState>.broadcast();
  final _closed = Completer<void>();

  var _encrypted = false;
  var _muted = false;
  var _deafened = false;
  var _sendIndex = 0;

  /// In the room: leaving says goodbye to it.
  var _connected = false;

  /// Disconnected: a [connect] still going on goes no further.
  var _over = false;

  /// Peers whose audio this device cannot decrypt.
  final _unheard = UnheardAudio();

  /// For the next peer whose audio is to count as unheard.
  Timer? _recheck;

  /// Remote audio that came unencrypted: never played.
  final _unencrypted = <String>{};

  @override
  Stream<CallRoomState> get states => _states.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> openMicrophone() async {
    try {
      _microphone = await LocalAudioTrack.create(_capture);
    } catch (e, stack) {
      _log.warning('Opening the microphone', e, stack);
      await _close();
      // Android's WebRTC says this of a permission denied.
      throw CallConnectionException(
        '$e'.contains('NotAllowedError')
            ? 'Hanashi may not use the microphone: allow it in the system settings'
            : 'Could not use the microphone',
      );
    }
    if (_over) return _close();
    await _gateOn();
  }

  /// The voice gate on, once the microphone is open (WebRTC is set up by
  /// then).
  Future<void> _gateOn() async {
    if (_gateOpens != null) return;
    _gateOpens = _gate.opens.listen((open) {
      _voiceOpen = open;
      _changed();
    });
    _gated = await _gate.activate();
    if (_gated) _gateCheck = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_checkGate()));
  }

  /// A gate WebRTC passes by would leave the others hearing a voice they
  /// never see speaking: then LiveKit's hearing says who speaks, as where
  /// there is no gate.
  Future<void> _checkGate() async {
    if (!_gated || _muted || !_encrypted || !_connected) {
      // Muted, the microphone is shut: nothing to gate.
      _framesGated = null;
      return;
    }
    final frames = await _gate.framesGated();
    if (frames == null || !_gated) return;
    final before = _framesGated;
    _framesGated = _muted ? null : frames;
    if (before == null || frames != before || _muted) return;
    _log.warning("WebRTC passes the voice gate by: the microphone's audio all goes out, and LiveKit says who speaks");
    _gated = false;
    _gateCheck?.cancel();
    _changed();
  }

  @override
  Future<void> connect({
    required String url,
    required String token,
    required Uint8List key,
    required int keyIndex,
    bool muted = false,
  }) async {
    _muted = muted;
    _sendIndex = keyIndex;
    final _OwnKeyProvider keys;
    try {
      keys = _OwnKeyProvider(
        await BaseKeyProvider.create(
          // The keys never move on by themselves: each epoch brings its own.
          ratchetWindowSize: 0,
          failureTolerance: -1,
          keyRingSize: 16,
          // Nothing goes out, or is played, before its key is here.
          discardFrameWhenCryptorNotReady: true,
          // Frames ending with these would pass unencrypted: random, nobody
          // else's to send.
          uncryptedMagicBytes: String.fromCharCodes(randomBytes(32)),
        ),
      );
      keys.sendIndex = keyIndex;
      await keys.setRawKey(key, keyIndex: keyIndex);
    } catch (e, stack) {
      _log.warning('Setting up encryption for the call', e, stack);
      await _close();
      throw const CallConnectionException('Encrypted calls do not work on this device');
    }
    _keys = keys;
    if (_over) return;
    final room = Room(
      roomOptions: RoomOptions(
        encryption: E2EEOptions(keyProvider: keys),
        defaultAudioCaptureOptions: _capture,
        // Video goes only where it is shown, and no bigger than shown.
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: const CameraCaptureOptions(params: VideoParametersPresets.h720_169),
      ),
    );
    _room = room;
    _listen(room);
    try {
      await room.connect(url, token);
    } catch (e, stack) {
      _log.warning('Could not get into the call at ${Uri.tryParse(url)?.host ?? url}', e, stack);
      await _close();
      throw CallConnectionException(_why(e));
    }
    if (_over) return;
    _connected = true;
    // Screens shared already: LiveKit's server started sending them on the
    // way in, and stops now.
    for (final participant in room.remoteParticipants.values) {
      await _applyWatching(participant);
    }
    try {
      // Published muted: it speaks once its frames are encrypted (see
      // TrackE2EEStateEvent below). The one opened before, if it was.
      final microphone = _microphone;
      if (microphone != null) {
        await room.localParticipant?.publishAudioTrack(microphone);
      } else {
        await room.localParticipant?.setMicrophoneEnabled(true);
      }
      await room.localParticipant?.setMicrophoneEnabled(false);
    } catch (e, stack) {
      _log.warning('Opening the microphone', e, stack);
      await _close();
      throw const CallConnectionException('Could not use the microphone');
    }
    await _gateOn();
    // In shared-key mode LiveKit starts every sender at key index 0.
    await room.e2eeManager?.setKeyIndex(keyIndex);
    // Deafened while getting in: the others are told now.
    if (_deafened) await setDeafened(true);
    _changed();
  }

  /// What to tell the user of [error], from getting into the room.
  static String _why(Object error) => switch (error) {
    // The token refused: LiveKit's key or secret differ from the server's.
    // (LiveKit's client says NotAllowed of any status from 400 up, even a
    // proxy's 502.)
    ConnectException(statusCode: 401 || 403) => 'The call server turned the call away',
    // The room let us in, but no audio got through: LiveKit's UDP and TCP
    // ports.
    MediaConnectException() => "Could not connect the call's audio",
    LiveKitE2EEException() => 'Encrypted calls do not work on this device',
    // Its address, TLS, the proxy before it, or no answer in time.
    _ => 'Could not reach the call server',
  };

  void _listen(Room room) {
    _listener = room.createListener()
      ..on<TrackE2EEStateEvent>((event) async {
        final identity = event.participant.identity;
        final source = event.publication.source;
        final audio = source == TrackSource.microphone;
        if (event.participant is LocalParticipant) {
          final ok = event.state == E2EEState.kOk;
          if (event.state == E2EEState.kMissingKey) {
            // In shared-key mode LiveKit starts each new sender at key index
            // 0: ours is another. Its frames are dropped meanwhile.
            await room.e2eeManager?.setKeyIndex(_sendIndex);
          } else if (audio && ok && !_encrypted) {
            _encrypted = true;
            _log.info('Our audio goes out encrypted');
            if (!_muted) await room.localParticipant?.setMicrophoneEnabled(true);
          } else if (ok) {
            _log.info('Our ${source.name} goes out encrypted');
          } else if (event.state != E2EEState.kNew) {
            _log.warning('Encrypting our ${source.name}: ${event.state.name}');
          }
        } else {
          _log.info('${audio ? 'Audio' : source.name} of $identity: ${event.state.name}');
          if (!audio) {
            // Shown only once decrypted (see _videoOf).
          } else if (event.state == E2EEState.kDecryptionFailed || event.state == E2EEState.kMissingKey) {
            _unheard.failed(identity);
          } else if (event.state == E2EEState.kOk) {
            _unheard.decrypted(identity);
          }
        }
        _changed();
      })
      ..on<TrackPublishedEvent>((event) async {
        // A screen shared from now on: told before LiveKit's server sends any
        // of it.
        await _applyWatching(event.participant);
        _changed();
      })
      ..on<TrackSubscribedEvent>((event) async {
        // Should a screen be here unwatched (shared as this device got in,
        // or again after a reconnect), as little of it as can be.
        if (_screenSources.contains(event.publication.source)) await _applyWatching(event.participant);
        if (event.publication.encryptionType == EncryptionType.kNone) {
          // Whatever it is, it is not of a member: not played, not shown.
          _log.warning('${event.publication.source.name} of ${event.participant.identity} came unencrypted: not played');
          _unencrypted.add(event.participant.identity);
          await event.track.disable();
        } else if (event.track is AudioTrack && !_plays(event.participant, event.publication)) {
          await event.track.disable();
        } else if (event.publication.source == TrackSource.screenShareAudio) {
          await _asMedia(event.track, true);
        }
        if (event.track is AudioTrack) await _applyVolume(event.participant, event.publication, event.track);
        if (event.publication.source == TrackSource.microphone) _unheard.audible(event.participant.identity);
        _changed();
      })
      ..on<TrackUnsubscribedEvent>((event) async {
        if (event.publication.source == TrackSource.screenShareAudio) await _asMedia(event.track, false);
        _trackVolumes.remove(event.track.mediaStreamTrack.id);
        _changed();
      })
      ..on<TrackUnpublishedEvent>((event) {
        // Its next share is watched only once asked again.
        if (event.publication.source == TrackSource.screenShareVideo) _watching.remove(event.participant.identity);
        _changed();
      })
      ..on<LocalTrackPublishedEvent>((_) => _changed())
      ..on<LocalTrackUnpublishedEvent>((event) async {
        final track = event.publication.track;
        if (track is LocalVideoTrack && identical(track, _screen)) {
          // Ended by the system (a window closed): its sound goes too.
          _log.info('Sharing the screen ended');
          _screen = null;
          await _endShare(track);
        }
        _changed();
      })
      ..on<ParticipantConnectedEvent>((event) {
        // The newcomer hears of it from now.
        if (_toldSpeaking) _tell(true, to: [event.participant.identity]);
        _changed();
      })
      ..on<ParticipantAttributesChanged>((_) => _changed())
      ..on<ParticipantDisconnectedEvent>((event) {
        _unheard.decrypted(event.participant.identity);
        _unencrypted.remove(event.participant.identity);
        _screenSoundOff.remove(event.participant.identity);
        _watching.remove(event.participant.identity);
        _peerSpeaking.remove(event.participant.identity);
        _changed();
      })
      ..on<DataReceivedEvent>((event) {
        final from = event.participant;
        if (event.topic != _speakingTopic || from == null || event.data.isEmpty) return;
        _peerSpeaking[from.identity] = event.data.first == 1;
        _changed();
      })
      ..on<ActiveSpeakersChangedEvent>((_) => _changed())
      ..on<TrackMutedEvent>((_) => _changed())
      ..on<TrackUnmutedEvent>((event) {
        if (event.participant is RemoteParticipant && event.publication.source == TrackSource.microphone) {
          _unheard.audible(event.participant.identity);
        }
        _changed();
      })
      ..on<RoomDisconnectedEvent>((event) {
        _log.info('Out of the room: ${event.reason?.name}');
        _connected = false;
        if (!_closed.isCompleted) _closed.complete();
      });
  }

  void _changed() {
    final room = _room;
    if (room == null || _states.isClosed) return;
    final shown = <VideoTrack>{};
    CallVideo? videoOf(Participant participant, TrackSource source) {
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (publication.source != source || publication.muted || track is! VideoTrack) continue;
        // Never one that comes unencrypted.
        if (publication.encryptionType == EncryptionType.kNone) continue;
        shown.add(track);
        final size = publication.dimensions;
        return _videos.putIfAbsent(track, () => _LiveKitVideo(track))
          ..size = size == null || size.width <= 0 || size.height <= 0
              ? null
              : Size(size.width.toDouble(), size.height.toDouble());
      }
      return null;
    }

    final peers = <CallPeer>[];
    Duration? recheck;
    for (final participant in room.remoteParticipants.values) {
      final identity = participant.identity;
      final slash = identity.lastIndexOf('/');
      // Not LiveKit's isMuted: that is the first audio's, which may be a
      // shared screen's sound.
      final muted =
          participant.audioTrackPublications.where((p) => p.source == TrackSource.microphone).firstOrNull?.muted ??
          true;
      final screenSound = participant.audioTrackPublications.any(
        (p) => p.source == TrackSource.screenShareAudio && !p.muted && p.encryptionType != EncryptionType.kNone,
      );
      final sharing = participant.videoTrackPublications.any(
        (p) => p.source == TrackSource.screenShareVideo && !p.muted && p.encryptionType != EncryptionType.kNone,
      );
      final watching = _watching.contains(identity);
      final unheardIn = _unheard.unheardIn(identity, muted: muted);
      if (unheardIn != null && unheardIn > Duration.zero && (recheck == null || unheardIn < recheck)) {
        recheck = unheardIn;
      }
      peers.add(
        CallPeer(
          user: slash < 0 ? identity : identity.substring(0, slash),
          device: slash < 0 ? '' : identity.substring(slash + 1),
          speaking: !muted && (_peerSpeaking[identity] ?? participant.isSpeaking),
          muted: muted,
          deafened: participant.attributes[_deafenedKey] == 'true',
          encrypted: !_unencrypted.contains(identity),
          decrypting: unheardIn != Duration.zero,
          camera: videoOf(participant, TrackSource.camera),
          screen: watching ? videoOf(participant, TrackSource.screenShareVideo) : null,
          unwatchedScreen: sharing && !watching,
          screenSound: screenSound,
          screenSoundOff: _screenSoundOff.contains(identity),
        ),
      );
    }
    _recheck?.cancel();
    _recheck = recheck == null ? null : Timer(recheck, _changed);
    final local = room.localParticipant;
    final speaking = !_muted && _encrypted && (_gated ? _voiceOpen : (local?.isSpeaking ?? false));
    if (_gated) _tell(speaking);
    final camera = local == null ? null : videoOf(local, TrackSource.camera);
    final ownScreen = local == null ? null : videoOf(local, TrackSource.screenShareVideo);
    _videos.removeWhere((track, _) => !shown.contains(track));
    _states.add(
      CallRoomState(
        peers: peers,
        encrypted: _encrypted,
        speaking: speaking,
        camera: camera,
        sharing: _screen != null,
        shareSound: _screenSound == null ? null : _screenSoundOn,
        shareSoundFrom: _screenSound == null ? null : _screenSoundFrom,
        shareSoundMissing: _screen == null ? null : _screenSoundMissing,
        ownScreen: _screen == null ? null : ownScreen,
      ),
    );
  }

  @override
  Future<void> addKey(Uint8List key, int keyIndex) async => _keys?.setRawKey(key, keyIndex: keyIndex);

  @override
  Future<void> sendWithKey(int keyIndex) async {
    _sendIndex = keyIndex;
    _keys?.sendIndex = keyIndex;
    await _room?.e2eeManager?.setKeyIndex(keyIndex);
  }

  /// Whose voice goes out: one byte, 1 or 0, to everyone in the room as
  /// it changes, and to each newcomer while it is 1. Encrypted, as data
  /// messages are in an encrypted room.
  static const _speakingTopic = 'hanashi.speaking';

  /// Tells the others whether this device's user speaks, when it changes,
  /// or newcomers ([to]) that they do. In order: one at a time.
  void _tell(bool speaking, {List<String>? to}) {
    final local = _room?.localParticipant;
    if (local == null || !_connected) return;
    if (to == null) {
      if (speaking == _toldSpeaking) return;
      _toldSpeaking = speaking;
    }
    if (!local.permissions.canPublishData) {
      if (!_tellingFailed) {
        _tellingFailed = true;
        _log.warning(
          "LiveKit lets no data messages through: the others see who speaks as LiveKit hears it, not by this device's voice gate",
        );
      }
      return;
    }
    _telling = _telling.then((_) async {
      try {
        await local.publishData(
          [if (speaking) 1 else 0],
          reliable: true,
          topic: _speakingTopic,
          destinationIdentities: to,
        );
      } catch (e) {
        if (_tellingFailed) return;
        _tellingFailed = true;
        _log.warning('Could not tell the others who speaks: $e');
      }
    });
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    // The microphone shuts and opens again: the gate's frames are counted
    // afresh.
    _framesGated = null;
    // Never before its audio is encrypted.
    if (_encrypted || muted) await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    _changed();
  }

  /// The attribute that tells the others this device hears nobody.
  static const _deafenedKey = 'deafened';

  @override
  Future<void> setDeafened(bool deafened) async {
    _deafened = deafened;
    try {
      // Empty takes it away.
      await _room?.localParticipant?.setAttributes({_deafenedKey: deafened ? 'true' : ''});
    } catch (e) {
      // Deafened all the same, only not shown to the others.
      _log.warning('LiveKit did not let the others know of deafening: $e');
    }
    await _applyPlaying();
  }

  /// Whether [publication]'s audio plays: not while deafened, never one
  /// that came unencrypted, nor a shared screen's sound turned off here.
  bool _plays(Participant participant, TrackPublication publication) =>
      !_deafened &&
      !_unencrypted.contains(participant.identity) &&
      !(publication.source == TrackSource.screenShareAudio && _screenSoundOff.contains(participant.identity));

  Future<void> _applyPlaying() async {
    for (final participant in _room?.remoteParticipants.values ?? const <RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track == null) continue;
        final plays = _plays(participant, publication);
        if (plays) {
          await track.enable();
        } else {
          await track.disable();
        }
        if (publication.source == TrackSource.screenShareAudio) await _asMedia(track, plays);
        await _applyVolume(participant, publication, track);
      }
    }
  }

  @override
  Future<void> setVolumes(Map<String, PeerVolume> volumes) async {
    _volumes
      ..clear()
      ..addAll(volumes);
    for (final participant in _room?.remoteParticipants.values ?? const <RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        if (publication.track case final track?) await _applyVolume(participant, publication, track);
      }
    }
  }

  /// [publication]'s audio as loud as its user is to play here: through
  /// WebRTC (which takes up to ten times as loud), or where a shared screen's
  /// sound plays as media (phones), there.
  Future<void> _applyVolume(Participant participant, TrackPublication publication, Track track) async {
    final id = track.mediaStreamTrack.id;
    if (id == null) return;
    final identity = participant.identity;
    final slash = identity.lastIndexOf('/');
    final volume = _volumes[slash < 0 ? identity : identity.substring(0, slash)] ?? const PeerVolume();
    final level = publication.source == TrackSource.screenShareAudio ? volume.screen : volume.voice;
    if ((_trackVolumes[id] ?? 1) == level) return;
    _trackVolumes[id] = level;
    try {
      if (_asMediaTracks.contains(id)) {
        await _streamSound.invokeMethod('volume', {'trackId': id, 'volume': level});
      } else {
        await rtc.Helper.setVolume(level, track.mediaStreamTrack);
      }
    } catch (e) {
      _log.debug('Setting the volume of $identity: $e');
    }
  }

  /// Phones play everything WebRTC plays the call's voice way, processed
  /// for speech, which spoils music: there, a shared screen's sound plays as
  /// media instead, as a video app's does (`StreamSound` in MainActivity).
  static const _streamSound = MethodChannel('hanashi/stream_sound');

  /// The shared screens' sounds playing as media, by track.
  final _asMediaTracks = <String>{};

  Future<void> _asMedia(Track track, bool on) async {
    final id = track.mediaStreamTrack.id;
    if (!Platform.isAndroid || id == null || on == _asMediaTracks.contains(id)) return;
    // Played elsewhere from now, as it came: its volume goes there next (see
    // _applyVolume).
    _trackVolumes.remove(id);
    try {
      if (on) {
        // Where it can't, the call's way it is.
        if (await _streamSound.invokeMethod<bool>('start', {'trackId': id}) ?? false) _asMediaTracks.add(id);
      } else {
        _asMediaTracks.remove(id);
        await _streamSound.invokeMethod('stop', {'trackId': id});
      }
    } catch (e) {
      _log.debug("Playing a shared screen's sound as media: $e");
    }
  }

  static String _identityOf(CallPeer peer) => peer.device.isEmpty ? peer.user : '${peer.user}/${peer.device}';

  @override
  Future<void> setScreenSoundOff(CallPeer peer, bool off) async {
    final identity = _identityOf(peer);
    if (off ? !_screenSoundOff.add(identity) : !_screenSoundOff.remove(identity)) return;
    await _applyPlaying();
    _changed();
  }

  @override
  Future<void> watchScreen(CallPeer peer, bool watch) async {
    final identity = _identityOf(peer);
    if (watch ? !_watching.add(identity) : !_watching.remove(identity)) return;
    _log.info(watch ? 'Watching the screen of $identity' : 'No longer watching the screen of $identity');
    if (_room?.remoteParticipants[identity] case final participant?) await _applyWatching(participant);
    _changed();
  }

  static const _screenSources = {TrackSource.screenShareVideo, TrackSource.screenShareAudio};

  /// [participant]'s shared screen, its picture and its sound, as this device
  /// watches it or not. Subscribed to as everything is, an unwatched one is
  /// disabled: LiveKit's server sends none of it.
  Future<void> _applyWatching(RemoteParticipant participant) async {
    final watching = _watching.contains(participant.identity);
    for (final publication in participant.trackPublications.values) {
      if (!_screenSources.contains(publication.source)) continue;
      if (watching) {
        await publication.enable();
      } else {
        await publication.disable();
      }
    }
  }

  /// For the whole app (LiveKit has one audio session), so it is set for
  /// each call. A headset still goes first.
  @override
  Future<void> setSpeaker(bool on) async {
    if (AudioManager.instance.canSwitchSpeakerphone) await AudioManager.instance.setSpeakerOutputPreferred(on);
  }

  @override
  Future<void> setCamera(bool on) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    try {
      await local.setCameraEnabled(
        on,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: _cameraPosition,
          params: VideoParametersPresets.h720_169,
        ),
      );
    } catch (e, stack) {
      _log.warning('Turning the camera ${on ? 'on' : 'off'}', e, stack);
      throw CallConnectionException(
        '$e'.contains('NotAllowedError')
            ? 'Hanashi may not use the camera: allow it in the system settings'
            : 'Could not use the camera',
      );
    }
    _changed();
  }

  @override
  Future<void> switchCamera() async {
    final track = _room?.localParticipant?.videoTrackPublications
        .where((p) => p.source == TrackSource.camera)
        .firstOrNull
        ?.track;
    _cameraPosition = _cameraPosition == CameraPosition.front ? CameraPosition.back : CameraPosition.front;
    if (track == null) return;
    try {
      await track.setCameraPosition(_cameraPosition);
    } catch (e, stack) {
      _log.warning('Switching cameras', e, stack);
      throw const CallConnectionException('Could not switch cameras');
    }
  }

  /// Our own sharing through the desktop portal on Wayland
  /// (`linux/webrtc/portal_screen_cast.h`): told to stop, and telling when
  /// the system ended it. On Android, MainActivity tells when the system
  /// ended flutter_webrtc's sharing (its "Stop sharing" chip), which
  /// flutter_webrtc itself does not.
  static const _screencast = MethodChannel('hanashi/screencast');
  static final _byScreenTrack = <String, LiveKitConnection>{};
  static var _screencastHeard = false;

  static void _hearScreencast() {
    if (_screencastHeard) return;
    _screencastHeard = true;
    _screencast.setMethodCallHandler((call) async {
      if (call.method != 'ended') return;
      final id = (call.arguments as Map?)?['trackId'];
      // Android does not say which: it shares one screen at a time.
      final ended = id == null ? [..._byScreenTrack.values] : [?_byScreenTrack[id]];
      if (ended.isEmpty) return;
      _log.info('The system ended sharing the screen');
      for (final connection in ended) {
        await connection.stopSharing();
      }
    });
  }

  /// Where the system picks what is shared, with a dialog of its own: on
  /// Wayland (listing windows there also crashes libwebrtc), and on phones.
  static bool get _systemPicks =>
      Platform.isAndroid || Platform.isIOS || (Platform.isLinux && Platform.environment['XDG_SESSION_TYPE'] == 'wayland');

  @override
  Future<List<ScreenSource>> screenSources() async {
    for (final subscription in _thumbnails) {
      await subscription.cancel();
    }
    _thumbnails.clear();
    if (_systemPicks) return const [];
    final List<rtc.DesktopCapturerSource> found;
    try {
      found = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen, rtc.SourceType.Window],
        thumbnailSize: rtc.ThumbnailSize(320, 180),
      );
    } catch (e, stack) {
      _log.warning('Listing screens and windows', e, stack);
      return const [];
    }
    return [
      for (final source in found)
        if (source.type == rtc.SourceType.Screen || source.name.isNotEmpty)
          _sourceOf(source),
    ];
  }

  ScreenSource _sourceOf(rtc.DesktopCapturerSource source) {
    final shown = ScreenSource(
      id: source.id,
      name: source.name,
      window: source.type == rtc.SourceType.Window,
      thumbnail: source.thumbnail,
    );
    // Thumbnails come a little later.
    _thumbnails.add(source.onThumbnailChanged.stream.listen((picture) => shown.thumbnail.value = picture));
    return shown;
  }

  @override
  Future<bool> allowScreenSharing() async {
    if (!Platform.isAndroid) return true;
    try {
      return await rtc.Helper.requestCapturePermission();
    } catch (e, stack) {
      _log.warning('Asking to share the screen', e, stack);
      return false;
    }
  }

  /// Whether our own sharing on Linux takes sound (`linux/webrtc`), as it
  /// said: never flutter_webrtc's own, which would have the call in it.
  static bool? _nativeSound;

  /// Whether a share can have sound: on Linux, through our own sharing, and
  /// where the server lets LiveKit take it. If not, why not (null where
  /// shares have no sound at all yet).
  Future<(bool, String?)> _shareSound(LocalParticipant local) async {
    if (!Platform.isLinux) return (false, null);
    // Protocol buffers' names; none listed: all allowed.
    final sources = local.permissions.canPublishSources;
    if (sources.isNotEmpty && !sources.any((source) => source.name == 'SCREEN_SHARE_AUDIO')) {
      return (false, "The call server doesn't allow sharing sound yet: it needs updating");
    }
    try {
      _nativeSound ??= await _screencast.invokeMethod<bool>('canShareSound') ?? false;
    } on MissingPluginException {
      _nativeSound = false;
    } catch (e) {
      _log.debug('Asking whether a share can have sound: $e');
      return (false, "Couldn't find out whether sound can be shared");
    }
    return _nativeSound! ? (true, null) : (false, "This build of Hanashi can't share sound (PipeWire)");
  }

  @override
  Future<void> shareScreen(ScreenSource? source, {ShareQuality quality = const ShareQuality()}) async {
    final local = _room?.localParticipant;
    if (local == null || _screen != null) return;
    if (Platform.isLinux || Platform.isAndroid) _hearScreencast();
    final (sound, noSound) = await _shareSound(local);
    _screenSoundMissing = noSound;
    // Until the screen's own size is known (see _fitShare): as if 16:9.
    final height = quality.height ?? 1080;
    final encoding = VideoEncoding(
      maxBitrate: quality.bitrateFor(height * 16 ~/ 9, height),
      maxFramerate: quality.fps,
    );
    final options = ScreenShareCaptureOptions(
      sourceId: source?.id,
      maxFrameRate: quality.fps.toDouble(),
      params: VideoParameters(dimensions: VideoDimensions(height * 16 ~/ 9, height), encoding: encoding),
    );
    final List<LocalTrack> tracks;
    try {
      tracks = sound
          ? await LocalVideoTrack.createScreenShareTracksWithAudio(options)
          : [await LocalVideoTrack.createScreenShareTrack(options)];
    } catch (e, stack) {
      // The user said no in the system's dialog: nothing to tell.
      if ('$e'.contains('cancelled')) return;
      _log.warning('Starting to share the screen', e, stack);
      throw const CallConnectionException('Sharing the screen did not start');
    }
    final track = tracks.whereType<LocalVideoTrack>().first;
    _byScreenTrack[track.mediaStreamTrack.id ?? ''] = this;
    _screenSound = tracks.whereType<LocalAudioTrack>().firstOrNull;
    if (sound && _screenSound == null) _screenSoundMissing = "PipeWire couldn't give the screen's sound";
    if (_over) {
      await _endShare(track);
      await track.stop();
      return;
    }
    // Ended by the system (its own "Stop sharing", a window closed), LiveKit
    // unpublishes it: see LocalTrackUnpublishedEvent.
    _screen = track;
    try {
      await local.publishVideoTrack(
        track,
        publishOptions: VideoPublishOptions(
          // One picture, fitted once the screen's size is known.
          simulcast: false,
          screenShareEncoding: encoding,
          degradationPreference: _degradation(quality),
        ),
      );
    } catch (e, stack) {
      _log.warning('Publishing the shared screen', e, stack);
      _screen = null;
      await _endShare(track);
      await track.stop();
      throw const CallConnectionException('Sharing the screen did not start');
    }
    if (_screenSound case final audio?) {
      try {
        await local.publishAudioTrack(
          audio,
          publishOptions: const AudioPublishOptions(
            name: 'screen_share_audio',
            // Music more than speech, and never silence left out (LiveKit's
            // Dart client sends it mono).
            encoding: AudioEncoding.presetMusicHighQuality,
            dtx: false,
            red: false,
          ),
        );
        _screenSoundOn = true;
        _screenSoundFrom = null;
      } catch (e, stack) {
        // Shared all the same, without its sound.
        _log.warning("Publishing the shared screen's sound", e, stack);
        _screenSound = null;
        _screenSoundMissing = "LiveKit didn't take the screen's sound";
        await _stopNative(audio.mediaStreamTrack.id);
        await audio.stop();
      }
    }
    _log.info(
      'Sharing ${source == null ? 'what the system picks' : source.window ? 'a window' : 'a screen'}'
      '${_screenSound != null ? ', with its sound' : _screenSoundMissing != null ? ', without its sound: $_screenSoundMissing' : ''}',
    );
    _changed();
    unawaited(_fitShare(track, quality));
  }

  /// When the network is short: at 30 frames a second or more, motion goes
  /// on, smaller; below, the picture stays sharp (text), less often.
  static DegradationPreference _degradation(ShareQuality quality) =>
      quality.fps >= 30 ? DegradationPreference.maintainFramerate : DegradationPreference.maintainResolution;

  /// A shared screen fitted to [quality] once its size is known (LiveKit sizes
  /// a screen's encoding from a preset, not from the screen): scaled down to
  /// the chosen height, at a bitrate for the size it then goes at (or the
  /// one chosen).
  Future<void> _fitShare(LocalVideoTrack track, ShareQuality quality) async {
    final sender = track.sender;
    final size = await _sizeOf(track);
    if (sender == null || !identical(_screen, track)) return;
    if (size == null) return _log.info("Sharing the screen as it is: its size didn't come");
    final (width, height) = size;
    final scale = quality.height == null ? 1.0 : max(1.0, min(width, height) / quality.height!);
    final bitrate = quality.bitrateFor(width ~/ scale, height ~/ scale);
    final parameters = sender.parameters;
    for (final encoding in parameters.encodings ?? const <rtc.RTCRtpEncoding>[]) {
      encoding
        ..scaleResolutionDownBy = scale
        ..maxFramerate = quality.fps
        ..maxBitrate = bitrate
        // Left as WebRTC has them (the copy here has the SSRC as 0): a
        // change to any is refused, and with it the rest.
        ..ssrc = null
        ..minBitrate = null
        ..numTemporalLayers = null
        ..scalabilityMode = null;
    }
    parameters.degradationPreference = quality.fps >= 30
        ? rtc.RTCDegradationPreference.MAINTAIN_FRAMERATE
        : rtc.RTCDegradationPreference.MAINTAIN_RESOLUTION;
    final taken = await sender.setParameters(parameters);
    _log.info(
      'Sharing ${width}x$height as ${(width / scale).round()}x${(height / scale).round()}, '
      '${quality.fps} frames a second, up to ${(bitrate / 1000000).toStringAsFixed(1)} Mbit/s'
      '${taken ? '' : " (WebRTC didn't take it)"}',
    );
  }

  /// How big [track]'s pictures are, once they come: from a view of it that
  /// nobody sees (WebRTC's statistics don't say on desktops).
  Future<(int, int)?> _sizeOf(LocalVideoTrack track) async {
    final view = rtc.RTCVideoRenderer();
    try {
      await view.initialize();
      view.srcObject = track.mediaStream;
      for (var tries = 0; tries < 40 && identical(_screen, track); tries++) {
        if (view.videoWidth > 0 && view.videoHeight > 0) return (view.videoWidth, view.videoHeight);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      _log.debug("Looking at the shared screen's size: $e");
    } finally {
      try {
        view.srcObject = null;
        await view.dispose();
      } catch (e) {
        _log.debug("Letting go of the shared screen's view: $e");
      }
    }
    return null;
  }

  /// Tells our own sharing (`linux/webrtc`) that [trackId]'s share stopped:
  /// its portal session closes (Wayland), with the system's indicator, and
  /// its sound is taken no more.
  static Future<void> _stopNative(String? trackId) async {
    try {
      await _screencast.invokeMethod('stop', {'trackId': trackId});
    } on MissingPluginException {
      // Android's, or flutter_webrtc's own sharing without ours.
    } catch (e) {
      _log.debug('Stopping our share of the screen: $e');
    }
  }

  /// A share's own end: ours (see [_stopNative]), and its sound's.
  Future<void> _endShare(LocalVideoTrack track) async {
    final id = track.mediaStreamTrack.id;
    if (_byScreenTrack.remove(id) != null) await _stopNative(id);
    final sound = _screenSound;
    _screenSound = null;
    if (sound == null) return;
    final local = _room?.localParticipant;
    final publication = local?.audioTrackPublications.where((p) => identical(p.track, sound)).firstOrNull;
    try {
      if (local != null && publication != null) {
        await local.removePublishedTrack(publication.sid);
      }
      await sound.stop();
    } catch (e) {
      _log.debug("Stopping the shared screen's sound: $e");
    }
  }

  @override
  Future<void> stopSharing() async {
    final track = _screen;
    _screen = null;
    if (track == null) return;
    await _endShare(track);
    final local = _room?.localParticipant;
    final publication = local?.videoTrackPublications.where((p) => identical(p.track, track)).firstOrNull;
    try {
      if (local != null && publication != null) {
        await local.removePublishedTrack(publication.sid);
      }
      await track.stop();
    } catch (e) {
      _log.debug('Stopping the shared screen: $e');
    }
    _changed();
  }

  @override
  Future<void> setShareSound(bool on) async {
    final sound = _screenSound;
    if (sound == null || on == _screenSoundOn) return;
    _screenSoundOn = on;
    try {
      // Muted, not stopped: starting it again would ask the portal again.
      if (on) {
        await sound.unmute(stopOnMute: false);
      } else {
        await sound.mute(stopOnMute: false);
      }
    } catch (e, stack) {
      _log.warning("Turning the shared screen's sound ${on ? 'on' : 'off'}", e, stack);
    }
    _changed();
  }

  @override
  Future<List<SoundApp>> soundApps() async {
    if (_screenSound == null) return const [];
    try {
      final apps = await _screencast.invokeListMethod<Map<Object?, Object?>>('soundApps') ?? const [];
      return [for (final app in apps) SoundApp(id: '${app['id']}', name: '${app['name']}')];
    } catch (e) {
      _log.debug('Listing the apps with sound: $e');
      return const [];
    }
  }

  @override
  Future<void> shareSoundFrom(SoundApp? app) async {
    if (_screenSound == null) return;
    try {
      await _screencast.invokeMethod('soundFrom', {'app': app?.id ?? ''});
      _screenSoundFrom = app;
      _log.info(app == null ? "The shared screen's sound: every app's" : "The shared screen's sound: one app's");
    } catch (e) {
      _log.warning("Choosing the shared screen's sound: $e");
    }
    _changed();
  }

  /// Runs the microphone through WebRTC as a call does, for the voice
  /// gate's meter outside calls (Settings): from one connection to another
  /// on this device, never further, and not played.
  static Future<MicrophoneTest> testMicrophone() => _MicrophoneLoop.start(_capture);

  @override
  Future<void> disconnect() async {
    _over = true;
    await _close();
    _log.debug('Left the room (sending with key index $_sendIndex)');
  }

  /// Out of the room for good; never throws. Says goodbye only to a room it
  /// is in: otherwise Room.disconnect waits 10 s for an event that came
  /// already, then throws.
  Future<void> _close() async {
    final (room, connected, microphone) = (_room, _connected, _microphone);
    _room = null;
    _connected = false;
    _microphone = null;
    await _gateOpens?.cancel();
    _gateCheck?.cancel();
    _voiceOpen = false;
    if (_asMediaTracks.isNotEmpty) {
      _asMediaTracks.clear();
      try {
        await _streamSound.invokeMethod('stopAll');
      } catch (e) {
        _log.debug("Stopping shared screens' sound as media: $e");
      }
    }
    final listener = _listener;
    _listener = null;
    await listener?.dispose();
    _recheck?.cancel();
    _recheck = null;
    if (room != null) {
      try {
        if (connected) await room.disconnect();
      } catch (e) {
        _log.debug('Saying goodbye to the room: $e');
      }
      try {
        await room.dispose();
      } catch (e) {
        _log.debug('Disposing of the room: $e');
      }
    }
    // Shut, also when never published (the room stops those it has).
    try {
      await microphone?.stop();
      if (_screen case final screen?) {
        await _endShare(screen);
        await screen.stop();
      }
    } catch (e) {
      _log.debug('Closing the microphone: $e');
    }
    _screen = null;
    _videos.clear();
    _trackVolumes.clear();
    _watching.clear();
    for (final subscription in _thumbnails) {
      await subscription.cancel();
    }
    _thumbnails.clear();
    if (!_closed.isCompleted) _closed.complete();
    if (!_states.isClosed) await _states.close();
  }
}

/// The microphone, sent from one peer connection to another on this device:
/// WebRTC takes its audio (and runs the voice gate) only while it is sent
/// somewhere.
class _MicrophoneLoop implements MicrophoneTest {
  _MicrophoneLoop(this._stream, this._from, this._to);

  final rtc.MediaStream _stream;
  final rtc.RTCPeerConnection _from;
  final rtc.RTCPeerConnection _to;

  static Future<MicrophoneTest> start(AudioCaptureOptions capture) async {
    final rtc.MediaStream stream;
    try {
      stream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': capture.toMediaConstraintsMap(),
        'video': false,
      });
    } catch (e, stack) {
      _log.warning('Opening the microphone for a test', e, stack);
      throw MicrophoneTestException(
        '$e'.contains('NotAllowedError')
            ? 'Hanashi may not use the microphone: allow it in the system settings'
            : 'Could not use the microphone',
      );
    }
    rtc.RTCPeerConnection? from;
    rtc.RTCPeerConnection? to;
    try {
      final a = from = await rtc.createPeerConnection({});
      final b = to = await rtc.createPeerConnection({});
      // Each side's candidates, once the other has the description they
      // belong to (before that they would be dropped).
      final forA = _Candidates(a);
      final forB = _Candidates(b);
      a.onIceCandidate = forB.add;
      b.onIceCandidate = forA.add;
      final connected = Completer<void>();
      a.onConnectionState = (state) {
        if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected && !connected.isCompleted) {
          connected.complete();
        }
      };
      // Not played: the meter is what it is for.
      b.onTrack = (event) => event.track.enabled = false;
      for (final track in stream.getAudioTracks()) {
        await a.addTrack(track, stream);
      }
      final offer = _mono(await a.createOffer());
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      await forB.ready();
      final answer = _mono(await b.createAnswer());
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);
      await forA.ready();
      // WebRTC takes the microphone's audio once the audio can go.
      await connected.future.timeout(const Duration(seconds: 5));
      // And runs what comes after its own processing (the gate) only once a
      // sender has been unmuted: off and on, as a call unmutes once its
      // audio is encrypted.
      for (final track in stream.getAudioTracks()) {
        track.enabled = false;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        track.enabled = true;
      }
      _log.info('Testing the microphone');
      return _MicrophoneLoop(stream, a, b);
    } catch (e, stack) {
      _log.warning('Testing the microphone', e, stack);
      await _MicrophoneLoop._end(stream, from, to);
      throw const MicrophoneTestException('Could not test the microphone');
    }
  }

  /// In one channel, as calls send: then WebRTC processes it as in a call.
  /// (In two, the gate would see only the first.)
  static rtc.RTCSessionDescription _mono(rtc.RTCSessionDescription description) {
    final sdp = description.sdp ?? '';
    final opus = RegExp(r'a=rtpmap:(\d+) opus/', caseSensitive: false).firstMatch(sdp)?.group(1);
    if (opus == null) return description;
    final mono = sdp.replaceAllMapped(RegExp('a=fmtp:$opus ([^\r\n]*)'), (match) {
      final params = match.group(1)!.split(';').map((p) => p.trim()).where((p) => !p.contains('stereo='));
      return 'a=fmtp:$opus ${[...params, 'stereo=0', 'sprop-stereo=0'].join(';')}';
    });
    return rtc.RTCSessionDescription(mono, description.type);
  }

  @override
  Future<void> stop() async {
    await _end(_stream, _from, _to);
    _log.info('The microphone test ended');
  }

  static Future<void> _end(rtc.MediaStream stream, rtc.RTCPeerConnection? from, rtc.RTCPeerConnection? to) async {
    try {
      await from?.close();
      await to?.close();
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    } catch (e) {
      _log.debug('Ending the microphone test: $e');
    }
  }
}

/// ICE candidates for [connection], held until it has the remote
/// description they belong to.
class _Candidates {
  _Candidates(this.connection);

  final rtc.RTCPeerConnection connection;
  final _held = <rtc.RTCIceCandidate>[];
  var _ready = false;

  void add(rtc.RTCIceCandidate candidate) {
    if (_ready) {
      unawaited(connection.addCandidate(candidate).catchError((Object _) {}));
    } else {
      _held.add(candidate);
    }
  }

  Future<void> ready() async {
    _ready = true;
    for (final candidate in _held) {
      // One it can't take: the others may do.
      await connection.addCandidate(candidate).catchError((Object _) {});
    }
    _held.clear();
  }
}
