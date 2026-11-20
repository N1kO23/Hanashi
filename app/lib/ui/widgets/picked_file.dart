import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// A path to [file], which the user picked: some platforms hand out content
/// URIs instead of paths, and those are copied to a temporary file.
Future<String> localPathOf(PlatformFile file) async {
  final path = file.path;
  if (path != null) return path;
  final dir = await Directory('${Directory.systemTemp.path}/hanashi-picked').create(recursive: true);
  final copy = '${dir.path}/${DateTime.now().microsecondsSinceEpoch}-${file.name}';
  await file.xFile.saveTo(copy);
  return copy;
}
