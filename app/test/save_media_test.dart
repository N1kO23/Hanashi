import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/ui/media/save_media.dart';

void main() {
  test('sender-chosen names cannot escape the downloads folder', () {
    expect(safeFileName('../../.bashrc'), '.._.._.bashrc');
    expect(safeFileName(r'C:\Windows\evil.exe'), 'C__Windows_evil.exe');
    expect(safeFileName('..'), 'file');
    expect(safeFileName('  '), 'file');
    expect(safeFileName('report.pdf'), 'report.pdf');
  });

  test('existing files are not overwritten', () {
    final dir = Directory.systemTemp.createTempSync('hanashi_save_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/notes.txt').writeAsStringSync('abc');
    expect(uniqueFileName(dir, 'notes.txt', 3), 'notes.txt'); // Same size: reuse.
    expect(uniqueFileName(dir, 'notes.txt', 10), 'notes (2).txt');
    expect(uniqueFileName(dir, 'README', 10), 'README');
  });
}
