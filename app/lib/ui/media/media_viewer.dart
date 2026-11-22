import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../state/providers.dart';
import '../chat/gif_picker.dart';
import '../widgets/hideable.dart';
import '../widgets/links.dart';
import '../window/window_caption.dart';
import '../window/window_controls.dart';
import 'gif_view.dart';
import 'save_media.dart';

/// Full-screen view of an image, video or GIF message, or playback of an
/// audio file (or of a video sent as a file); or of the video, GIF or
/// picture of a link, also one loaded from its site if the user chose so
/// (see [linkSourcesProvider]).
///
/// A tap hides the bar along the top and the caption, and on phones the
/// system's bars, to see the picture alone; another tap brings them back. On
/// a video with sound the bars come and go with the player's controls. On
/// desktops, F11 or F (or the bar's button) makes the window full screen.
/// A GIF can be saved to the user's GIFs from here. Escape or Backspace
/// closes it; Escape first leaves full screen.
class MediaViewerScreen extends ConsumerStatefulWidget {
  const MediaViewerScreen({super.key, required Envelope this.envelope}) : link = null;

  /// The video or GIF of [link], or its picture, as the sender's app made it.
  const MediaViewerScreen.link({super.key, required LinkPreview this.link}) : envelope = null;

  final Envelope? envelope;
  final LinkPreview? link;

  static Future<void> open(BuildContext context, Envelope envelope) =>
      _show(context, MediaViewerScreen(envelope: envelope));

  static Future<void> openLinkPicture(BuildContext context, LinkPreview link) =>
      _show(context, MediaViewerScreen.link(link: link));

  static Future<void> _show(BuildContext context, MediaViewerScreen viewer) =>
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => viewer));

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

/// How the viewer lays out what it shows.
enum _Layout {
  /// Filling the screen; a tap hides or shows the bars.
  picture,

  /// With the bar among the player's controls, and the system's bars going
  /// with them.
  video,

  /// With the bar always there.
  audio,
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  /// The bars and the caption are hidden.
  var _bare = false;

  /// The window full screen, as the viewer made it (to undo on closing).
  WindowControls? _fullScreen;

  static bool get _phone => const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

  void _toggleBare() {
    setState(() => _bare = !_bare);
    if (_phone) _showSystemBars(!_bare);
  }

  /// Copies of the bar on screen, for a video on phones (see [_countBar]).
  var _bars = 0;

