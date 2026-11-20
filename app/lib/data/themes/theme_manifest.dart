import '../../ui/theme/hanashi_theme.dart';

/// What a theme file holds: its `pack.json` (see `docs/themes.md`).
///
/// ```json
/// {"format": 1, "type": "theme", "id": "dusk", "title": "Dusk", "author"?: "…", "version"?: 1,
///  "light"?: {"header": "#FB94A7", "avatarColors": ["#F7A8B8"]},
///  "dark"?: {"header": "#B8566C"},
///  "assets"?: {"logo": "logo.png", "wordmark": "name.png", "appIcon": "icon.png",
///              "messageSound": "message.ogg", "ringtone": "ring.ogg"}}
/// ```
class ThemeManifest {
  const ThemeManifest({
    required this.id,
    required this.title,
    this.author,
    this.appName,
    this.version,
    this.light,
    this.dark,
    this.assets = const {},
  });

  /// What a theme's manifest says it is (`"type"`).
  static const type = 'theme';

  /// The newest format this version reads (`"format"`).
  static const format = 1;

  /// A theme's ID: lower case, as it names a folder and part of a URI.
  static final idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  /// IDs of the app's own themes, which a file cannot take.
  static const reservedIds = {'default'};

  /// What a theme can bring besides colours: pictures, and sounds.
  static const imageRoles = {'logo', 'wordmark', 'appIcon'};

  /// Pictures the system draws (in the tray, on notifications), not the app:
  /// PNG only, which every one of them reads.
  static const pngRoles = {'appIcon'};
  static const soundRoles = {'messageSound', 'ringtone'};

  static final _imageFile = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.(png|webp)$');
  static final _pngFile = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.png$');
  static final _soundFile = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.(wav|ogg|mp3)$');

  final String id;
  final String title;
  final String? author;

  /// The name the app goes by while the theme shows: in its title bar, its
  /// window, its tray and its notifications, and on a phone's home screen
  /// (see `ThemeLauncher`). Short, as launchers cut longer ones.
  final String? appName;
  final int? version;

  /// The longest [appName].
  static const maxAppName = 32;

  /// The theme's palettes, over the app's built-in ones of the same
  /// brightness; at least one of them is set.
  final HanashiPalette? light;
  final HanashiPalette? dark;

  /// The files of what it brings, by role ([imageRoles], [soundRoles]).
  final Map<String, String> assets;

  /// Throws a [FormatException] whose message can be shown to the user.
  factory ThemeManifest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) throw const FormatException('This is not a theme');
    final given = json['format'];
    if (given is! int || given < 1) throw const FormatException('This theme is damaged');
    if (given > format) throw const FormatException('This theme needs a newer version of Hanashi');
    final id = json['id'];
    if (id is! String || !idPattern.hasMatch(id)) {
      throw const FormatException('This theme has no valid ID (lower-case letters, digits, ".", "_" and "-")');
    }
    if (reservedIds.contains(id)) throw FormatException('A theme cannot be called "$id"');
    final title = _text(json['title']);
    if (title == null) throw const FormatException('This theme has no title');
    HanashiPalette? variant(String name, HanashiPalette base) {
      final colors = json[name];
      if (colors == null) return null;
      if (colors is! Map) throw FormatException('"$name" of this theme must be its colours');
      try {
        return HanashiPalette.fromJson(colors.cast<String, Object?>(), base: base);
      } on FormatException catch (e) {
        throw FormatException('${e.message} (in "$name")');
      }
    }

    final light = variant('light', HanashiPalette.light);
    final dark = variant('dark', HanashiPalette.dark);
    if (light == null && dark == null) throw const FormatException('This theme has neither "light" nor "dark" colours');
    final assets = <String, String>{};
    final listed = json['assets'];
    if (listed != null) {
      if (listed is! Map) throw const FormatException('"assets" of this theme must name its files');
      for (final MapEntry(:key, :value) in listed.entries) {
        final images = imageRoles.contains(key);
        // Later versions' roles are left alone.
        if (!images && !soundRoles.contains(key)) continue;
        final png = pngRoles.contains(key);
        final pattern = png ? _pngFile : (images ? _imageFile : _soundFile);
        if (value is! String || !pattern.hasMatch(value)) {
          throw FormatException(switch ((png, images)) {
            (true, _) => '"$key" of this theme must be a .png file, in no folder',
            (_, true) => '"$key" of this theme must be a .png or .webp file, in no folder',
            _ => '"$key" of this theme must be a .wav, .ogg or .mp3 file, in no folder',
          });
        }
        assets[key as String] = value;
      }
    }
    final version = json['version'];
    return ThemeManifest(
      id: id,
      title: title,
      author: _text(json['author']),
      appName: _text(json['appName'], max: maxAppName),
      version: version is int && version >= 0 ? version : null,
      light: light,
      dark: dark,
      assets: assets,
    );
  }

  static String? _text(Object? value, {int max = 64}) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty || text.length > max ? null : text;
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'type': type,
    'id': id,
    'title': title,
    'author': ?author,
    'appName': ?appName,
    'version': ?version,
    'light': ?light?.toJson(),
    'dark': ?dark?.toJson(),
    if (assets.isNotEmpty) 'assets': assets,
  };
}
