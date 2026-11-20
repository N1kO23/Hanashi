import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../calls/call_connection.dart';
import '../../calls/call_controller.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/hideable.dart';
import '../window/window_controls.dart';
import 'call_volume.dart';
import 'call_widgets.dart' show CallClock, HoldToTalk, pushToTalkOn;

/// Whether there is anything to see in a call: a camera on or a screen
/// shared, by this device or anyone (watched or not).
bool callHasVideo(CallView view) =>
    view.room.camera != null ||
    view.sharing ||
    view.room.peers.any((p) => p.camera != null || p.screen != null || p.unwatchedScreen);

/// Whether the call's view shows, where it has a place: there is something to
/// see, or it was opened (see [callViewOpenProvider]).
bool callShown(CallView view, WidgetRef ref) => callHasVideo(view) || ref.watch(callViewOpenProvider);

/// The call's view, opened from the call bar for a call with nothing to see:
/// its people, in a grid.
final callViewOpenProvider = NotifierProvider<CallViewOpen, bool>(CallViewOpen.new);

class CallViewOpen extends Notifier<bool> {
  @override
  bool build() {
    // Not past the call.
    ref.listen(callControllerProvider.select((v) => v.phase.inCall), (_, inCall) {
      if (!inCall) state = false;
    });
    return false;
  }

  void set(bool open) => state = open;
}

/// The call's video fills the window rather than showing in its chat.
final callStageFullProvider = NotifierProvider<CallStageFull, bool>(CallStageFull.new);

class CallStageFull extends Notifier<bool> {
  @override
  bool build() {
    // Not past the call.
    ref.listen(callControllerProvider.select((v) => v.phase.inCall), (_, inCall) {
      if (!inCall) state = false;
    });
    return false;
  }

  void set(bool full) => state = full;
}

/// The call's video fills the screen: the window full screen (desktops),
/// with the stage filling it. Left, it goes back to where it was: its chat,
/// or the filled window.
final callFullScreenProvider = NotifierProvider<CallFullScreen, bool>(CallFullScreen.new);

class CallFullScreen extends Notifier<bool> {
  var _filledBefore = false;

  @override
  bool build() {
    // Not past the call.
    ref.listen(callControllerProvider.select((v) => v.phase.inCall), (_, inCall) {
      if (inCall || !state) return;
      state = false;
      unawaited(ref.read(windowControlsProvider)?.setFullScreen(false));
    });
    return false;
  }

  void set(bool on) {
    if (on == state) return;
    final fill = ref.read(callStageFullProvider.notifier);
    if (on) {
      _filledBefore = ref.read(callStageFullProvider);
      fill.set(true);
    } else {
      fill.set(_filledBefore);
    }
    state = on;
    unawaited(ref.read(windowControlsProvider)?.setFullScreen(on));
  }
}

/// The tile shown large on the stage, chosen by a click; else the first
/// shared screen. The same in the chat and over the whole window.
final callPinnedProvider = NotifierProvider<CallPinned, Object?>(CallPinned.new);

class CallPinned extends Notifier<Object?> {
  @override
  Object? build() {
    ref.listen(callControllerProvider.select((v) => v.phase.inCall), (_, inCall) {
      if (!inCall) state = null;
    });
    return null;
  }

  void set(Object? key) => state = key;

  void toggle(Object key) => state = state == key ? null : key;
}

/// Menus of the stage that are open: its controls stay while there are.
final callChromeHolds = ValueNotifier<int>(0);

/// Narrow, as on phones (held either way) and in narrow windows: a call
/// with video gets a view of its own ([PhoneCallView]) rather than a place
/// in its chat.
bool narrowCallLayout(BuildContext context, WidgetRef ref) {
  final size = MediaQuery.sizeOf(context);
  return size.width < 720 || ref.watch(callOnPhoneProvider) && size.shortestSide < 600;
}

/// The phone's call view shows its large video full screen: the phone turned
/// the video's way, nothing over it until a tap brings the controls back.
final phoneCallFullScreenProvider = NotifierProvider<PhoneCallFullScreen, bool>(PhoneCallFullScreen.new);

class PhoneCallFullScreen extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(callControllerProvider.select((v) => v.phase.inCall), (_, inCall) {
      if (!inCall) state = false;
    });
    return false;
  }

  void set(bool on) => state = on;
}

/// On narrow layouts, the call's own view is put away for the call bar.
final callViewMinimizedProvider = NotifierProvider<CallViewMinimized, bool>(CallViewMinimized.new);

class CallViewMinimized extends Notifier<bool> {
  @override
  bool build() {
    // The next call shows its own again.
    ref.listen(callControllerProvider.select((v) => v.phase.inCall), (_, inCall) {
      if (!inCall) state = false;
    });
    return false;
  }

  void set(bool minimized) => state = minimized;
}

/// On phones and in narrow windows, a call with video fills the screen: the
/// main video edge to edge, with this device's camera small in a corner, and
/// over it the others in a strip and the controls, which a tap takes away
/// and brings back (see [_PhoneCallBody]). Put away (its button, or the
/// system's back: the app's [backButtonDispatcher]), the call bar stands for
/// it. Over the lock screen ([locked]) there is no putting it away, only
/// unlocking, and names show only where notifications show them. With a
/// navigator of its own, for tooltips, as it shows above the app's.
class PhoneCallView extends ConsumerWidget {
  const PhoneCallView({super.key, this.locked = false, this.backButtonDispatcher});

  final bool locked;
  final BackButtonDispatcher? backButtonDispatcher;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _CallNavigator(
    key: const ValueKey('phone-call-navigator'),
    // Over the lock screen there is nothing to go back to.
    backButtonDispatcher: locked ? null : backButtonDispatcher,
    // Out of full screen first.
    onBack: () => ref.read(phoneCallFullScreenProvider)
        ? ref.read(phoneCallFullScreenProvider.notifier).set(false)
        : ref.read(callViewMinimizedProvider.notifier).set(true),
    child: _PhoneCallBody(locked: locked),
  );
}