  /// A video's controls hide and show by themselves, and have the bar among
  /// them only while they show; the system's bars go with it, hiding when no
  /// copy of it is on screen. Acted on once the frame is built, as copies
  /// come and go while it is (one taking another's place, say).
  void _countBar(int change) {
    _bars += change;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bare = _bars == 0;
      // Not while the viewer closes, nor under the player's own full screen.
      if (!mounted || bare == _bare || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      setState(() => _bare = bare);
      _showSystemBars(!bare);
    });
  }

  /// The most room the system's bars have taken at this size of screen, kept
  /// so that a video and its controls stay put as the bars come and go.
  /// Turning the phone moves the bars, and changes the size.
  ({Size size, EdgeInsets padding})? _room;

  EdgeInsets _barsRoom(BuildContext context) {
    final size = MediaQuery.sizeOf(context), padding = MediaQuery.paddingOf(context);
    final kept = _room?.size == size ? _room!.padding : EdgeInsets.zero;
    final room = EdgeInsets.fromLTRB(
      max(kept.left, padding.left),
      max(kept.top, padding.top),
      max(kept.right, padding.right),
      max(kept.bottom, padding.bottom),
    );
    _room = (size: size, padding: room);
    return room;
  }

  /// As the video player does for its own full screen.
  static void _showSystemBars(bool show) => SystemChrome.setEnabledSystemUIMode(
    show ? SystemUiMode.manual : SystemUiMode.immersiveSticky,
    overlays: show ? SystemUiOverlay.values : null,
  );

  void _setFullScreen(bool fullScreen) {
    final controls = ref.read(windowControlsProvider);
    if (controls == null || fullScreen == (_fullScreen != null)) return;
    setState(() => _fullScreen = fullScreen ? controls : null);
    controls.setFullScreen(fullScreen);
  }

  @override
  void dispose() {
    if (_bare && _phone) _showSystemBars(true);
    _fullScreen?.setFullScreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final envelope = widget.envelope, link = widget.link;
    final gif = envelope == null ? null : gifOf(envelope);
    // A GIF from its provider (KLIPY) has no file of ours.
    final remote = gif?.remote;
    final media = link?.media ?? link?.thumb ?? envelope?.media;
    // A link's video or GIF that did not come with the message, to load from
    // the site if the user chose so.
    final source = link != null && link.media == null && (ref.watch(linkSourcesProvider).value ?? false)
        ? link.source
        : null;
    final caption = envelope?.text;
    final audio = media?.mime.startsWith('audio/') ?? false;
    final video = envelope?.messageType == MessageType.video || (media?.mime.startsWith('video/') ?? false);
    // Plays over and over, without sound or controls, as a GIF does.
    final loop = link?.kind == LinkKind.gif || gif != null;
    final layout = audio
        ? _Layout.audio
        : (source != null ? source.mime.startsWith('video/') && !loop : video && !loop)
        ? _Layout.video
        : _Layout.picture;
    final controls = ref.watch(windowControlsProvider);
    final title = link != null
        ? link.title ?? linkHost(link.url)
        : media?.name ?? remote?.title ?? (audio ? 'Audio' : (video ? 'Video' : (gif != null ? 'GIF' : 'Photo')));
    final bar = [
      if (_phone && layout == _Layout.video) _Presence(_countBar),
      const BackButton(color: Colors.white),
      // Only the title is the window drag area, so buttons stay responsive.
      Expanded(
        child: WindowDragArea(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ),
      ),
      if (gif != null) _SaveGifButton(gif: gif),
      // Not for KLIPY's GIFs: KLIPY does not allow keeping copies.
      // Nor for a link's picture: the link has the real thing.
      if (link != null)
        IconButton(
          key: const Key('viewer-open-link'),
          tooltip: 'Open link',
          icon: const Icon(Icons.open_in_new, color: Colors.white),
          onPressed: () => confirmOpenLink(context, ref, Uri.parse(link.url)),
        )
      else if (media != null)
        IconButton(
          key: const Key('viewer-download'),
          tooltip: 'Download',
          icon: const Icon(Icons.download, color: Colors.white),
          onPressed: () => saveMedia(context, ref, media),
        ),
      // The video player has its own.
      if (controls != null && layout == _Layout.picture)
        IconButton(
          key: const Key('viewer-full-screen'),
          tooltip: _fullScreen != null ? 'Leave full screen (F11)' : 'Full screen (F11)',
          icon: Icon(_fullScreen != null ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
          onPressed: () => _setFullScreen(_fullScreen == null),
        ),
      const WindowButtons(color: Colors.white, height: kToolbarHeight),
    ];
    final videoBar = layout == _Layout.video ? bar : null;
    final shown = switch ((media, remote)) {
      _ when source != null => _SourceView(link: link!, source: source, bar: videoBar),
      (_, final remote?) => _RemoteImageView(media: remote),
      (final media?, _) when audio || video => _VideoView(
        load: (onProgress) async {
          // Streamed from the encrypted cache, decrypted as it plays.
          final playable = await ref.read(chatRepositoryProvider).playableMedia(media, onProgress: onProgress);
          if (playable == null) throw const _Unavailable();
          return playable;
        },
        audio: audio,
        loop: loop,
        bar: videoBar,
      ),
      // A link's picture made small stands in for one it does not bring.
      (final media?, _) => _ImageView(media: media, standIn: link != null && link.media == null),
      _ => const _Message('Nothing to show'),
    };
    final insets = MediaQuery.paddingOf(context);
    return _CloseOnKeys(
      fullScreen: _fullScreen != null,
      onFullScreen: controls != null && layout == _Layout.picture ? _setFullScreen : null,
      child: Scaffold(
        backgroundColor: Colors.black,
        // Centred on the screen, under a see-through title bar.
        extendBodyBehindAppBar: true,
        appBar: layout == _Layout.video
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(kToolbarHeight),
                child: Hideable(key: const Key('viewer-bar'), hidden: _bare, child: _Bar(bar)),
              ),
        body: switch (layout) {
          _Layout.picture => Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: _toggleBare, child: shown),
              if (caption != null && caption.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Hideable(
                    key: const Key('viewer-caption'),
                    hidden: _bare,
                    child: ColoredBox(
                      color: const Color(0x99000000),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16 + insets.left, 12, 16 + insets.right, 12 + insets.bottom),
                        child: Text(caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // The player's controls keep clear of the system's bars.
          _Layout.video => Builder(
            builder: (context) {
              final room = _barsRoom(context);
              final captioned = caption != null && caption.isNotEmpty;
              return Column(
                children: [
                  Expanded(
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(padding: captioned ? room.copyWith(bottom: 0) : room),
                      child: shown,
                    ),
                  ),
                  if (captioned)
                    Padding(
                      padding: EdgeInsets.fromLTRB(16 + room.left, 16, 16 + room.right, 16 + room.bottom),
                      child: Text(caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
                    ),
                ],
              );
            },
          ),
          // As much room above the media as the navigation bar (which
          // Android draws over the app) takes below it, and as much on either
          // side as on the other: centred on the screen, with the controls
          // clear of the bar.
          _Layout.audio => Padding(
            padding: EdgeInsets.fromLTRB(
              max(insets.left, insets.right),
              insets.bottom,
              max(insets.left, insets.right),
              insets.bottom,
            ),
            child: Column(
              children: [
                Expanded(child: shown),
                if (caption != null && caption.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
                  ),
              ],
            ),
          ),
        },
      ),
    );
  }
}

/// The bar along the top: back, what is shown, and what can be done with it.
class _Bar extends StatelessWidget {
  const _Bar(this.items);

  final List<Widget> items;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0x99000000),
    child: SafeArea(
      bottom: false,
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(children: items),
      ),
    ),
  );
}

