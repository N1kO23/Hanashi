import 'dart:async';
import 'dart:typed_data';

/// What was decrypted lately, kept in memory, so that it is not decrypted
/// again (a picture shown again, scrolling back up a chat, say) and comes
/// back as the very same bytes: Flutter's image cache knows a picture by
/// them, so it is not decoded again either. At most [maxBytes] in all, the
/// oldest going first; one larger than a quarter of that is not kept. Two
/// asking for the same at once share one decryption.
class DecryptedCache {
  DecryptedCache({required this.maxBytes});

  final int maxBytes;

  /// By ID, the newest last.
  final _kept = <String, Uint8List>{};
  var _size = 0;
  final _pending = <String, Future<Uint8List>>{};

  /// What [id] decrypted to, if it is kept.
  Uint8List? peek(String id) {
    final kept = _kept.remove(id);
    if (kept != null) _kept[id] = kept; // The newest now.
    return kept;
  }

  /// What [id] decrypts to: kept, or from [decrypt].
  Future<Uint8List> get(String id, Future<Uint8List> Function() decrypt) {
    final kept = peek(id);
    if (kept != null) return Future.value(kept);
    return _pending.putIfAbsent(id, () async {
      try {
        final plain = await decrypt();
        _keep(id, plain);
        return plain;
      } finally {
        // Forgotten a turn after it is done: never before it is stored, even
        // if it fails at once. (A block body: `remove` returns this very
        // future, which an arrow would hand on, failure and all, to nobody.)
        unawaited(
          Future(() {
            _pending.remove(id);
          }),
        );
      }
    });
  }

  /// Forgets what [which] IDs decrypted to.
  void forget(bool Function(String id) which) {
    for (final id in [..._kept.keys.where(which)]) {
      _size -= _kept.remove(id)!.length;
    }
  }

  void _keep(String id, Uint8List plain) {
    if (plain.length > maxBytes ~/ 4) return;
    _kept[id] = plain;
    _size += plain.length;
    while (_size > maxBytes) {
      _size -= _kept.remove(_kept.keys.first)!.length;
    }
  }
}