/// A navigator of the call's own, above the app's, for tooltips and dialogs.
/// The system's back puts its view away ([onBack]), ahead of the app's own
/// back ([backButtonDispatcher]). Android asks ahead whether the app handles
/// back (see `HomeShell`): this says it does, where a navigator of one page
/// would say it does not, and that would stay after it is gone.
class _CallNavigator extends StatefulWidget {
  const _CallNavigator({super.key, required this.child, required this.onBack, this.backButtonDispatcher});

  final Widget child;
  final VoidCallback onBack;
  final BackButtonDispatcher? backButtonDispatcher;

  @override
  State<_CallNavigator> createState() => _CallNavigatorState();
}

class _CallNavigatorState extends State<_CallNavigator> {
  ChildBackButtonDispatcher? _back;

  @override
  void initState() {
    super.initState();
    _hook();
  }

  @override
  void didUpdateWidget(_CallNavigator old) {
    super.didUpdateWidget(old);
    if (old.backButtonDispatcher != widget.backButtonDispatcher) {
      _unhook();
      _hook();
    }
  }

  @override
  void dispose() {
    _unhook();
    super.dispose();
  }

  void _hook() {
    final parent = widget.backButtonDispatcher;
    if (parent == null) return;
    _back = parent.createChildBackButtonDispatcher()
      ..addCallback(_onBack)
      ..takePriority();
  }

  void _unhook() {
    _back?.removeCallback(_onBack);
    _back = null;
  }

  Future<bool> _onBack() {
    widget.onBack();
    return SynchronousFuture(true);
  }

  @override
  Widget build(BuildContext context) => Navigator(
    onGenerateRoute: (_) => PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => PopScope(canPop: false, child: widget.child),
    ),
  );
}

class _PhoneCallBody extends ConsumerStatefulWidget {
  const _PhoneCallBody({required this.locked});

  final bool locked;

  @override
  ConsumerState<_PhoneCallBody> createState() => _PhoneCallBodyState();
}

/// The large video fills it; the bar at the top, the strip and the controls
/// float over it. A tap on the video takes them away (with the system's
/// bars, on phones) and brings them back; they go by themselves once
/// untouched for a while, while there is video to see. Taken away, a tap
/// only brings them back: nothing is pressed by mistake. A shared screen
/// large zooms (pinch, or a double tap), and full screen turns the phone the
/// video's way.
class _PhoneCallBodyState extends ConsumerState<_PhoneCallBody> {
  static const _idle = Duration(seconds: 5);

  /// The tile shown large, chosen by a tap.
  Object? _pinned;

  /// The controls show; they go once untouched for [_idle] while the large
  /// tile has video ([_video]).
  var _shown = true;
  var _video = false;
  CallVideo? _large;
  Timer? _hide;

  /// A shared screen zoomed, and which large tile the zoom is for.
  final _zoom = TransformationController();
  Object? _zoomFor;
  var _doubleTapAt = Offset.zero;

  /// The room the controls at the bottom take, measured: one's own picture
  /// stays above them.
  final _bottom = GlobalKey();
  var _bottomHeight = 0.0;

  late final bool _phone = ref.read(callOnPhoneProvider);

  /// The system's bars show, as last asked (phones).
  bool? _bars;

  /// The phone was turned for full screen.
  var _turned = false;

  @override
  void initState() {
    super.initState();
    callChromeHolds.addListener(_wake);
    _wake();
  }

  @override
  void dispose() {
    _hide?.cancel();
    callChromeHolds.removeListener(_wake);
    _zoom.dispose();
    if (_phone) {
      if (_bars == false) _systemBars(true);
      if (_turned) unawaited(SystemChrome.setPreferredOrientations(const []));
    }
    super.dispose();
  }

  /// As the media viewer does.
  static void _systemBars(bool show) => unawaited(
    SystemChrome.setEnabledSystemUIMode(
      show ? SystemUiMode.manual : SystemUiMode.immersiveSticky,
      overlays: show ? SystemUiOverlay.values : null,
    ),
  );

  void _setShown(bool shown) {
    if (shown != _shown) setState(() => _shown = shown);
    final bars = shown && !ref.read(phoneCallFullScreenProvider);
    if (!_phone || bars == _bars) return;
    _bars = bars;
    _systemBars(bars);
  }

  /// The controls show, for a while.
  void _wake() {
    _hide?.cancel();
    if (!mounted) return;
    _setShown(true);
    _hide = Timer(_idle, () {
      if (mounted && _video && callChromeHolds.value == 0) _setShown(false);
    });
  }

  void _toggle() {
    if (!_shown) return _wake();
    _hide?.cancel();
    _setShown(false);
  }

  void _pin(Object key) {
    setState(() => _pinned = _pinned == key ? null : key);
    _wake();
  }