/// Shows nothing; tells [onChange] when it comes (1) and goes (-1), along
/// with what it is in.
class _Presence extends StatefulWidget {
  const _Presence(this.onChange);

  final ValueChanged<int> onChange;

  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence> {
  @override
  void initState() {
    super.initState();
    widget.onChange(1);
  }

  @override
  void dispose() {
    widget.onChange(-1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Closes the viewer on Escape or Backspace; makes the window full screen on
/// F11 or F, if [onFullScreen] can, and Escape leaves that first. Seen
/// before the focused widget sees the key, as the video controls take
/// Escape (out of their own full screen) and F.
class _CloseOnKeys extends StatefulWidget {
  const _CloseOnKeys({required this.fullScreen, required this.onFullScreen, required this.child});

  final bool fullScreen;
  final ValueChanged<bool>? onFullScreen;
  final Widget child;

  @override
  State<_CloseOnKeys> createState() => _CloseOnKeysState();
}

class _CloseOnKeysState extends State<_CloseOnKeys> {
  /// Pressed while the viewer was on top; closes it once let go.
  LogicalKeyboardKey? _pressed;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final key = event.logicalKey;
    final onFullScreen = widget.onFullScreen;
    final fullScreenKey = onFullScreen != null && (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF);
    if (key != LogicalKeyboardKey.escape && key != LogicalKeyboardKey.backspace && !fullScreenKey) return false;
    // Not with something over the viewer (a menu, or a video in full
    // screen, which Escape leaves), nor while it closes already.
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) {
      _pressed = null;
      return false;
    }
    switch (event) {
      case KeyDownEvent() when fullScreenKey:
        onFullScreen(!widget.fullScreen);
      case KeyDownEvent() when key == LogicalKeyboardKey.escape && widget.fullScreen:
        _pressed = null;
        onFullScreen?.call(false);
      case KeyDownEvent():
        _pressed = key;
      // On release: closed on the press, a held Backspace would go on
      // deleting in the chat's text field.
      case KeyUpEvent() when key == _pressed:
        _pressed = null;
        Navigator.of(context).maybePop();
      case _:
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Saves the GIF to the user's GIFs, or takes it out again.
class _SaveGifButton extends ConsumerWidget {
  const _SaveGifButton({required this.gif});

  final GifRef gif;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = (ref.watch(savedGifsProvider).value ?? const []).any((g) => g.key == gif.key);
    return IconButton(
      key: const Key('viewer-save-gif'),
      tooltip: saved ? 'Remove from saved GIFs' : 'Save GIF',
      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined, color: Colors.white),
      onPressed: () => setGifSaved(context, ref, gif, !saved),
    );
  }
}

/// A GIF from its provider, loaded now: the user asked to see it.
class _RemoteImageView extends ConsumerStatefulWidget {
  const _RemoteImageView({required this.media});

  final RemoteMedia media;

  @override
  ConsumerState<_RemoteImageView> createState() => _RemoteImageViewState();
}

class _RemoteImageViewState extends ConsumerState<_RemoteImageView> {
  late final _loading = ref.read(remoteMediaLoaderProvider).load(widget.media);

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _loading,
    builder: (context, snapshot) => switch (snapshot) {
      AsyncSnapshot(:final data?) => _ZoomableImage(MemoryImage(data), semanticLabel: widget.media.title),
      AsyncSnapshot(:final error?) => _Message('Could not load the GIF: $error'),
      _ => const Center(child: CircularProgressIndicator(color: Colors.white)),
    },
  );
}

class _ImageView extends ConsumerStatefulWidget {
  const _ImageView({required this.media, this.standIn = false});

  final MediaRef media;

  /// Not the picture itself but a copy made small: always smoothed.
  final bool standIn;

  @override
  ConsumerState<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends ConsumerState<_ImageView> {
  Uint8List? _bytes;
  double? _progress;
  Object? _error;

  @override
  void initState() {
    super.initState();
    ref
        .read(chatRepositoryProvider)
        .mediaBytes(widget.media, onProgress: (p) => mounted ? setState(() => _progress = p) : null)
        .then(
          (bytes) => mounted ? setState(() => _bytes = bytes) : null,
          onError: (Object e) => mounted ? setState(() => _error = e) : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) return _ZoomableImage(MemoryImage(bytes), smooth: widget.standIn);
    if (_error != null) return _Message('Could not load the photo: $_error');
    // Show the thumbnail, if cached, while the full image downloads.
    final thumb = widget.media.thumb;
    final thumbBytes = thumb == null ? null : ref.watch(mediaBytesProvider(mediaKey(thumb))).value;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbBytes != null) Image.memory(thumbBytes, fit: BoxFit.contain),
        Center(
          child: CircularProgressIndicator(value: _progress, color: Colors.white),
        ),
      ],
    );
  }
}

