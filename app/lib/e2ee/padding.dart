import 'dart:convert';
import 'dart:typed_data';

/// [json] (UTF-8 JSON) with spaces after it, which JSON allows, so that its
/// length shows only roughly once encrypted: at least 256 bytes, the next
/// power of two up to 4 KiB, and the next multiple of 4 KiB above that; but
/// not past [max].
Uint8List padJson(List<int> json, {int? max}) {
  final length = json.length;
  var padded = length <= 256
      ? 256
      : length <= 4096
      ? 1 << (length - 1).bitLength
      : (length + 4095) & ~4095;
  if (max != null && padded > max) padded = length > max ? length : max;
  return Uint8List(padded)
    ..setRange(0, length, json)
    ..fillRange(length, padded, 0x20);
}

/// [value] as JSON, padded (see [padJson]).
Uint8List encodePaddedJson(Object? value, {int? max}) => padJson(utf8.encode(jsonEncode(value)), max: max);

/// Padmé (Nikitin et al., "Reducing Metadata Leakage from Encrypted Files and
/// Communication with PURBs", 2019): [length] rounded up so that only about
/// log log [length] bits of it show, adding at most 12%.
int padme(int length) {
  if (length < 2) return length;
  final e = length.bitLength - 1; // floor(log2 length)
  final s = e.bitLength; // floor(log2 e) + 1
  final mask = (1 << (e - s)) - 1;
  return (length + mask) & ~mask;
}