  void _zoomAt(Offset at) {
    if (_zoom.value.getMaxScaleOnAxis() > 1.01) {
      _zoom.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    _zoom.value = Matrix4.translationValues(-at.dx * (scale - 1), -at.dy * (scale - 1), 0)
      ..multiply(Matrix4.diagonal3Values(scale, scale, 1));
  }

  /// In or out of full screen: turned the large video's way (as its sender
  /// says it is), the controls away; out, as it was.
  void _fullScreen(bool on) {
    if (on) {
      final size = _large?.size;
      if (_phone && size != null && size.width != size.height) {
        _turned = true;
        unawaited(
          SystemChrome.setPreferredOrientations(
            size.width > size.height
                ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
                : const [DeviceOrientation.portraitUp],
          ),
        );
      }
      _hide?.cancel();
      _setShown(false);
    } else {
      if (_turned) unawaited(SystemChrome.setPreferredOrientations(const []));
      _turned = false;
      _wake();
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(callControllerProvider);
    final call = view.call;
    if (!view.phase.inCall || call == null) return const ColoredBox(color: Colors.black);
    ref.listen(phoneCallFullScreenProvider, (_, on) => _fullScreen(on));
    final fullScreen = ref.watch(phoneCallFullScreenProvider);
    final me = ref.watch(chatRepositoryProvider).me;
    // Over the lock screen, names show where notifications show them.
    final named = !widget.locked || (ref.watch(notificationPreferencesProvider).value?.preview ?? true);
    final summary = ref.watch(conversationProvider(call.conv));
    final profiles = ref.watch(profilesProvider).value ?? const {};
    final caller = profiles[call.startedBy]?.displayName ?? UserId.fallbackName(call.startedBy, me: me);
    final title = !named ? context.appName : summary?.title ?? (widget.locked ? caller : 'Call');
    final status = switch (view.phase) {
      CallPhase.connecting => 'Connecting...',
      _ when call.unanswered && call.startedBy == me => 'Calling...',
      _ => null,
    };
    final unheard = view.room.peers.any((p) => !p.encrypted || !p.decrypting);

    final (:screens, :people, :mine) = _tilesOf(view, ref, named: named);
    final self = people.first;
    final others = [...screens, ...people.skip(1)];
    // A pinned one, else a shared screen watched, else a camera, else anyone;
    // one's own shared screen only when pinned. With nothing to see (opened
    // from the call bar), everyone in a grid instead.
    final grid = !callHasVideo(view);
    final main =
        [...others, self, ?mine].where((t) => t.key == _pinned).firstOrNull ??
        others.where((t) => t.video != null).firstOrNull ??
        others.firstOrNull ??
        self;
    final strip = grid ? const <_TileData>[] : [for (final t in [...others, ?mine]) if (t.key != main.key) t];
    _large = main.video;
    if (_video != (main.video != null)) {
      _video = main.video != null;
      // Nothing to see: the controls stay.
      if (!_video) WidgetsBinding.instance.addPostFrameCallback((_) => _wake());
    }
    if (_zoomFor != main.key) {
      _zoomFor = main.key;
      WidgetsBinding.instance.addPostFrameCallback((_) => _zoom.value = Matrix4.identity());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final height = (_bottom.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;
      if (mounted && height != _bottomHeight) setState(() => _bottomHeight = height);
    });
    // Held sideways, the strip goes beside the video.
    final sideways = MediaQuery.sizeOf(context).aspectRatio > 1;
    final insets = MediaQuery.paddingOf(context);

    Widget large = _Tile(
      tile: main,
      framed: false,
      labelBottom: (_shown ? _bottomHeight : insets.bottom) + 6,
      onPin: (_) => _toggle(),
      onZoom: main.screen ? (_) => _zoomAt(_doubleTapAt) : null,
      onDoubleTapDown: main.screen ? (at) => _doubleTapAt = at : null,
    );
    if (grid) {
      large = Padding(
        padding: EdgeInsets.fromLTRB(8 + insets.left, insets.top + 72, 8 + insets.right, _bottomHeight + 8),
        child: _Grid(tiles: people, onPin: (_) => _wake()),
      );
    } else if (main.screen) {
      large = InteractiveViewer(transformationController: _zoom, minScale: 1, maxScale: 5, child: large);
    }
    // What floats over the video: touched, it stays a while longer.
    Widget floating(Widget child) => Hideable(
      hidden: !_shown,
      child: Listener(onPointerDown: (_) => _wake(), child: child),
    );
    Widget stripOf(Axis axis) => ListView(
      key: const Key('phone-call-strip'),
      scrollDirection: axis,
      padding: const EdgeInsets.all(2),
      children: [
        for (final tile in strip)
          Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(width: 136, height: 90, child: _Tile(tile: tile, onPin: _pin)),
          ),
      ],
    );
    final top = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
          child: Row(
            children: [
              if (!widget.locked)
                IconButton(
                  key: const Key('phone-call-minimize'),
                  tooltip: 'Back to the chats',
                  color: Colors.white,
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => ref.read(callViewMinimizedProvider.notifier).set(true),
                )
              else
                const SizedBox(width: 12),
              Icon(
                view.room.encrypted ? Icons.lock : Icons.lock_open,
                size: 16,
                color: view.room.encrypted ? context.palette.online : context.palette.railIcon,
                semanticLabel: view.room.encrypted ? 'Encrypted' : 'Not encrypted yet',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                    if (status != null)
                      Text(status, style: TextStyle(color: context.palette.railIcon, fontSize: 13))
                    else
                      CallClock(since: call.answeredAt ?? call.startedAt, fontSize: 13),
                    if (unheard)
                      Text(
                        "Someone's audio can't be heard",
                        style: TextStyle(color: context.palette.warning, fontSize: 13),
                      ),
                  ],
                ),
              ),
              if (_phone && main.video != null)
                IconButton(
                  key: const Key('phone-call-full-screen'),
                  tooltip: fullScreen ? 'Leave full screen' : 'Full screen',
                  color: Colors.white,
                  icon: Icon(fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
                  onPressed: () => ref.read(phoneCallFullScreenProvider.notifier).set(!fullScreen),
                ),
            ],
          ),
        ),
      ),
    );
    final bottom = DecoratedBox(
      key: _bottom,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            if (!sideways && strip.isNotEmpty && !fullScreen) SizedBox(height: 98, child: stripOf(Axis.horizontal)),
            _StageControls(view: view, full: false, fillable: false),
            if (widget.locked)
              TextButton(
                key: const Key('phone-call-unlock'),
                onPressed: () => unawaited(ref.read(callWindowProvider).unlock()),
                child: Text('Unlock to open ${context.appName}', style: TextStyle(color: context.palette.railIcon)),
              ),
          ],
        ),
      ),
    );
    return MouseRegion(
      // A mouse (narrow windows): moving it brings the controls back.
      onHover: (_) => _wake(),
      child: Material(
        key: const Key('phone-call-view'),
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: large),
            // Oneself, small, above the controls while they show.
            if (self.video != null && main.key != self.key && !fullScreen)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                right: 12 + insets.right,
                bottom: (_shown ? _bottomHeight : insets.bottom) + 12,
                width: 96,
                height: 128,
                child: _Tile(tile: self, onPin: _pin),
              ),
            Positioned(top: 0, left: 0, right: 0, child: floating(top)),
            if (sideways && strip.isNotEmpty && !fullScreen)
              Positioned(
                top: insets.top + 64,
                right: insets.right,
                bottom: _bottomHeight,
                width: 148,
                child: floating(stripOf(Axis.vertical)),
              ),
            Positioned(left: 0, right: 0, bottom: 0, child: floating(bottom)),
          ],
        ),
      ),
    );
  }
}