/// [image] fitted to the screen, to zoom into. Shown larger than it is, it is
/// not smoothed: a small or pixel-art picture shows as it is, each of its
/// pixels a sharp square, rather than blurred. Shown smaller, or with
/// [smooth], it is.
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage(this.image, {this.semanticLabel, this.smooth = false});

  final ImageProvider image;
  final String? semanticLabel;
  final bool smooth;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _zoom = TransformationController();
  ImageStream? _stream;
  late final _listener = ImageStreamListener((info, _) {
    final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
    info.dispose();
    if (mounted && size != _size) setState(() => _size = size);
  });

  /// In image pixels, once decoded.
  Size? _size;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_ZoomableImage old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    _stream?.removeListener(_listener);
    _stream = widget.image.resolve(createLocalImageConfiguration(context))..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = _size;
      // Screen pixels per image pixel.
      final scale = size == null || size.isEmpty
          ? null
          : min(box.maxWidth / size.width, box.maxHeight / size.height) *
                MediaQuery.devicePixelRatioOf(context) *
                _zoom.value.getMaxScaleOnAxis();
      return InteractiveViewer(
        transformationController: _zoom,
        maxScale: 6,
        child: Center(
          child: Image(
            key: const Key('viewer-image'),
            image: widget.image,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: widget.semanticLabel,
            filterQuality: !widget.smooth && scale != null && scale > 1 ? FilterQuality.none : FilterQuality.medium,
          ),
        ),
      );
    },
  );
}

