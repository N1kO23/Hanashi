import 'dart:typed_data';

import 'content_package.dart';

/// [bytes], the sound of a package's [file]: WAV, Ogg or MP3, by its first
/// bytes, and the one [file]'s extension (`.wav`, `.ogg`, `.mp3`) says. Its
/// type (`audio/wav`, `audio/ogg`, `audio/mpeg`); [what] names it in the
/// [PackageException] thrown otherwise.
String checkSound(Uint8List bytes, {required String file, required String what}) {
  final (mime, extension) = switch (_soundType(bytes)) {
    'wav' => ('audio/wav', 'wav'),
    'ogg' => ('audio/ogg', 'ogg'),
    'mp3' => ('audio/mpeg', 'mp3'),
    _ => (null, null),
  };
  if (mime == null || !file.endsWith('.$extension')) throw PackageException('$what is not the sound its file says');
  return mime;
}

String? _soundType(Uint8List bytes) {
  bool at(int offset, String text) =>
      bytes.length >= offset + text.length && String.fromCharCodes(bytes.sublist(offset, offset + text.length)) == text;
  if (at(0, 'RIFF') && at(8, 'WAVE')) return 'wav';
  if (at(0, 'OggS')) return 'ogg';
  // An ID3 tag, or straight away an MPEG frame's sync bits.
  if (at(0, 'ID3') || (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)) return 'mp3';
  return null;
}