/// Shares a screen: one picked here, where the system lists them (X11,
/// Windows, macOS), or else what the system's own picker gives.
Future<void> pickAndShareScreen(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(callControllerProvider.notifier);
  final sources = await controller.screenSources();
  if (sources.isEmpty) return controller.shareScreen(null);
  if (!context.mounted) return;
  final chosen = await showDialog<ScreenSource>(
    context: context,
    builder: (_) => ScreenPicker(sources: sources),
  );
  if (chosen != null) await controller.shareScreen(chosen);
}

/// What to share: screens and windows, with pictures of them.
class ScreenPicker extends StatelessWidget {
  const ScreenPicker({super.key, required this.sources});

  final List<ScreenSource> sources;

  @override
  Widget build(BuildContext context) {
    final screens = [for (final s in sources) if (!s.window) s];
    final windows = [for (final s in sources) if (s.window) s];
    Widget section(String title, List<ScreenSource> list) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: context.palette.textSecondary)),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final source in list) _SourceTile(source: source)],
        ),
      ],
    );
    return AlertDialog(
      key: const Key('screen-picker'),
      title: const Text('Share your screen'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (screens.isNotEmpty) section('Screens', screens),
              if (windows.isNotEmpty) section('Windows', windows),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source});

  final ScreenSource source;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('screen-source-${source.id}'),
    borderRadius: BorderRadius.circular(10),
    onTap: () => Navigator.pop(context, source),
    child: SizedBox(
      width: 168,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: context.palette.rail,
                child: ValueListenableBuilder(
                  valueListenable: source.thumbnail,
                  builder: (_, picture, _) => picture == null
                      ? Icon(source.window ? Icons.web_asset : Icons.desktop_windows, color: context.palette.railIcon)
                      : Image.memory(picture, fit: BoxFit.contain, gaplessPlayback: true),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}

/// The call's video, in its chat above the messages: everyone in a grid, or
/// the one picked large with the others beside it; and what to do. Its
/// height can be dragged, and it can fill the window ([full], shown by
/// `CallOverlay` then). Nothing while the call has no video and wasn't
/// opened (see [callShown]), or is another chat's.
class CallStage extends ConsumerStatefulWidget {
  const CallStage({super.key, required this.conversationId, this.full = false});

  final String conversationId;
  final bool full;

  @override
  ConsumerState<CallStage> createState() => _CallStageState();
}

class _CallStageState extends ConsumerState<CallStage> {
  static const _minHeight = 160.0;

  /// The height in the chat, once dragged.
  double? _height;

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(callControllerProvider);
    final full = ref.watch(callStageFullProvider);
    if (!view.phase.inCall || view.conv != widget.conversationId || !callShown(view, ref) || full != widget.full) {
      return const SizedBox.shrink();
    }
    // Narrow (phones): the call's own view shows its video (PhoneCallView).
    if (!widget.full && narrowCallLayout(context, ref)) return const SizedBox.shrink();
    final pinned = ref.read(callPinnedProvider.notifier);
    final body = _StageBody(
      view: view,
      full: widget.full,
      pinned: ref.watch(callPinnedProvider),
      onPin: pinned.toggle,
      // A double click, or a tile's own button: full screen with it large,
      // or out of full screen.
      onFullScreen: ref.watch(windowControlsProvider) == null || ref.watch(callOnPhoneProvider)
          ? null
          : (key) {
              final fullScreen = ref.read(callFullScreenProvider);
              if (!fullScreen) pinned.set(key);
              ref.read(callFullScreenProvider.notifier).set(!fullScreen);
            },
    );
    if (widget.full) return body;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = MediaQuery.sizeOf(context).height;
        final height = (_height ?? room * 0.42).clamp(_minHeight, max(_minHeight, room * 0.7)).toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(key: const Key('call-stage'), height: height, child: body),
            // Dragged for more video, or more chat.
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                key: const Key('call-stage-resize'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) => setState(() => _height = height + details.delta.dy),
                child: Container(
                  height: 10,
                  color: context.palette.rail,
                  alignment: Alignment.center,
                  child: Container(
                    width: 36,
                    height: 3,
                    decoration: BoxDecoration(color: context.palette.railIcon, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One person's or one screen's place on the stage.
class _TileData {
  const _TileData({
    required this.key,
    required this.label,
    required this.user,
    this.video,
    this.screen = false,
    this.mirror = false,
    this.speaking = false,
    this.muted = false,
    this.deafened = false,
    this.peer,
    this.sound,
    this.unwatched = false,
    this.other,
  });

  final Object key;
  final String label;
  final String user;
  final CallVideo? video;
  final bool screen;
  final bool mirror;
  final bool speaking;
  final bool muted;
  final bool deafened;

  /// Whose shared screen it is, and whether its sound plays here (null: it
  /// has none, or isn't watched).
  final CallPeer? peer;
  final bool? sound;

  /// Their shared screen isn't watched here: none of it comes until it is.
  final bool unwatched;

  /// Someone else's (their user): how loud they play here can be set.
  final String? other;
}

/// Who and what there is to see in a call: the shared screens, the people
/// (this device's user first) with their cameras, or their avatars, and this
/// device's own shared screen as it goes out ([mine]: large only when
/// picked, as it may show itself). Not [named], the others go without names
/// and pictures, and without volumes (whose menu has them).
({List<_TileData> screens, List<_TileData> people, _TileData? mine}) _tilesOf(
  CallView view,
  WidgetRef ref, {
  bool named = true,
}) {
  final me = ref.watch(chatRepositoryProvider).me;
  final profiles = ref.watch(profilesProvider).value ?? const {};
  String nameOf(String user) => !named ? '' : profiles[user]?.displayName ?? UserId.fallbackName(user, me: me);
  String avatarOf(String user) => named ? user : '';

  final screens = <_TileData>[];
  final people = <_TileData>[
    _TileData(
      key: 'me',
      label: 'You',
      user: me,
      video: view.room.camera,
      mirror: true,
      speaking: view.room.speaking,
      muted: view.muted,
      deafened: view.deafened,
    ),
  ];
  final byUser = <String, List<CallPeer>>{};
  for (final peer in view.room.peers) {
    byUser.putIfAbsent(peer.user, () => []).add(peer);
    if (peer.screen != null || peer.unwatchedScreen) {
      screens.add(
        _TileData(
          key: 'screen ${peer.user}/${peer.device}',
          label: named ? "${nameOf(peer.user)}'s screen" : 'A shared screen',
          user: avatarOf(peer.user),
          video: peer.screen,
          screen: true,
          peer: peer,
          sound: peer.screenSound && !peer.unwatchedScreen ? !peer.screenSoundOff : null,
          unwatched: peer.unwatchedScreen,
          other: named ? peer.user : null,
        ),
      );
    }
  }
  for (final MapEntry(key: user, value: devices) in byUser.entries) {
    final cameras = [for (final d in devices) if (d.camera != null) d];
    if (cameras.isEmpty) {
      people.add(
        _TileData(
          key: user,
          label: nameOf(user),
          user: avatarOf(user),
          speaking: devices.any((d) => d.speaking),
          muted: devices.every((d) => d.muted),
          deafened: devices.every((d) => d.deafened),
          other: named ? user : null,
        ),
      );
    }
    for (final d in cameras) {
      people.add(
        _TileData(
          key: '$user/${d.device}',
          label: nameOf(user),
          user: avatarOf(user),
          video: d.camera,
          speaking: d.speaking,
          muted: d.muted,
          deafened: d.deafened,
          other: named ? user : null,
        ),
      );
    }
  }
  final ownScreen = view.room.ownScreen;
  final mine = ownScreen == null
      ? null
      : _TileData(key: 'my-screen', label: 'Your screen', user: me, video: ownScreen, screen: true);
  return (screens: screens, people: people, mine: mine);
}

class _StageBody extends ConsumerWidget {
  const _StageBody({
    required this.view,
    required this.full,
    required this.pinned,
    required this.onPin,
    required this.onFullScreen,
  });

  final CallView view;
  final bool full;
  final Object? pinned;
  final void Function(Object key) onPin;
  final void Function(Object key)? onFullScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:screens, :people, :mine) = _tilesOf(view, ref);
    final tiles = [...screens, ...people, ?mine];
    // Large only once picked (a shared screen too): else everyone in a grid.
    final main = tiles.where((t) => t.key == pinned).firstOrNull;
    if (full) {
      return _ImmersiveStage(view: view, tiles: tiles, main: main, onPin: onPin, onFullScreen: onFullScreen);
    }
    return Material(
      color: context.palette.rail,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: main == null
                  ? _Grid(tiles: tiles, onPin: onPin, onFullScreen: onFullScreen)
                  : _MainAndStrip(
                      main: main,
                      others: [for (final t in tiles) if (t.key != main.key) t],
                      onPin: onPin,
                      onFullScreen: onFullScreen,
                    ),
            ),
          ),
          _StageControls(view: view, full: full),
        ],
      ),
    );
  }
}