/// Where a [_VideoView]'s player finds what it plays, and what to do once
/// the view is gone.
typedef _Playable = ({String uri, Future<void> Function()? close});

class _Unavailable implements Exception {
  const _Unavailable();

  @override
  String toString() => 'It is not available.';
}

/// The player's controls for this kind of device: the phone's or the
/// desktop's, as the viewer's own bars expect. media_kit's own choice
/// (`AdaptiveVideoControls`) goes by `package:flutter/material`'s theme,
/// which this app (on material_ui) does not have; without one, that is a
/// theme made once, for whichever platform it was first asked on.
VideoControlsBuilder get _videoControls =>
    _MediaViewerScreenState._phone ? MaterialVideoControls : MaterialDesktopVideoControls;

class _VideoView extends ConsumerStatefulWidget {
  const _VideoView({required this.load, this.audio = false, this.loop = false, this.bar});

  /// Gets it ready to play, telling how far it got.
  final Future<_Playable> Function(void Function(double progress) onProgress) load;

  /// No picture to show: a note instead, and the controls stay in view.
  final bool audio;

  /// Plays over and over, as a GIF does, without controls.
  final bool loop;

  /// The viewer's bar, which comes and goes with the controls.
  final List<Widget>? bar;

  @override
  ConsumerState<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<_VideoView> {
  /// Once it is ready.
  Player? _player;
  VideoController? _controller;
  Future<void> Function()? _close;
  double? _progress;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Media is encrypted end to end, so it is downloaded and decrypted
    // before playing; there is no streaming from the server.
    widget.load((p) => mounted ? setState(() => _progress = p) : null).then((playable) {
      if (!mounted) {
        playable.close?.call();
        return;
      }
      _close = playable.close;
      final player = _player = Player();
      setState(() => _controller = VideoController(player));
      if (widget.loop) player.setPlaylistMode(PlaylistMode.single);
      player.open(Media(playable.uri));
    }, onError: (Object e) => mounted ? setState(() => _error = e) : null);
  }

  @override
  void dispose() {
    _player?.dispose();
    _close?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final bar = widget.bar;
    if (_error != null || controller == null) {
      final waiting = _error != null
          ? _Message('Could not load the ${widget.audio ? 'audio' : 'video'}: $_error')
          : Center(
              child: CircularProgressIndicator(value: _progress, color: Colors.white),
            );
      if (bar == null) return waiting;
      return Stack(
        fit: StackFit.expand,
        children: [
          waiting,
          Align(alignment: Alignment.topCenter, child: _Bar(bar)),
        ],
      );
    }
    if (widget.loop) return Video(controller: controller, controls: NoVideoControls);
    if (!widget.audio) {
      if (bar == null) return Video(controller: controller, controls: _videoControls);
      // The controls (the bar among them) keep clear of the system's bars,
      // while the video fills the screen.
      final padding = MediaQuery.paddingOf(context);
      return MaterialVideoControlsTheme(
        normal: MaterialVideoControlsThemeData(
          visibleOnMount: true,
          padding: padding,
          topButtonBar: bar,
          topButtonBarMargin: EdgeInsets.zero,
        ),
        fullscreen: kDefaultMaterialVideoControlsThemeDataFullscreen,
        child: MaterialDesktopVideoControlsTheme(
          normal: MaterialDesktopVideoControlsThemeData(
            visibleOnMount: true,
            padding: padding,
            topButtonBar: bar,
            topButtonBarMargin: EdgeInsets.zero,
          ),
          fullscreen: kDefaultMaterialDesktopVideoControlsThemeDataFullscreen,
          child: Video(controller: controller, controls: _videoControls),
        ),
      );
    }
    const mobile = MaterialVideoControlsThemeData(visibleOnMount: true, controlsHoverDuration: Duration(days: 1));
    const desktop = MaterialDesktopVideoControlsThemeData(
      visibleOnMount: true,
      controlsHoverDuration: Duration(days: 1),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        const Center(child: Icon(Icons.music_note_rounded, size: 120, color: Colors.white24)),
        MaterialVideoControlsTheme(
          normal: mobile,
          fullscreen: mobile,
          child: MaterialDesktopVideoControlsTheme(
            normal: desktop,
            fullscreen: desktop,
            child: Video(controller: controller, fill: Colors.transparent, controls: _videoControls),
          ),
        ),
      ],
    );
  }
}

