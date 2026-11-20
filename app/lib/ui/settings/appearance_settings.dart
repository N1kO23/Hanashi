import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/packs/content_package.dart';
import '../../data/themes/app_theme.dart';
import '../../data/themes/theme_library.dart';
import '../../launcher/theme_launcher.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/picked_file.dart';

/// A theme file the user picks; null if they picked none.
Future<String?> pickThemeFile() async {
  final file = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['zip'])).firstOrNull;
  return file == null ? null : localPathOf(file);
}

/// How this device shows the app: light, dark or as the system is, and in
/// which theme. Themes come as files; the built-in ones always stay.
class AppearanceSettings extends ConsumerStatefulWidget {
  const AppearanceSettings({super.key, this.pickFile = pickThemeFile});

  /// A theme file to add; null if the user picked none.
  final Future<String?> Function() pickFile;

  @override
  ConsumerState<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends ConsumerState<AppearanceSettings> {
  var _importing = false;

  /// Whether the home screen takes the theme's shortcut (see [ThemeLauncher]).
  late final Future<bool> _canPin = ref.read(themeLauncherProvider).supported();

  Future<void> _pin() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await ref.read(themeLauncherProvider).pin(ref.read(activeThemeProvider))) {
        _say(messenger, 'Your home screen takes no shortcuts');
      }
    } on PlatformException catch (e) {
      _say(messenger, 'Could not add it: ${e.message ?? e.code}');
    }
  }

  void _say(ScaffoldMessengerState messenger, String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await widget.pickFile();
    if (path == null || !mounted) return;
    setState(() => _importing = true);
    try {
      final themes = ref.read(themesProvider.notifier);
      AppTheme theme;
      try {
        theme = await themes.import(path);
      } on ThemeInstalled catch (e) {
        // Not busy while asking.
        setState(() => _importing = false);
        if (!mounted || !await _confirmReplace(e.title) || !mounted) return;
        setState(() => _importing = true);
        theme = await themes.import(path, replace: true);
      }
      _say(messenger, 'Added the theme ${theme.title}');
    } on PackageException catch (e) {
      _say(messenger, e.message);
    } on FileSystemException catch (e) {
      _say(messenger, 'Could not read the file: ${e.message}');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<bool> _confirmReplace(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const Key('replace-theme'),
          title: Text('Replace "$title"?'),
          content: const Text('This file is a version of a theme you have.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Replace')),
          ],
        ),
      ) ??
      false;

  Future<void> _remove(AppTheme theme) async {
    final messenger = ScaffoldMessenger.of(context);
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('remove-theme'),
        title: Text('Remove "${theme.title}"?'),
        content: const Text('It goes from this device. You can add it again from its file.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: dialog.palette.failed),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await ref.read(themesProvider.notifier).remove(theme.id);
    } on FileSystemException catch (e) {
      _say(messenger, 'Could not remove the theme: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final mode = ref.watch(appearanceProvider.select((appearance) => appearance.mode));
    final active = ref.watch(activeThemeProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedButton<ThemeMode>(
            key: const Key('appearance-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {mode},
            onSelectionChanged: (chosen) => unawaited(ref.read(appearanceProvider.notifier).setMode(chosen.single)),
          ),
        ),
        for (final theme in ref.watch(themesProvider))
          ListTile(
            key: ValueKey('theme-${theme.id}'),
            leading: _ThemeSwatch(dark ? theme.dark : theme.light),
            title: Text(theme.title),
            subtitle: Text(
              [
                if (theme.origin == ThemeOrigin.builtIn) 'Built in',
                ?theme.author,
                if (theme.origin == ThemeOrigin.imported && theme.author == null) 'From a file',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (theme.id == active.id) Icon(Icons.check, color: palette.replyAccent, semanticLabel: 'In use'),
                if (theme.origin != ThemeOrigin.builtIn)
                  PopupMenuButton<VoidCallback>(
                    key: ValueKey('theme-menu-${theme.id}'),
                    tooltip: 'Theme',
                    icon: Icon(Icons.more_vert, color: palette.textSecondary),
                    // Once the menu has gone.
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        key: ValueKey('theme-remove-${theme.id}'),
                        value: () => unawaited(_remove(theme)),
                        child: const Text('Remove theme…'),
                      ),
                    ],
                  ),
              ],
            ),
            onTap: () => unawaited(ref.read(appearanceProvider.notifier).setTheme(theme.id)),
          ),
        ListTile(
          key: const Key('import-theme'),
          enabled: !_importing,
          // As wide as the swatches, for the titles to line up.
          leading: SizedBox(width: 40, child: Icon(Icons.file_open_outlined, color: palette.textSecondary)),
          title: const Text('Import theme file…'),
          subtitle: const Text('Colours for light and dark, and its own pictures and sounds'),
          trailing: _importing
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          onTap: _import,
        ),
        FutureBuilder<bool>(
          future: _canPin,
          builder: (context, canPin) => canPin.data != true
              ? const SizedBox.shrink()
              : ListTile(
                  key: const Key('pin-theme'),
                  leading: SizedBox(width: 40, child: Icon(Icons.add_to_home_screen, color: palette.textSecondary)),
                  title: const Text('Add to home screen'),
                  subtitle: Text('${active.shownName}, with this theme\'s icon; it follows the theme you choose'),
                  onTap: _pin,
                ),
        ),
      ],
    );
  }
}

/// A theme's colours in small: its header over its chat, with a bubble of
/// each side.
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch(this.palette);

  final HanashiPalette palette;

  @override
  Widget build(BuildContext context) {
    Widget bubble(Color color, Alignment side) => Align(
      alignment: side,
      child: Container(
        width: 18,
        height: 7,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3.5)),
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: 40,
        height: 40,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: palette.chatBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.palette.divider),
        ),
        child: Column(
          children: [
            Container(height: 12, color: palette.header),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    bubble(palette.incomingBubble, Alignment.centerLeft),
                    bubble(palette.outgoingBubble, Alignment.centerRight),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