/// The stage over the whole window, filled or full screen: the large video
/// takes all of it, and the rest floats over it. That fades out, the pointer
/// too, after a few seconds without the pointer moving, and comes back with
/// any movement; never while the pointer is on it, or a menu of it is open.
class _ImmersiveStage extends ConsumerStatefulWidget {
  const _ImmersiveStage({
    required this.view,
    required this.tiles,
    required this.main,
    required this.onPin,
    required this.onFullScreen,
  });

  final CallView view;
  final List<_TileData> tiles;
  final _TileData? main;
  final void Function(Object key) onPin;
  final void Function(Object key)? onFullScreen;

  /// How long the pointer stays still before the controls go.
  static const idle = Duration(seconds: 3);

  @override
  ConsumerState<_ImmersiveStage> createState() => _ImmersiveStageState();
}

class _ImmersiveStageState extends ConsumerState<_ImmersiveStage> {
  var _shown = true;
  var _onControls = false;
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    callChromeHolds.addListener(_wake);
    _wake();
  }

  @override
  void dispose() {
    _idle?.cancel();
    callChromeHolds.removeListener(_wake);
    super.dispose();
  }

  void _wake() {
    _idle?.cancel();
    if (!_shown) setState(() => _shown = true);
    _idle = Timer(_ImmersiveStage.idle, () {
      if (!mounted || _onControls || callChromeHolds.value > 0) return;
      setState(() => _shown = false);
    });
  }

  Widget _controls(Widget child) => Hideable(
    hidden: !_shown,
    child: MouseRegion(
      onEnter: (_) => _onControls = true,
      onExit: (_) {
        _onControls = false;
        _wake();
      },
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final main = widget.main;
    final others = [for (final t in widget.tiles) if (t.key != main?.key) t];
    return MouseRegion(
      cursor: _shown ? MouseCursor.defer : SystemMouseCursors.none,
      onHover: (_) => _wake(),
      child: Listener(
        onPointerDown: (_) => _wake(),
        child: Material(
          key: const Key('call-stage-immersive'),
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 640;
              final strip = ListView(
                key: const Key('call-stage-strip'),
                scrollDirection: wide ? Axis.vertical : Axis.horizontal,
                padding: const EdgeInsets.all(8),
                children: [
                  for (final tile in others)
                    Padding(
                      padding: EdgeInsets.only(bottom: wide ? 8 : 0, right: wide ? 0 : 8),
                      child: SizedBox(
                        width: wide ? null : 160,
                        height: wide ? 108 : null,
                        child: _Tile(tile: tile, onPin: widget.onPin, onFullScreen: widget.onFullScreen),
                      ),
                    ),
                ],
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (main == null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 64),
                      child: _Grid(tiles: widget.tiles, onPin: widget.onPin, onFullScreen: widget.onFullScreen),
                    )
                  else
                    _Tile(
                      tile: main,
                      onPin: widget.onPin,
                      onFullScreen: widget.onFullScreen,
                      framed: false,
                      labelBottom: _shown ? 70 : 6,
                      // Clear of the strip beside it.
                      buttonsRight: _shown && wide && others.isNotEmpty ? 214 : 6,
                    ),
                  if (main != null && others.isNotEmpty)
                    wide
                        ? Positioned(top: 8, right: 0, bottom: 64, width: 208, child: _controls(strip))
                        : Positioned(left: 0, right: 0, bottom: 64, height: 106, child: _controls(strip)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _controls(
                      DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black54],
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _StageControls(view: widget.view, full: true),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Everyone, as big as fits: tiles of 16:9.
class _Grid extends StatelessWidget {
  const _Grid({required this.tiles, required this.onPin, this.onFullScreen});

  final List<_TileData> tiles;
  final void Function(Object key) onPin;
  final void Function(Object key)? onFullScreen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final count = tiles.length;
      // The column count that makes the tiles biggest.
      var best = (columns: 1, width: 0.0);
      for (var columns = 1; columns <= count; columns++) {
        final rows = (count / columns).ceil();
        final width = min(constraints.maxWidth / columns - 8, (constraints.maxHeight / rows - 8) * 16 / 9);
        if (width > best.width) best = (columns: columns, width: width);
      }
      final width = max(best.width, 40.0);
      return Center(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: width,
                height: width * 9 / 16,
                child: _Tile(tile: tile, onPin: onPin, onFullScreen: onFullScreen),
              ),
          ],
        ),
      );
    },
  );
}

/// One tile large, the others in a strip beside it (below, when narrow).
class _MainAndStrip extends StatelessWidget {
  const _MainAndStrip({required this.main, required this.others, required this.onPin, this.onFullScreen});

  final _TileData main;
  final List<_TileData> others;
  final void Function(Object key) onPin;
  final void Function(Object key)? onFullScreen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 640;
      final strip = ListView(
        scrollDirection: wide ? Axis.vertical : Axis.horizontal,
        children: [
          for (final tile in others)
            Padding(
              padding: EdgeInsets.only(bottom: wide ? 8 : 0, right: wide ? 0 : 8),
              child: SizedBox(
                width: wide ? null : 160,
                height: wide ? 108 : null,
                child: _Tile(tile: tile, onPin: onPin, onFullScreen: onFullScreen),
              ),
            ),
        ],
      );
      final big = _Tile(tile: main, onPin: onPin, onFullScreen: onFullScreen);
      if (others.isEmpty) return big;
      return wide
          ? Row(
              children: [
                Expanded(child: big),
                const SizedBox(width: 8),
                SizedBox(width: 192, child: strip),
              ],
            )
          : Column(
              children: [
                Expanded(child: big),
                const SizedBox(height: 8),
                SizedBox(height: 90, child: strip),
              ],
            );
    },
  );
}

