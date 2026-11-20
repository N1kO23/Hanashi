#!/usr/bin/env python3
"""Makes a theme file from a folder, or checks one.

    python3 app/tool/make_theme.py <folder> [-o theme.zip]
    python3 app/tool/make_theme.py --check theme.zip

A theme is a zip file of pack.json and the pictures and sounds it names, all
at its top level (see docs/themes.md). <folder> holds the same: pack.json,
and the files its "assets" name. Nothing is converted: the theme is checked
as the app checks one, and its file written only if the app would take it.
People import a theme file in Settings, under Appearance.

A theme's ID names it: the same ID is the same theme, so a new version of a
theme keeps its ID, and importing it replaces the one people have.
"""

import argparse
import io
import json
import pathlib
import re
import sys
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from make_sticker_pack import Refused, picture_info  # noqa: E402

FORMAT = 1
ID = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
RESERVED_IDS = {'default'}
MAX_TEXT = 64
MAX_APP_NAME = 32
MAX_THEME = 8 * 1024 * 1024
MAX_ENTRIES = 32
MAX_MANIFEST = 64 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_IMAGE = 1024 * 1024
MAX_SOUND = 2 * 1024 * 1024
MAX_SIDE = 2048
DATE = (2026, 1, 1, 0, 0, 0)  # Every entry's: the same theme makes the same file.

