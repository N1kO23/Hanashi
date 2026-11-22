import 'dart:io';
import 'dart:isolate';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../data/attachments.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/format.dart';

/// A file on this device, ready to send.
typedef LocalFile = ({String path, String name});

/// Files come from other apps by drag and drop or the clipboard on desktops.
bool get filesFromOtherApps => switch (defaultTargetPlatform) {
  TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => !kIsWeb,
  _ => false,
};

/// Files dragged from other apps onto [child] go to [onFiles]; while they
/// are over it, [label] says what dropping does. Folders and links (from a
/// browser) are left out.
class FileDropTarget extends StatefulWidget {
  const FileDropTarget({
    super.key,
    required this.label,
    required this.onFiles,
    this.enabled = true,
    required this.child,
  });

  final String label;
  final Future<void> Function(List<LocalFile> files) onFiles;
  final bool enabled;
  final Widget child;

  @override
  State<FileDropTarget> createState() => _FileDropTargetState();
}

class _FileDropTargetState extends State<FileDropTarget> {
  var _over = false;

  Future<void> _dropped(DropDoneDetails details) async {
    setState(() => _over = false);
    final files = <LocalFile>[];
    var skipped = 0;
    for (final item in details.files) {
      if (item is DropItemDirectory || FileSystemEntity.typeSync(item.path) != FileSystemEntityType.file) {
        skipped++;
      } else {
        files.add((path: item.path, name: item.name));
      }
    }
    if (skipped > 0 && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Only files can be sent, not folders or links')));
    }
    if (files.isEmpty) return;
    // A sandboxed app (macOS) may read dropped files only while it says so.
    final bookmarks = [
      for (final item in details.files)
        if (item.extraAppleBookmark case final bookmark? when bookmark.isNotEmpty) bookmark,
    ];
    for (final bookmark in bookmarks) {
      await DesktopDrop.instance.startAccessingSecurityScopedResource(bookmark: bookmark);
    }
    try {
      await widget.onFiles(files);
    } finally {
      for (final bookmark in bookmarks) {
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(bookmark: bookmark);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!filesFromOtherApps) return widget.child;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: _dropped,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  key: const Key('file-drop-overlay'),
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: context.palette.replyPanel.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.palette.replyAccent, width: 2),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.upload_file, size: 48, color: context.palette.replyAccent),
                        const SizedBox(height: 12),
                        Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, color: context.palette.textHeading),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What the clipboard holds to send: files (copied in a file manager), or an
/// image, written into [tempDir]. Null when it holds neither, or text as
/// well as an image (as copied spreadsheet cells do): that pastes as text.
/// Throws an [AttachmentException] for an image this device cannot read.
Future<List<LocalFile>?> clipboardFiles(Directory tempDir) async {
  final paths = await _orNull(Pasteboard.files) ?? const [];
  final files = [
    for (final path in paths)
      // Also keeps out web addresses, which macOS hands out as paths.
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file)
        (path: path, name: File(path).uri.pathSegments.last),
  ];
  if (files.isNotEmpty) return files;
  if (await Clipboard.hasStrings()) return null;
  final image = await _orNull(() => Pasteboard.image);
  if (image == null || image.isEmpty) return null;
  return [await _pastedImage(image, tempDir)];
}

Future<T?> _orNull<T>(Future<T?> Function() read) async {
  try {
    return await read();
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Formats a chat shows as images, kept as they are; others (BMP from
/// Windows, TIFF from macOS) become PNG.
const _imageExtensions = {'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp'};

Future<LocalFile> _pastedImage(Uint8List bytes, Directory tempDir) async {
  var extension = _imageExtensions[lookupMimeType('', headerBytes: bytes)];
  var data = bytes;
  if (extension == null) {
    final png = await Isolate.run(() {
      final image = img.decodeImage(bytes);
      return image == null ? null : img.encodePng(image);
    });
    if (png == null) throw const AttachmentException('The clipboard holds an image this device cannot read');
    (data, extension) = (png, 'png');
  }
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final name = 'Pasted image ${formatDay(now)} ${two(now.hour)}.${two(now.minute)}.${two(now.second)}.$extension';
  await tempDir.create(recursive: true);
  final file = await File('${tempDir.path}/$name').writeAsBytes(data);
  return (path: file.path, name: name);
}

/// Asks before sending files that were dropped or pasted: a stray drop or
/// paste must not send anything. Images show as small previews.
Future<bool> confirmSendFiles(BuildContext context, List<LocalFile> files, {required String to}) async {
  final sizes = [for (final f in files) File(f.path).lengthSync()];
  return await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (context) => AlertDialog(
          key: const Key('send-files-dialog'),
          title: Text(files.length == 1 ? 'Send to $to?' : 'Send ${files.length} files to $to?'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [for (final (i, file) in files.indexed) _FileRow(file: file, size: sizes[i])],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              key: const Key('send-files-confirm'),
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send'),
            ),
          ],
        ),
      ) ??
      false;
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.size});

  final LocalFile file;
  final int size;

  @override
  Widget build(BuildContext context) {
    final mime = lookupMimeType(file.name) ?? '';
    Widget icon(IconData icon) => Icon(icon, size: 32, color: context.palette.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 56,
            child: mime.startsWith('image/')
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(
                      File(file.path),
                      fit: BoxFit.cover,
                      cacheWidth: 112,
                      errorBuilder: (_, _, _) => icon(Icons.image_outlined),
                    ),
                  )
                : icon(mime.startsWith('video/') ? Icons.movie_outlined : Icons.insert_drive_file_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(formatBytes(size), style: TextStyle(fontSize: 13, color: context.palette.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
