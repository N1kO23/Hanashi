import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'padding.dart';
import 'primitives.dart';

/// Chunked AES-256-GCM for files, so large videos never sit in memory whole.
///
/// Layout: magic "MTF2" ‖ 7-byte nonce prefix, then chunks of at most
/// [chunkSize] plaintext bytes, each `ciphertext ‖ 16-byte tag`. A chunk's
/// nonce is prefix ‖ 32-bit counter ‖ last-chunk flag, and the header is the
/// associated data, so reordered, truncated or extended files fail to decrypt.
///
/// The plaintext is the file, a 0x80 byte and zero bytes up to its [padme]
/// length, so the server sees only roughly how large a file is.
abstract final class FileCipher {
  static const chunkSize = 64 * 1024;
  static const _tag = 16;
  static final _magic = Uint8List.fromList('MTF2'.codeUnits);
  static const _headerLength = 4 + 7;

  /// Encrypts [input] into [output] with [key] (32 bytes), off the UI isolate.
  /// The padding stops short of making it larger than [maxSize] bytes.
  static Future<void> encrypt(String input, String output, Uint8List key, {int? maxSize}) =>
      Isolate.run(() => _encrypt(input, output, key, maxSize));

  /// Throws [DecryptionFailed] if the file was tampered with or the key is wrong.
  static Future<void> decrypt(String input, String output, Uint8List key) =>
      Isolate.run(() => _decrypt(input, output, key));

  /// [input] decrypted into memory, off the UI isolate: for pictures and other
  /// small files. Throws as [decrypt] does.
  static Future<Uint8List> decryptBytes(String input, Uint8List key) => Isolate.run(() async {
    final plain = BytesBuilder(copy: false);
    final length = await _decryptAll(input, key, plain.add);
    return Uint8List.sublistView(plain.takeBytes(), 0, length);
  });

  /// How large the encrypted file of [length] plaintext bytes (padding
  /// included) is.
  static int encryptedSize(int length) => _headerLength + length + _tag * max(1, (length + chunkSize - 1) ~/ chunkSize);

  /// The plaintext length, padding included, of a file of [length] bytes.
  static int paddedLength(int length, {int? maxSize}) {
    var padded = padme(length + 1);
    if (maxSize != null && encryptedSize(padded) > maxSize) {
      padded = maxSize - _headerLength - _tag * ((maxSize + chunkSize - 1) ~/ chunkSize);
    }
    return max(padded, length + 1);
  }

  static Uint8List _nonce(List<int> prefix, int counter, bool last) => Uint8List.fromList([
    ...prefix,
    (counter >> 24) & 0xff,
    (counter >> 16) & 0xff,
    (counter >> 8) & 0xff,
    counter & 0xff,
    last ? 1 : 0,
  ]);

  static Future<void> _encrypt(String input, String output, Uint8List key, int? maxSize) async {
    final aes = AesGcm.with256bits();
    final secretKey = SecretKey(key);
    final prefix = randomBytes(7);
    final header = Uint8List.fromList([..._magic, ...prefix]);
    final source = File(input).openSync();
    final sink = File(output).openSync(mode: FileMode.write);
    try {
      sink.writeFromSync(header);
      final length = source.lengthSync();
      final total = paddedLength(length, maxSize: maxSize);
      var offset = 0, counter = 0;
      do {
        final chunk = Uint8List(min(chunkSize, total - offset));
        final data = max(0, min(chunk.length, length - offset));
        for (var read = 0; read < data;) {
          final n = source.readIntoSync(chunk, read, data);
          if (n == 0) throw FileSystemException('The file got shorter', input);
          read += n;
        }
        if (data < chunk.length && offset + data == length) chunk[data] = 0x80;
        offset += chunk.length;
        final last = offset >= total;
        final box = await aes.encrypt(chunk, secretKey: secretKey, nonce: _nonce(prefix, counter++, last), aad: header);
        sink.writeFromSync(box.cipherText);
        sink.writeFromSync(box.mac.bytes);
        if (last) break;
      } while (true);
    } finally {
      source.closeSync();
      sink.closeSync();
    }
  }

  static Future<void> _decrypt(String input, String output, Uint8List key) async {
    final sink = File(output).openSync(mode: FileMode.write);
    try {
      sink.truncateSync(await _decryptAll(input, key, sink.writeFromSync));
    } finally {
      sink.closeSync();
    }
  }