/// One person's camera (or picture), or a shared screen. A click makes it
/// the large one ([onPin]). Where there is full screen ([onFullScreen],
/// desktops), a double click, or its button under the pointer, goes full
/// screen with it large, or back. Someone else's sets how loud they play
/// here: its button under the pointer, a right click or a long press. Not
/// [framed]: it fills the stage, edge to edge.
class _Tile extends ConsumerStatefulWidget {
  const _Tile({
    required this.tile,
    required this.onPin,
    this.onFullScreen,
    this.onZoom,
    this.onDoubleTapDown,
    this.framed = true,
    this.labelBottom = 6,
    this.buttonsRight = 6,
  });

  final _TileData tile;
  final void Function(Object key) onPin;
  final void Function(Object key)? onFullScreen;

  /// A double tap zooms it, where it was ([onDoubleTapDown] tells where).
  final void Function(Object key)? onZoom;
  final void Function(Offset at)? onDoubleTapDown;
  final bool framed;

  /// How high its name sits, and how far from the right its buttons at the
  /// top: clear of what floats over it, while that shows.
  final double labelBottom;
  final double buttonsRight;

  @override
  ConsumerState<_Tile> createState() => _TileState();
}

class _TileState extends ConsumerState<_Tile> {
  var _pointed = false;

  _TileData get tile => widget.tile;

  /// How loud they play here, set in a menu [at] a place on the screen: the
  /// stage's controls stay meanwhile.
  Future<void> _volume(Offset at) async {
    final other = tile.other;
    if (other == null) return;
    callChromeHolds.value++;
    try {
      await showVolumes(context, at: at, users: [other]);
    } finally {
      callChromeHolds.value--;
    }
  }