/// Pictures and GIFs of links loaded from their sites this time the app
/// runs, so that opening one again fetches nothing.
final _loadedSourcesProvider = Provider<Map<String, File>>((ref) => {});

/// A link's video or GIF that did not come with the message, loaded from its
/// site once the user agrees: they are asked when it opens, and again with
/// the button if they said no. Until then nothing is fetched. A video
/// streams; a picture or GIF is downloaded first.
class _SourceView extends ConsumerStatefulWidget {
  const _SourceView({required this.link, required this.source, this.bar});

  final LinkPreview link;
  final LinkSource source;

  /// The viewer's bar, for a video (see [_VideoView.bar]).
  final List<Widget>? bar;

  @override
  ConsumerState<_SourceView> createState() => _SourceViewState();
}

class _SourceViewState extends ConsumerState<_SourceView> {
  /// The user agreed.
  var _agreed = false;
  File? _picture;
  double? _progress;
  Object? _error;

  bool get _video => widget.source.mime.startsWith('video/');

  String get _host => Uri.parse(widget.source.url).host;

  @override
  void initState() {
    super.initState();
    _picture = ref.read(_loadedSourcesProvider)[widget.source.url];
    if (_picture == null) WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  Future<void> _ask() async {
    if (!mounted) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('source-dialog'),
        title: Text('Load from $_host?'),
        content: Text(
          'This ${widget.link.kind == LinkKind.gif ? 'GIF' : 'video'} did not come with the message. '
          'Loading it from $_host lets that website see your IP address.',
        ),
        actions: [
          TextButton(
            key: const Key('source-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('source-load'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Load'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    setState(() => _agreed = true);
    if (!_video) {
      try {
        final file = await ref
            .read(linkPreviewFetcherProvider)
            .loadSource(widget.source, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
        ref.read(_loadedSourcesProvider)[widget.source.url] = file;
        if (mounted) setState(() => _picture = file);
      } on Exception catch (e) {
        if (mounted) setState(() => _error = e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final picture = _picture;
    if (picture != null) return _ZoomableImage(FileImage(picture));
    if (_agreed && _video) {
      return _VideoView(
        load: (_) async {
          final stream = await ref.read(linkPreviewFetcherProvider).stream(widget.source.url);
          return (uri: '${stream.address}', close: stream.close);
        },
        loop: widget.link.kind == LinkKind.gif,
        bar: widget.bar,
      );
    }
    final Widget shown;
    if (_error != null) {
      shown = _Message('Could not load it: $_error');
    } else if (_agreed) {
      shown = Center(
        child: CircularProgressIndicator(value: _progress, color: Colors.white),
      );
    } else {
      // The picture the sender's app made, until the user agrees.
      final thumb = widget.link.thumb;
      final thumbBytes = thumb == null ? null : ref.watch(mediaBytesProvider(mediaKey(thumb))).value;
      shown = Stack(
        fit: StackFit.expand,
        children: [
          if (thumbBytes != null)
            Image.memory(thumbBytes, fit: BoxFit.contain, color: Colors.black45, colorBlendMode: BlendMode.darken),
          Center(
            child: FilledButton.icon(
              key: const Key('source-ask'),
              onPressed: _ask,
              icon: Icon(_video ? Icons.play_arrow_rounded : Icons.gif_box_outlined),
              label: Text('Load from $_host'),
            ),
          ),
        ],
      );
    }
    final bar = widget.bar;
    if (bar == null) return shown;
    return Stack(
      fit: StackFit.expand,
      children: [
        shown,
        Align(alignment: Alignment.topCenter, child: _Bar(bar)),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70),
        textAlign: TextAlign.center,
      ),
    ),
  );
}
