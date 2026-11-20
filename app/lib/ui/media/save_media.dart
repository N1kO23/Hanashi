import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/providers.dart';

bool get _isDesktop => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Downloads a received file and saves it where the user can find it.
///
/// Files are never opened or run by the app: anyone can send a file with a
/// harmless-looking name. On desktop the file goes to Downloads/Hanashi and
/// the user can reveal the folder; on phones the system save dialog is used.
Future<void> saveMedia(
  BuildContext context,
  WidgetRef ref,
  MediaRef media, {
  void Function(double progress)? onProgress,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await ref.read(chatRepositoryProvider).mediaFile(media, onProgress: onProgress);
    if (file == null) throw const FileSystemException('This file is not available');
    final name = safeFileName(media.name ?? defaultFileName(media));
    if (_isDesktop) {
      final saved = await _saveToDownloads(file, name);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved to ${saved.path}'),
          action: SnackBarAction(
            label: 'Show in folder',
            // Opens the folder in the file manager, never the file itself.
            onPressed: () => OpenFilex.open(saved.parent.path),
          ),
        ),
      );
    } else {
      final uri = await FilePicker.saveFile(fileName: name, bytes: await file.readAsBytes(), mimeType: media.mime);
      if (uri != null) messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not save the file: $e')));
  }
}

/// Saves [bytes] as [name] where the user finds it, as [saveMedia] does.
/// Returns where on desktop, the name on phones, or null if the user
/// cancelled the save dialog.
Future<String?> saveBytes(Uint8List bytes, String name, {required String mime}) async {
  if (_isDesktop) {
    final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/Hanashi');
    await dir.create(recursive: true);
    final target = File('${dir.path}/${uniqueFileName(dir, name, -1)}');
    await target.writeAsBytes(bytes);
    return target.path;
  }
  final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mime);
  return uri == null ? null : name;
}

Future<File> _saveToDownloads(File cached, String name) async {
  final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/Hanashi');
  await dir.create(recursive: true);
  final target = File('${dir.path}/${uniqueFileName(dir, name, await cached.length())}');
  if (!target.existsSync()) await cached.copy(target.path);
  return target;
}

/// Strips path separators and control characters from a sender-chosen name.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty || RegExp(r'^\.+$').hasMatch(cleaned) ? 'file' : cleaned;
}

/// Reuses an existing copy with the same size; otherwise picks "name (2).ext".
String uniqueFileName(Directory dir, String name, int size) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; ; i++) {
    final candidate = i == 1 ? name : '$stem ($i)$ext';
    final file = File('${dir.path}/$candidate');
    if (!file.existsSync() || file.lengthSync() == size) return candidate;
  }
}

String defaultFileName(MediaRef media) {
  final ext = switch (media.mime) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    'video/quicktime' => 'mov',
    _ => 'bin',
  };
  return 'hanashi-${media.hash.substring(7, 15)}.$ext';
}
