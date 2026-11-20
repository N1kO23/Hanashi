import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _random = Random.secure();
final _ulidPattern = RegExp(r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$');

/// Generates a ULID: 48-bit millisecond timestamp + 80 random bits, encoded as
/// 26 Crockford base32 characters. Used as client-generated message IDs.
String newUlid({DateTime? now}) {
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final chars = List.filled(26, '0');
  for (var i = 9; i >= 0; i--) {
    chars[i] = _alphabet[ms % 32];
    ms ~/= 32;
  }
  for (var i = 10; i < 26; i++) {
    chars[i] = _alphabet[_random.nextInt(32)];
  }
  return chars.join();
}

/// A ULID made of [ms] and [sequence] instead of random bits, for local
/// records derived from server events: deriving one again gives the same ID.
String ulidFor(int ms, int sequence) {
  final chars = List.filled(26, '0');
  for (var i = 9; i >= 0; i--) {
    chars[i] = _alphabet[ms % 32];
    ms ~/= 32;
  }
  for (var i = 25; i >= 10 && sequence > 0; i--) {
    chars[i] = _alphabet[sequence % 32];
    sequence ~/= 32;
  }
  return chars.join();
}

bool isUlid(String value) => _ulidPattern.hasMatch(value);
