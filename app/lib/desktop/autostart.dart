import 'dart:io';

/// Starts the app hidden in the tray when the user logs in.
abstract final class Autostart {
  /// The command-line flag for starting without showing the window.
  static const hiddenFlag = '--hidden';

  static bool get supported => Platform.isLinux || Platform.isWindows;

  static Future<bool> isEnabled() async {
    if (Platform.isLinux) return _desktopEntry.exists();
    if (Platform.isWindows) {
      return (await Process.run('reg', ['query', _runKey, '/v', _name])).exitCode == 0;
    }
    return false;
  }

  static Future<void> setEnabled(bool enabled) async {
    // An AppImage runs from a mount that is gone after it exits; start the
    // AppImage itself. Unpacked from the .tar.gz, the launcher beside the app
    // (see packaging/linux/package.sh).
    final exe = Platform.environment['APPIMAGE'] ?? _launcher ?? Platform.resolvedExecutable;
    if (Platform.isLinux) {
      final entry = _desktopEntry;
      if (!enabled) {
        if (await entry.exists()) await entry.delete();
        return;
      }
      await entry.parent.create(recursive: true);
      await entry.writeAsString(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Hanashi\n'
        'Exec=${_quoteExec(exe)} $hiddenFlag\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n',
      );
    } else if (Platform.isWindows) {
      final result = enabled
          ? await Process.run('reg', ['add', _runKey, '/v', _name, '/t', 'REG_SZ', '/d', '"$exe" $hiddenFlag', '/f'])
          : await Process.run('reg', ['delete', _runKey, '/v', _name, '/f']);
      if (result.exitCode != 0 && enabled) {
        throw FileSystemException('Could not change the startup setting: ${result.stderr}');
      }
    }
  }

  static const _name = 'Hanashi';
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static File get _desktopEntry {
    final env = Platform.environment;
    final config = env['XDG_CONFIG_HOME'] ?? '${env['HOME']}/.config';
    return File('$config/autostart/app.nullpointr.hanashi.desktop');
  }

  static String? get _launcher {
    if (!Platform.isLinux) return null;
    final launcher = File('${File(Platform.resolvedExecutable).parent.path}/hanashi');
    return launcher.existsSync() ? launcher.path : null;
  }

  /// Quotes a path for a desktop entry's Exec key (the spec's rules).
  static String _quoteExec(String path) =>
      '"${path.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}')}"';
}
