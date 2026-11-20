import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../diagnostics/app_log.dart';
import '../media/save_media.dart';
import '../theme/hanashi_theme.dart';

/// Shows the app's log (see [AppLog]) to read, copy or save for a bug report.
Future<void> showLog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const LogDialog());

/// What each level is called where the user picks one.
String logLevelName(LogLevel level) => switch (level) {
  LogLevel.error => 'Errors only',
  LogLevel.warning => 'Problems only',
  LogLevel.info => 'Normal',
  LogLevel.debug => 'Detailed',
};

class LogDialog extends StatefulWidget {
  const LogDialog({super.key});

  /// The newest lines shown; copying and saving take all of it.
  static const shownLines = 3000;

  @override
  State<LogDialog> createState() => _LogDialogState();
}

class _LogDialogState extends State<LogDialog> {
  late Future<String> _text = AppLog.instance.read();

  /// What the last copy or save did.
  String? _status;

  void _reload() => setState(() {
    _text = AppLog.instance.read();
  });

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: await _text));
    setState(() => _status = 'Copied');
  }

  Future<void> _save() async {
    final now = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    try {
      final saved = await saveBytes(utf8.encode(await _text), 'hanashi-log-$now.txt', mime: 'text/plain');
      if (saved != null && mounted) setState(() => _status = 'Saved to $saved');
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not save the log: $e');
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the log?'),
        content: const Text('What it holds now is gone, also for a bug report.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('log-clear-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppLog.instance.clear();
    _status = null;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('log-dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 900),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text('Log', style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(
                    key: const Key('log-refresh'),
                    tooltip: 'Refresh',
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    key: const Key('log-copy'),
                    tooltip: 'Copy all',
                    onPressed: _copy,
                    icon: const Icon(Icons.copy),
                  ),
                  IconButton(
                    key: const Key('log-save'),
                    tooltip: 'Save to a file',
                    onPressed: _save,
                    icon: const Icon(Icons.download),
                  ),
                  IconButton(
                    key: const Key('log-clear'),
                    tooltip: 'Clear',
                    onPressed: _clear,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                _status ??
                    'Level: ${logLevelName(AppLog.instance.level)}. Holds IDs of your contacts, chats and devices, '
                        'never messages or keys.',
                key: const Key('log-status'),
                style: TextStyle(color: context.palette.textSecondary, fontSize: 13),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<String>(
                future: _text,
                builder: (context, snapshot) {
                  final text = snapshot.data;
                  if (text == null) return const Center(child: CircularProgressIndicator());
                  if (text.trim().isEmpty) return const Center(child: Text('Nothing logged yet'));
                  final all = text.trimRight().split('\n');
                  final lines = all.length > LogDialog.shownLines
                      ? all.sublist(all.length - LogDialog.shownLines)
                      : all;
                  // Newest at the bottom, where the list starts.
                  return SelectionArea(
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: lines.length,
                      itemBuilder: (context, i) => _LogLine(lines[lines.length - 1 - i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine(this.line);

  final String line;

  @override
  Widget build(BuildContext context) {
    // "2026-10-27 14:03:22.123 W tag: ..."; stack trace lines have no level.
    final level = line.length > 25 && line[25] == ' ' ? line[24] : null;
    return Text(
      line,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.35,
        color: switch (level) {
          'E' => context.palette.failed,
          'W' => context.palette.logWarning,
          'D' => context.palette.textSecondary,
          _ => null,
        },
      ),
    );
  }
}