# The colours a theme sets, as `PaletteSlot` names them (lib/ui/theme/hanashi_theme.dart;
# test/theme_tool_test.dart keeps the two the same).
SLOTS = [
    'header', 'onHeader', 'rail', 'railSelected', 'railIcon', 'onRail', 'listBackground', 'listSelected',
    'divider', 'panelDivider', 'chatBackground', 'surface', 'incomingBubble', 'outgoingBubble', 'onBubble',
    'replyPanel', 'replyAccent', 'onAccent', 'fieldBorder', 'mediaCardBorder', 'textPrimary', 'textHeading',
    'textSecondary', 'textMuted', 'unreadBadge', 'failed', 'success', 'online', 'idle', 'focus', 'offline',
    'profileText', 'profilePill', 'birthday', 'birthdayText', 'warning', 'warningBackground', 'logWarning',
    'shadow', 'callTile',
]
COLOR = re.compile(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$')
IMAGE_ROLES = {'logo', 'wordmark', 'appIcon'}
PNG_ROLES = {'appIcon'}  # The system draws it (tray, notifications): PNG, which all of them read.
SOUND_ROLES = {'messageSound', 'ringtone'}
IMAGE_FILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.(png|webp)$')
PNG_FILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.png$')
SOUND_FILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.(wav|ogg|mp3)$')


def _text(value, most=MAX_TEXT):
    if not isinstance(value, str):
        return None
    text = value.strip()
    return text if 1 <= len(text) <= most else None


def _colors(manifest, variant, notes):
    colors = manifest.get(variant)
    if colors is None:
        return False
    if not isinstance(colors, dict):
        raise Refused(f'"{variant}" must be its colours')
    for name, value in colors.items():
        if name == 'avatarColors':
            if not isinstance(value, list) or not value:
                raise Refused(f'"avatarColors" must list at least one colour (in "{variant}")')
            for i, color in enumerate(value):
                if not isinstance(color, str) or not COLOR.match(color):
                    raise Refused(f'"avatarColors[{i}]" must be a colour, #RRGGBB or #AARRGGBB (in "{variant}")')
        elif name in SLOTS:
            if not isinstance(value, str) or not COLOR.match(value):
                raise Refused(f'"{name}" must be a colour, #RRGGBB or #AARRGGBB (in "{variant}")')
        else:
            notes.append(f'{variant}: "{name}" is no colour this version knows; the app passes over it')
    return True


def check_manifest(manifest, notes):
    """Refuses a pack.json the app would refuse; else its files by role."""
    if not isinstance(manifest, dict) or manifest.get('type') != 'theme':
        raise Refused('this is not a theme ("type" must be "theme")')
    given = manifest.get('format')
    if not isinstance(given, int) or isinstance(given, bool) or given < 1:
        raise Refused('"format" must be 1')
    if given > FORMAT:
        raise Refused(f'it is of format {given}; this version reads {FORMAT}')
    theme_id = manifest.get('id')
    if not isinstance(theme_id, str) or not ID.match(theme_id):
        raise Refused('"id" must be 1 to 64 of a-z, 0-9, ".", "_" and "-", starting with a letter or digit')
    if theme_id in RESERVED_IDS:
        raise Refused(f'a theme cannot be called "{theme_id}"')
    if _text(manifest.get('title')) is None:
        raise Refused(f'"title" must be 1 to {MAX_TEXT} characters')
    if 'author' in manifest and _text(manifest['author']) is None:
        notes.append(f'"author" is not 1 to {MAX_TEXT} characters; the app passes over it')
    if 'appName' in manifest and _text(manifest['appName'], MAX_APP_NAME) is None:
        notes.append(f'"appName" is not 1 to {MAX_APP_NAME} characters; the app passes over it')
    version = manifest.get('version')
    if version is not None and (not isinstance(version, int) or isinstance(version, bool) or version < 0):
        notes.append('"version" is no whole number from 0; the app passes over it')
    light = _colors(manifest, 'light', notes)
    dark = _colors(manifest, 'dark', notes)
    if not light and not dark:
        raise Refused('it has neither "light" nor "dark" colours')
    assets = manifest.get('assets', {})
    if not isinstance(assets, dict):
        raise Refused('"assets" must name its files')
    files = {}
    for role, name in assets.items():
        if role in PNG_ROLES:
            if not isinstance(name, str) or not PNG_FILE.match(name):
                raise Refused(f'"{role}" must be a .png file, in no folder')
        elif role in IMAGE_ROLES:
            if not isinstance(name, str) or not IMAGE_FILE.match(name):
                raise Refused(f'"{role}" must be a .png or .webp file, in no folder')
        elif role in SOUND_ROLES:
            if not isinstance(name, str) or not SOUND_FILE.match(name):
                raise Refused(f'"{role}" must be a .wav, .ogg or .mp3 file, in no folder')
        else:
            notes.append(f'assets: "{role}" is nothing this version shows; the app passes over it')
            continue
        files[role] = name
    return files


def sound_kind(data):
    """'wav', 'ogg' or 'mp3' by a sound's first bytes, as the app tells them."""
    if data[:4] == b'RIFF' and data[8:12] == b'WAVE':
        return 'wav'
    if data[:4] == b'OggS':
        return 'ogg'
    if data[:3] == b'ID3' or (len(data) >= 2 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0):
        return 'mp3'
    return None


def check_file(role, name, data):
    """Refuses a theme's file the app would refuse; else what it is."""
    if role in IMAGE_ROLES:
        if len(data) > MAX_IMAGE:
            raise Refused(f'{role}: {name} is larger than {MAX_IMAGE // (1024 * 1024)} MiB')
        try:
            info = picture_info(data)
        except ValueError:
            info = None
        if info is None or info[0] not in ('png', 'webp') or not name.endswith('.' + info[0]):
            raise Refused(f'{role}: {name} is not the picture its name says')
        _, width, height, frames = info
        if frames > 1:
            raise Refused(f'{role}: {name} must be a still picture')
        if not (1 <= width <= MAX_SIDE and 1 <= height <= MAX_SIDE):
            raise Refused(f'{role}: {name} is {width}x{height}, larger than {MAX_SIDE}x{MAX_SIDE}')
        return f'{width}x{height}'
    if len(data) > MAX_SOUND:
        raise Refused(f'{role}: {name} is larger than {MAX_SOUND // (1024 * 1024)} MiB')
    kind = sound_kind(data)
    if kind is None or not name.endswith('.' + kind):
        raise Refused(f'{role}: {name} is not the sound its name says')
    return kind.upper()


def check(data, notes):
    """Refuses a theme file the app would refuse; else (manifest, files)."""
    if len(data) > MAX_THEME:
        raise Refused(f'the file is larger than {MAX_THEME // (1024 * 1024)} MiB')
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e:
        raise Refused('not a zip file') from e
    with archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES:
            raise Refused(f'it holds more than {MAX_ENTRIES} files')
        names, total = set(), 0
        for entry in entries:
            if entry.filename in names:
                raise Refused(f'{entry.filename} is there twice')
            names.add(entry.filename)
            if entry.flag_bits & 1:
                raise Refused(f'{entry.filename} is encrypted')
            if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise Refused(f'{entry.filename} is compressed other than by deflate')
            if entry.create_system == 3 and (entry.external_attr >> 16) & 0xF000 == 0xA000:
                raise Refused(f'{entry.filename} is a link')
            total += entry.file_size
        if total > MAX_TOTAL:
            raise Refused(f'it is larger than {MAX_TOTAL // (1024 * 1024)} MiB unpacked')
        if 'pack.json' not in names:
            raise Refused('it has no pack.json at its top level')
        if archive.getinfo('pack.json').file_size > MAX_MANIFEST:
            raise Refused(f'pack.json is larger than {MAX_MANIFEST // 1024} KiB')
        try:
            manifest = json.loads(archive.read('pack.json'))
        except ValueError as e:
            raise Refused(f'pack.json is not JSON: {e}') from e
        files = {}
        for role, name in check_manifest(manifest, notes).items():
            if name not in names:
                raise Refused(f'{role}: there is no {name}')
            files[role] = (name, check_file(role, name, archive.read(name)))
        return manifest, files


def describe(manifest, files):
    variants = ' and '.join(v for v in ('light', 'dark') if v in manifest)
    named = _text(manifest.get('appName'), MAX_APP_NAME)
    shown = ', '.join(f'{role} {name} ({what})' for role, (name, what) in files.items())
    return (f'"{manifest["title"]}" ({manifest["id"]})' + (f', naming the app "{named}"' if named else '')
            + f', {variants} colours' + (f'; {shown}' if shown else ''))


def make(folder, output):
    notes = []
    try:
        manifest = json.loads((folder / 'pack.json').read_text(encoding='utf-8'))
    except FileNotFoundError:
        sys.exit(f'{folder} has no pack.json')
    except ValueError as e:
        sys.exit(f'{folder / "pack.json"} is not JSON: {e}')
    try:
        files = check_manifest(manifest, [])
    except Refused as e:
        sys.exit(f'The theme would not be taken: {e}')
    entries = []
    for name in dict.fromkeys(files.values()):
        path = folder / name
        if not path.is_file():
            sys.exit(f'{folder} has no {name}')
        entries.append((name, path.read_bytes()))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        json_bytes = (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode()
        for name, data in [('pack.json', json_bytes), *entries]:
            entry = zipfile.ZipInfo(name, date_time=DATE)
            entry.create_system = 0
            # Pictures and most sounds are compressed already.
            entry.compress_type = zipfile.ZIP_DEFLATED if name.endswith(('.json', '.wav')) else zipfile.ZIP_STORED
            archive.writestr(entry, data)
    try:
        manifest, checked = check(buffer.getvalue(), notes)
    except Refused as e:
        sys.exit(f'The theme would not be taken: {e}')
    out = pathlib.Path(output or f'{manifest["id"]}.zip')
    out.write_bytes(buffer.getvalue())
    for note in notes:
        print(f'Note: {note}')
    print(f'{out}: {describe(manifest, checked)}, {len(buffer.getvalue()) // 1024} KiB')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('folder', nargs='?', help='a folder of pack.json and the files it names')
    parser.add_argument('-o', '--output', help='the file to write (<id>.zip)')
    parser.add_argument('--check', metavar='THEME', help='check a theme file instead')
    args = parser.parse_args()
    if args.check:
        notes = []
        try:
            manifest, files = check(pathlib.Path(args.check).read_bytes(), notes)
        except Refused as e:
            sys.exit(f'{args.check} is not a theme the app takes: {e}')
        for note in notes:
            print(f'Note: {note}')
        print(f'{args.check}: {describe(manifest, files)}: fine')
        return
    if not args.folder:
        parser.error('give a folder, or --check a theme')
    make(pathlib.Path(args.folder), args.output)


if __name__ == '__main__':
    main()
