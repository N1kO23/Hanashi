/// A web address in a message's text.
class TextLink {
  const TextLink(this.start, this.end, this.address);

  /// Where it is in the text (UTF-16 code units, [end] exclusive).
  final int start;
  final int end;

  /// What it opens: as written, with `https://` before one that starts with
  /// `www.`.
  final String address;

  Uri get uri => Uri.parse(address);

  @override
  bool operator ==(Object other) =>
      other is TextLink && other.start == start && other.end == end && other.address == address;

  @override
  int get hashCode => Object.hash(start, end, address);

  @override
  String toString() => 'TextLink($start, $end, $address)';
}

/// `http://`, `https://` or `www.`, not inside a word, an email address or
/// another address; up to the next space (or `<`, `>`, `"`).
final _candidate = RegExp(r'''(?<![\w@/.\-])(?:https?://|www\.)[^\s<>"]+''', caseSensitive: false);

/// Punctuation that ends a sentence rather than an address.
const _trailing = '.,:;!?\'*_~…。、，！？';
const _closing = {')': '(', ']': '[', '}': '{'};

/// The web addresses in [text], in order.
Iterable<TextLink> findLinks(String text) sync* {
  for (final match in _candidate.allMatches(text)) {
    var end = match.end;
    // "(see https://example.com/a_(b))." keeps its own brackets, not the
    // sentence's.
    while (end > match.start) {
      final last = text[end - 1];
      final open = _closing[last];
      if (_trailing.contains(last) ||
          (open != null && _count(text, open, match.start, end) < _count(text, last, match.start, end))) {
        end--;
      } else {
        break;
      }
    }
    final written = text.substring(match.start, end);
    final address = written.toLowerCase().startsWith('www.') ? 'https://$written' : written;
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) continue;
    yield TextLink(match.start, end, address);
  }
}

int _count(String text, String char, int start, int end) {
  var n = 0;
  for (var i = start; i < end; i++) {
    if (text[i] == char) n++;
  }
  return n;
}
