import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/chat_repository.dart' show PlayableMedia;
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';

/// The GIF a message shows: a GIF message's, or a GIF file sent as a photo.
GifRef? gifOf(Envelope envelope) {
  if (envelope.messageType == MessageType.gif) return envelope.gif;
  final media = envelope.messageType == MessageType.image ? envelope.media : null;
  return media?.mime == 'image/gif' ? GifRef.media(media!) : null;
}

/// A GIF, playing: an uploaded file (its thumbnail until the file is here),
/// or one its provider serves. Without [autoLoad], a provider's GIF waits
/// for a tap (see [gifAutoLoadProvider]).
class GifView extends StatelessWidget {
  const GifView({super.key, required this.gif, this.fit = BoxFit.cover, this.autoLoad = true});

  final GifRef gif;
  final BoxFit fit;
  final bool autoLoad;

  @override
  Widget build(BuildContext context) => switch (gif) {
    GifRef(:final media?) => UploadedImage(media: media, fit: fit),
    GifRef(:final remote?) => RemoteImage(media: remote, fit: fit, autoLoad: autoLoad),
    _ => const GifPlaceholder(),
  };
}

/// Larger images play only in the viewer.
const maxInlineAnimationBytes = 10 << 20;

/// An uploaded image in full (up to [maxInlineAnimationBytes]), so that an
/// animated one plays; its thumbnail until then.
class UploadedImage extends ConsumerWidget {
  const UploadedImage({
    super.key,
    required this.media,
    this.fit = BoxFit.cover,
    this.placeholder = const GifPlaceholder(),
    this.cacheWidth,
  });

  final MediaRef media;
  final BoxFit fit;

  /// Until the file is here.
  final Widget placeholder;

  /// Decoded no wider than this many pixels, if given (for many small ones).
  final int? cacheWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final full = media.size <= maxInlineAnimationBytes ? ref.watch(mediaBytesProvider(mediaKey(media))).value : null;
    final thumb = media.thumb;
    final shown = full ?? (thumb == null ? null : ref.watch(mediaBytesProvider(mediaKey(thumb))).value);
    return shown == null ? placeholder : Image.memory(shown, fit: fit, gaplessPlayback: true, cacheWidth: cacheWidth);
  }
}

/// A video without sound (up to [maxInlineAnimationBytes]) playing in place
/// over and over, like a GIF; [poster] until it plays.
class LoopingVideo extends ConsumerStatefulWidget {
  const LoopingVideo({super.key, required this.media, this.poster, this.fit = BoxFit.cover});

  final MediaRef media;
  final MediaRef? poster;
  final BoxFit fit;

  @override
  ConsumerState<LoopingVideo> createState() => _LoopingVideoState();
}

class _LoopingVideoState extends ConsumerState<LoopingVideo> {
  Player? _player;
  VideoController? _controller;

  /// Ends the stream the player plays from.
  Future<void> Function()? _close;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    if (widget.media.size > maxInlineAnimationBytes) return;
    unawaited(_start());
  }

  Future<void> _start() async {
    final PlayableMedia? playable;
    try {
      playable = await ref.read(chatRepositoryProvider).playableMedia(widget.media);
    } on Object {
      return; // Not here (offline, say): the picture stays.
    }
    if (playable == null) return;
    if (_disposed) {
      await playable.close?.call();
      return;
    }
    _close = playable.close;
    final Player player;
    try {
      player = Player();
    } catch (_) {
      return; // No player on this device: the picture stays.
    }
    setState(() {
      _player = player;
      _controller = VideoController(player);
    });
    player
      ..setVolume(0)
      ..setPlaylistMode(PlaylistMode.single)
      ..open(Media(playable.uri));
  }

  @override
  void dispose() {
    _disposed = true;
    // The player first: it stops reading from the stream.
    final close = _close;
    unawaited(_player?.dispose().whenComplete(() => close?.call()) ?? close?.call() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final poster = widget.poster;
    final picture = poster == null ? null : ref.watch(mediaBytesProvider(mediaKey(poster))).value;
    final controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (picture != null)
          Image.memory(picture, fit: widget.fit, gaplessPlayback: true)
        else
          const GifPlaceholder(),
        if (controller != null)
          Video(controller: controller, controls: NoVideoControls, fit: widget.fit, fill: Colors.transparent),
      ],
    );
  }
}

/// [media] from its provider, which sees the IP address of whoever loads it;
/// without [autoLoad], only after a tap.
class RemoteImage extends ConsumerStatefulWidget {
  const RemoteImage({super.key, required this.media, this.fit = BoxFit.cover, this.autoLoad = true});

  final RemoteMedia media;
  final BoxFit fit;
  final bool autoLoad;

  @override
  ConsumerState<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends ConsumerState<RemoteImage> {
  Future<Uint8List>? _loading;

  @override
  void didUpdateWidget(RemoteImage old) {
    super.didUpdateWidget(old);
    if (old.media.url != widget.media.url) _loading = null;
  }

  void _load() {
    setState(() {
      _loading = ref.read(remoteMediaLoaderProvider).load(widget.media);
    });
  }

  Widget _image(Uint8List bytes) =>
      Image.memory(bytes, fit: widget.fit, gaplessPlayback: true, semanticLabel: widget.media.title);

  @override
  Widget build(BuildContext context) {
    final loader = ref.watch(remoteMediaLoaderProvider);
    final bytes = loader.cached(widget.media);
    if (bytes != null) return _image(bytes);
    if (_loading == null && widget.autoLoad) _loading = loader.load(widget.media);
    if (_loading == null) {
      return GifPlaceholder(key: const Key('gif-tap-to-load'), hint: 'Tap to load', onTap: _load);
    }
    return FutureBuilder(
      future: _loading,
      builder: (context, snapshot) => switch (snapshot) {
        AsyncSnapshot(:final data?) => _image(data),
        AsyncSnapshot(hasError: true) => GifPlaceholder(
          icon: Icons.broken_image_outlined,
          hint: 'Tap to try again',
          onTap: _load,
        ),
        _ => const GifPlaceholder(),
      },
    );
  }
}

/// Where a GIF goes while it is not here (yet).
class GifPlaceholder extends StatelessWidget {
  const GifPlaceholder({super.key, this.icon, this.hint, this.onTap});

  final IconData? icon;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = ColoredBox(
      color: context.palette.listSelected,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, color: context.palette.textSecondary) else const GifBadge(),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(hint!, style: TextStyle(fontSize: 12, color: context.palette.textSecondary)),
              ),
          ],
        ),
      ),
    );
    return onTap == null ? box : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: box);
  }
}

/// "GIF", as on a GIF in a chat.
class GifBadge extends StatelessWidget {
  const GifBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(4)),
    child: const Text(
      'GIF',
      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
    ),
  );
}
