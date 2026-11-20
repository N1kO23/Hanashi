import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/remote/api_client.dart';
import '../../data/remote/klipy.dart';
import '../../state/providers.dart';
import '../media/gif_view.dart';
import '../theme/hanashi_theme.dart';
import 'expression_panel.dart';

/// GIFs: sent as messages of their own.
final gifTab = ExpressionTab(
  id: 'gif',
  icon: Icons.gif_box_outlined,
  label: 'GIFs',
  build: (context, target, height) => GifPicker(height: height, onGif: target.onGif!),
);

/// Saves [gif] to the user's GIFs or, with [saved] false, removes it, and
/// says so.
Future<void> setGifSaved(BuildContext context, WidgetRef ref, GifRef gif, bool saved) async {
  final messenger = ScaffoldMessenger.of(context);
  final repository = ref.read(chatRepositoryProvider);
  try {
    await repository.setGifSaved(gif, saved);
    messenger.showSnackBar(
      SnackBar(
        content: Text(saved ? 'Saved to your GIFs' : 'Removed from your GIFs'),
        action: saved
            ? null
            : SnackBarAction(label: 'Undo', onPressed: () => unawaited(repository.setGifSaved(gif, true))),
      ),
    );
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not change your saved GIFs: $e')));
  }
}

/// The user's saved GIFs, then trending GIFs or search results from KLIPY
/// (when the server has a KLIPY key). Tapping a GIF sends it; a long press
/// or right click saves it, or removes a saved one.
class GifPicker extends ConsumerStatefulWidget {
  const GifPicker({super.key, required this.height, required this.onGif});

  final double height;
  final ValueChanged<GifRef> onGif;

  @override
  ConsumerState<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends ConsumerState<GifPicker> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  /// What the results are for: trending when empty.
  var _shown = '';
  final _results = <GifResult>[];
  var _page = 0;
  var _hasNext = true;
  var _loading = false;
  String? _error;

  /// Changes with [_shown]: answers to an earlier search are dropped.
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300) _loadMore();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _search(String query, {Duration delay = const Duration(milliseconds: 400)}) {
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      if (!mounted || query.trim() == _shown) return;
      setState(() {
        _shown = query.trim();
        _results.clear();
        _page = 0;
        _hasNext = true;
        _loading = false;
        _error = null;
        _generation++;
      });
      _loadMore();
    });
  }

  Future<void> _loadMore() async {
    final search = ref.read(gifSearchProvider).value;
    if (search == null || _loading || !_hasNext || _error != null) return;
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final page = _shown.isEmpty ? await search.trending(page: _page + 1) : await search.search(_shown, page: _page + 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results.addAll(page.items);
        _page++;
        _hasNext = page.hasNext && page.items.isNotEmpty;
      });
    } on GifSearchException catch (e) {
      if (mounted && generation == _generation) setState(() => _error = e.message);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _toggleSaved(GifRef gif, List<GifRef> saved) =>
      setGifSaved(context, ref, gif, !saved.any((g) => g.key == gif.key));

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(gifSearchProvider);
    final saved = ref.watch(savedGifsProvider).value ?? const <GifRef>[];
    // The first page, once there is a search to ask.
    if (search.value != null && _page == 0 && !_loading && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMore();
      });
    }

    Widget tile(GifRef gif, {RemoteMedia? preview, required Key key}) => _GifTile(
      key: key,
      gif: gif,
      preview: preview,
      onTap: () => widget.onGif(gif),
      onLongPress: () => _toggleSaved(gif, saved),
    );

    return SizedBox(
      key: const Key('gif-picker'),
      height: widget.height,
      child: Column(
        children: [
          if (search.value != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: TextField(
                key: const Key('gif-search'),
                controller: _query,
                textInputAction: TextInputAction.search,
                // KLIPY asks for this wording.
                decoration: InputDecoration(
                  hintText: 'Search KLIPY',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _query.clear();
                            _search('', delay: Duration.zero);
                          },
                        ),
                ),
                onChanged: (text) {
                  setState(() {}); // The clear button.
                  _search(text);
                },
                onSubmitted: (text) => _search(text, delay: Duration.zero),
              ),
            ),
          Expanded(
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                if (_shown.isEmpty && saved.isNotEmpty) ...[
                  const _Header('Saved'),
                  _Grid([for (final gif in saved) tile(gif, key: ValueKey('saved-gif-${gif.key}'))]),
                ],
                ...switch (search) {
                  AsyncData(value: null) => [
                    _Note(
                      saved.isEmpty
                          ? 'Save GIFs from chats: long-press one and choose "Save GIF". '
                                'GIF search is not set up on this server.'
                          : 'GIF search is not set up on this server.',
                    ),
                  ],
                  AsyncError() => [
                    _Note('Cannot reach the server.', onRetry: () => ref.invalidate(gifSearchProvider)),
                  ],
                  AsyncData() => [
                    if (_shown.isEmpty) const _Header('Trending on KLIPY'),
                    _Grid([
                      for (final result in _results)
                        tile(GifRef.remote(result.full), preview: result.preview, key: ValueKey('gif-${result.full.id}')),
                    ]),
                    if (_loading) const _Spinner(),
                    if (_error != null)
                      _Note(
                        _error!,
                        onRetry: () {
                          setState(() => _error = null);
                          _loadMore();
                        },
                      ),
                    if (!_loading && _error == null && _page > 0 && _results.isEmpty) const _Note('No GIFs found.'),
                  ],
                  _ => [const _Spinner()],
                },
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GifTile extends StatelessWidget {
  const _GifTile({super.key, required this.gif, this.preview, required this.onTap, required this.onLongPress});

  final GifRef gif;

  /// A smaller version to show (in search results).
  final RemoteMedia? preview;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) => Material(
    color: context.palette.listSelected,
    borderRadius: BorderRadius.circular(6),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: preview != null ? RemoteImage(media: preview!) : GifView(gif: gif),
    ),
  );
}

class _Grid extends StatelessWidget {
  const _Grid(this.tiles);

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      delegate: SliverChildListDelegate(tiles),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        title,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.palette.textSecondary),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: context.palette.textMuted),
          ),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
    ),
  );
}