  @override
  Widget build(BuildContext context) {
    final onFullScreen = widget.onFullScreen;
    final fullScreen = ref.watch(callFullScreenProvider);
    final sound = tile.sound;
    final other = tile.other;
    // Someone else's shared screen, watched (only theirs have a peer).
    final watched = tile.peer != null && !tile.unwatched;
    Widget button(String key, String tooltip, IconData icon, Color color, VoidCallback onPressed) => Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: IconButton(
        key: ValueKey(key),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: color,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _pointed = true),
      onExit: (_) => setState(() => _pointed = false),
      child: Container(
        decoration: BoxDecoration(
          color: context.palette.callTile,
          borderRadius: widget.framed ? BorderRadius.circular(10) : null,
          border: widget.framed
              ? Border.all(color: tile.speaking ? context.palette.online : Colors.transparent, width: 2.5)
              : null,
        ),
        clipBehavior: widget.framed ? Clip.antiAlias : Clip.none,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Its buttons are beside this, not in it: a double click waits
            // on every tap in it.
            GestureDetector(
              key: ValueKey('call-tile-${tile.key}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onPin(tile.key),
              onDoubleTapDown: switch (widget.onDoubleTapDown) {
                final told? => (details) => told(details.localPosition),
                null => null,
              },
              onDoubleTap: switch ((onFullScreen, widget.onZoom)) {
                (final onFullScreen?, _) => () => onFullScreen(tile.key),
                (_, final onZoom?) => () => onZoom(tile.key),
                _ => null,
              },
              onSecondaryTapUp: other == null ? null : (details) => unawaited(_volume(details.globalPosition)),
              onLongPressStart: other == null ? null : (details) => unawaited(_volume(details.globalPosition)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (tile.video case final video?)
                    video.view(fit: tile.screen ? BoxFit.contain : BoxFit.cover, mirror: tile.mirror)
                  else if (!tile.unwatched)
                    Center(
                      child: LayoutBuilder(
                        builder: (context, c) =>
                            Avatar(id: tile.user, label: tile.label, size: min(72, c.maxHeight * 0.5)),
                      ),
                    ),
                  if (tile.label.isNotEmpty || (tile.muted || tile.deafened) && !tile.screen)
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200),
                      left: 6,
                      bottom: widget.labelBottom,
                      right: 6,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (tile.deafened && !tile.screen) ...[
                                Icon(
                                  Icons.headset_off,
                                  key: ValueKey('call-tile-deafened-${tile.key}'),
                                  size: 13,
                                  color: context.palette.failed,
                                  semanticLabel: 'Deafened',
                                ),
                                const SizedBox(width: 3),
                              ],
                              if (tile.muted && !tile.screen) ...[
                                Icon(Icons.mic_off, size: 13, color: context.palette.failed, semanticLabel: 'Muted'),
                                const SizedBox(width: 3),
                              ],
                              if (tile.label.isNotEmpty)
                                Flexible(
                                  child: Text(
                                    tile.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Someone's shared screen, not watched here: none of it comes
            // until it is. Watched, it shows large on the stage.
            if (tile.unwatched)
              Center(
                child: FilledButton.icon(
                  key: ValueKey('call-watch-${tile.key}'),
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () {
                    ref.read(callPinnedProvider.notifier).set(tile.key);
                    unawaited(ref.read(callControllerProvider.notifier).toggleWatching(tile.peer!));
                  },
                  icon: const Icon(Icons.visibility, size: 18),
                  label: const Text('Watch'),
                ),
              ),
            // How loud they play here, under the pointer; a shared screen's
            // sound, to play here or not; and watching it no more.
            if (sound != null || watched || other != null && _pointed)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                top: 6,
                right: widget.buttonsRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    if (other != null && _pointed)
                      Builder(
                        builder: (context) => button(
                          'call-tile-volume-${tile.key}',
                          'Volume',
                          Icons.tune,
                          Colors.white,
                          () => unawaited(_volume(below(context))),
                        ),
                      ),
                    if (sound != null)
                      button(
                        'call-screen-sound-${tile.key}',
                        sound ? 'Mute its sound here' : 'Play its sound',
                        sound ? Icons.volume_up : Icons.volume_off,
                        sound ? Colors.white : context.palette.failed,
                        () => unawaited(ref.read(callControllerProvider.notifier).toggleScreenSound(tile.peer!)),
                      ),
                    if (watched)
                      button(
                        'call-stop-watching-${tile.key}',
                        'Stop watching',
                        Icons.visibility_off,
                        Colors.white,
                        () => unawaited(ref.read(callControllerProvider.notifier).toggleWatching(tile.peer!)),
                      ),
                  ],
                ),
              ),
            // Full screen with it large, under the pointer (the large one over
            // the whole window has the controls' own).
            if (onFullScreen != null && _pointed && widget.framed && tile.video != null)
              Positioned(
                right: 6,
                bottom: 6,
                child: button(
                  'call-tile-full-screen-${tile.key}',
                  fullScreen ? 'Leave full screen' : 'Full screen',
                  fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  Colors.white,
                  () => onFullScreen(tile.key),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// While this device shares its screen: its sound on or off and whose it is
/// (every app's, or one's); where it has none but could have, dimmed, why.
class _ShareSound extends ConsumerWidget {
  const _ShareSound({required this.view});

  final CallView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sound = view.shareSound;
    final missing = view.room.shareSoundMissing;
    if (sound == null) {
      if (missing == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Tooltip(
          key: const Key('call-share-sound-missing'),
          message: missing,
          triggerMode: TooltipTriggerMode.tap,
          child: const CircleAvatar(
            radius: 20,
            backgroundColor: Colors.white12,
            child: Icon(Icons.volume_off, size: 20, color: Colors.white38),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: sound ? Colors.white12 : context.palette.failed.withValues(alpha: 0.85),
        shape: const StadiumBorder(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const Key('call-share-sound'),
              tooltip: sound ? "Turn the screen's sound off" : "Share the screen's sound",
              color: Colors.white,
              icon: Icon(sound ? Icons.volume_up : Icons.volume_off, size: 20),
              onPressed: () => unawaited(ref.read(callControllerProvider.notifier).toggleShareSound()),
            ),
            if (sound) _SoundFrom(from: view.shareSoundFrom),
          ],
        ),
      ),
    );
  }
}

/// Whose sound the shared screen has: every app's, or one app's, picked
/// from those playing now.
class _SoundFrom extends ConsumerWidget {
  const _SoundFrom({required this.from});

  final SoundApp? from;

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(callControllerProvider.notifier);
    final menus = Navigator.of(context).overlay!;
    final apps = await controller.soundApps();
    if (!context.mounted || !menus.mounted) return;
    final button = context.findRenderObject()! as RenderBox;
    final overlay = menus.context.findRenderObject()! as RenderBox;
    final place = Rect.fromPoints(
      button.localToGlobal(button.size.bottomLeft(Offset.zero), ancestor: overlay),
      button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    PopupMenuItem<(SoundApp?,)> item(SoundApp? app) => PopupMenuItem(
      key: ValueKey('call-sound-from-${app?.id ?? 'all'}'),
      value: (app,),
      child: Row(
        children: [
          SizedBox(width: 28, child: app == from ? const Icon(Icons.check, size: 18) : null),
          Flexible(child: Text(app?.name ?? 'All apps', maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
    callChromeHolds.value++;
    final (SoundApp?,)? picked;
    try {
      picked = await showMenu<(SoundApp?,)>(
        context: context,
        position: RelativeRect.fromRect(place, Offset.zero & overlay.size),
        items: [
          item(null),
          if (apps.isNotEmpty || from != null) const PopupMenuDivider(),
          for (final app in {...apps, ?from}) item(app),
        ],
      );
    } finally {
      callChromeHolds.value--;
    }
    if (picked != null) await controller.shareSoundFrom(picked.$1);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    key: const Key('call-sound-from'),
    style: TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
    onPressed: () => unawaited(_pick(context, ref)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(from?.name ?? 'All apps', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const Icon(Icons.arrow_drop_down, size: 18),
      ],
    ),
  );
}

/// Mute, camera, share, deafen, speaker (phones), fill the window, hang up.
class _StageControls extends ConsumerWidget {
  const _StageControls({required this.view, required this.full, this.fillable = true});

  final CallView view;
  final bool full;

  /// Offers to fill the window (not where it fills the screen already).
  final bool fillable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(callControllerProvider.notifier);
    final phone = ref.watch(callOnPhoneProvider);
    final fullScreen = ref.watch(callFullScreenProvider);
    Widget button(
      String key,
      String label,
      IconData icon,
      VoidCallback? onPressed, {
      bool off = false,
      bool on = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: IconButton.filledTonal(
        key: Key(key),
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: off
              ? context.palette.failed.withValues(alpha: 0.85)
              : on
              ? context.palette.online.withValues(alpha: 0.85)
              : context.palette.onRail.withAlpha(0x1F),
          foregroundColor: context.palette.onRail,
        ),
        icon: Icon(icon, size: 20),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (pushToTalkOn(ref))
            HoldToTalk(
              muted: view.muted,
              builder: (context, held) => button(
                'stage-talk',
                'Hold to talk',
                Icons.record_voice_over,
                // Held, not tapped: the pointer does it.
                view.muted ? null : () {},
                on: held,
              ),
            ),
          button(
            'stage-mute',
            view.muted ? 'Unmute' : 'Mute',
            view.muted ? Icons.mic_off : Icons.mic,
            () => unawaited(controller.toggleMute()),
            off: view.muted,
          ),
          button(
            'stage-camera',
            view.camera ? 'Turn camera off' : 'Turn camera on',
            view.camera ? Icons.videocam : Icons.videocam_off,
            () => unawaited(controller.toggleCamera()),
            off: !view.camera,
          ),
          if (phone && view.camera)
            button('stage-flip', 'Switch camera', Icons.cameraswitch, () => unawaited(controller.switchCamera())),
          // Not iPhones yet (a broadcast extension of their own).
          if (!Platform.isIOS)
            button(
              'stage-share',
              view.sharing ? 'Stop sharing' : 'Share your screen',
              view.sharing ? Icons.stop_screen_share : Icons.screen_share,
              () => view.sharing
                  ? unawaited(controller.stopSharing())
                  : unawaited(pickAndShareScreen(context, ref)),
              on: view.sharing,
            ),
          if (view.sharing) _ShareSound(view: view),
          button(
            'stage-deafen',
            view.deafened ? 'Undeafen' : 'Deafen',
            view.deafened ? Icons.headset_off : Icons.headset,
            () => unawaited(controller.toggleDeafen()),
            off: view.deafened,
          ),
          if (phone)
            button(
              'stage-speaker',
              view.speaker ? 'Earpiece' : 'Speaker',
              view.speaker ? Icons.volume_up : Icons.phone_in_talk,
              () => unawaited(controller.toggleSpeaker()),
            ),
          // Opened with nothing to see: closed again.
          if (fillable && !full && !callHasVideo(view))
            button(
              'stage-hide',
              'Hide the call',
              Icons.keyboard_arrow_up,
              () => ref.read(callViewOpenProvider.notifier).set(false),
            ),
          if (fillable && !fullScreen)
            button(
              'stage-full',
              full ? 'Back to the chat' : 'Fill the window',
              full ? Icons.close_fullscreen : Icons.open_in_full,
              () => ref.read(callStageFullProvider.notifier).set(!full),
            ),
          if (fillable && !phone && ref.watch(windowControlsProvider) != null)
            button(
              'stage-full-screen',
              fullScreen ? 'Leave full screen (F11)' : 'Full screen (F11)',
              fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
              () => ref.read(callFullScreenProvider.notifier).set(!fullScreen),
            ),
          const SizedBox(width: 6),
          IconButton.filled(
            key: const Key('stage-hang-up'),
            tooltip: 'Hang up',
            style: IconButton.styleFrom(backgroundColor: context.palette.failed, foregroundColor: Colors.white),
            onPressed: () => unawaited(controller.hangUp()),
            icon: const Icon(Icons.call_end, size: 20),
          ),
        ],
      ),
    );
  }
}

/// The stage over the whole window: with a navigator of its own, for
/// tooltips and the screen picker. Esc, or the system's back, goes out of
/// full screen, else back to the chat; F11 (or F) in and out of full screen.
class FullCallStage extends ConsumerWidget {
  const FullCallStage({super.key, this.backButtonDispatcher});

  final BackButtonDispatcher? backButtonDispatcher;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conv = ref.watch(callControllerProvider.select((v) => v.conv));
    if (!ref.watch(callStageFullProvider) || conv == null) return const SizedBox.shrink();
    void back() => ref.read(callFullScreenProvider)
        ? ref.read(callFullScreenProvider.notifier).set(false)
        : ref.read(callStageFullProvider.notifier).set(false);
    void fullScreen() {
      if (ref.read(windowControlsProvider) == null) return;
      ref.read(callFullScreenProvider.notifier).set(!ref.read(callFullScreenProvider));
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): back,
        const SingleActivator(LogicalKeyboardKey.f11): fullScreen,
        const SingleActivator(LogicalKeyboardKey.keyF): fullScreen,
      },
      child: Focus(
        autofocus: true,
        child: _CallNavigator(
          key: const ValueKey('full-call-stage'),
          backButtonDispatcher: backButtonDispatcher,
          onBack: back,
          child: SafeArea(child: CallStage(conversationId: conv, full: true)),
        ),
      ),
    );
  }
}