  /// Decrypts [input]'s chunks in order into [write], padding and all;
  /// returns the length without the padding.
  static Future<int> _decryptAll(String input, Uint8List key, void Function(List<int> plain) write) async {
    final aes = AesGcm.with256bits();
    final secretKey = SecretKey(key);
    final source = File(input).openSync();
    try {
      final total = source.lengthSync();
      final header = source.readSync(_headerLength);
      if (header.length != _headerLength || !_startsWith(header, _magic)) {
        throw const DecryptionFailed('Not an encrypted Hanashi file');
      }
      final prefix = header.sublist(4);
      var offset = _headerLength, counter = 0, written = 0;
      // Where the padding starts: the last byte that is not zero.
      var end = -1, endByte = 0;
      do {
        final chunk = source.readSync(chunkSize + _tag);
        if (chunk.length < _tag) throw const DecryptionFailed('The file is truncated');
        offset += chunk.length;
        final last = offset >= total;
        final List<int> plain;
        try {
          plain = await aes.decrypt(
            SecretBox(
              chunk.sublist(0, chunk.length - _tag),
              nonce: _nonce(prefix, counter++, last),
              mac: Mac(chunk.sublist(chunk.length - _tag)),
            ),
            secretKey: secretKey,
            aad: header,
          );
        } on SecretBoxAuthenticationError {
          throw const DecryptionFailed('The file was damaged or tampered with');
        }
        write(plain);
        for (var i = plain.length - 1; i >= 0; i--) {
          if (plain[i] != 0) {
            (end, endByte) = (written + i, plain[i]);
            break;
          }
        }
        written += plain.length;
        if (last) break;
      } while (true);
      if (endByte != 0x80) throw const DecryptionFailed('The file was damaged or tampered with');
      return end;
    } finally {
      source.closeSync();
    }
  }

  static bool _startsWith(List<int> header, List<int> magic) {
    for (var i = 0; i < magic.length; i++) {
      if (header[i] != magic[i]) return false;
    }
    return true;
  }
}

/// Parts of a file [FileCipher] encrypted, decrypted as they are asked for:
/// the chunks a range needs, each on its own (for a player that seeks, say),
/// so the file is never decrypted whole.
class FileCipherReader {
  FileCipherReader._(this._source, this._key, this._header, this._chunks, this._lastSealed);

  final RandomAccessFile _source;
  final SecretKey _key;
  final Uint8List _header;
  final int _chunks;

  /// The last chunk's length, its tag included.
  final int _lastSealed;

  /// The plaintext's length, without its padding.
  late final int length;

  final _aes = AesGcm.with256bits();
  ({int index, List<int> plain})? _recent;

  /// Opens [path], finding where its padding starts. Throws
  /// [DecryptionFailed] as [FileCipher.decrypt] does.
  static Future<FileCipherReader> open(String path, Uint8List key) async {
    final source = File(path).openSync();
    try {
      final header = source.readSync(FileCipher._headerLength);
      if (header.length != FileCipher._headerLength || !FileCipher._startsWith(header, FileCipher._magic)) {
        throw const DecryptionFailed('Not an encrypted Hanashi file');
      }
      const sealed = FileCipher.chunkSize + FileCipher._tag;
      final body = source.lengthSync() - FileCipher._headerLength;
      final chunks = max(1, (body + sealed - 1) ~/ sealed);
      final lastSealed = body - (chunks - 1) * sealed;
      if (lastSealed < FileCipher._tag) throw const DecryptionFailed('The file is truncated');
      final reader = FileCipherReader._(source, SecretKey(key), header, chunks, lastSealed);
      // The padding is a 0x80 byte and zeros, which may fill whole chunks.
      for (var index = chunks - 1; index >= 0; index--) {
        final plain = await reader._chunk(index);
        for (var i = plain.length - 1; i >= 0; i--) {
          if (plain[i] == 0) continue;
          if (plain[i] != 0x80) throw const DecryptionFailed('The file was damaged or tampered with');
          return reader..length = index * FileCipher.chunkSize + i;
        }
      }
      throw const DecryptionFailed('The file was damaged or tampered with');
    } catch (_) {
      source.closeSync();
      rethrow;
    }
  }

  /// Bytes [start] up to [end] of the plaintext.
  Stream<List<int>> read(int start, int end) async* {
    end = min(end, length);
    start = max(0, start);
    if (start >= end) return;
    for (var index = start ~/ FileCipher.chunkSize; index * FileCipher.chunkSize < end; index++) {
      final plain = await _chunk(index);
      final from = max(0, start - index * FileCipher.chunkSize);
      final to = min(plain.length, end - index * FileCipher.chunkSize);
      yield plain.sublist(from, to);
    }
  }

  Future<List<int>> _chunk(int index) async {
    final recent = _recent;
    if (recent != null && recent.index == index) return recent.plain;
    final last = index == _chunks - 1;
    // Read at once, with nothing awaited between: requests of their own may
    // move the position in the meantime.
    _source.setPositionSync(FileCipher._headerLength + index * (FileCipher.chunkSize + FileCipher._tag));
    final sealed = _source.readSync(last ? _lastSealed : FileCipher.chunkSize + FileCipher._tag);
    if (sealed.length < FileCipher._tag) throw const DecryptionFailed('The file is truncated');
    final List<int> plain;
    try {
      plain = await _aes.decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - FileCipher._tag),
          nonce: FileCipher._nonce(_header.sublist(4), index, last),
          mac: Mac(sealed.sublist(sealed.length - FileCipher._tag)),
        ),
        secretKey: _key,
        aad: _header,
      );
    } on SecretBoxAuthenticationError {
      throw const DecryptionFailed('The file was damaged or tampered with');
    }
    _recent = (index: index, plain: plain);
    return plain;
  }

  void close() => _source.closeSync();
}
