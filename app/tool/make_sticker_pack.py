#!/usr/bin/env python3
"""Makes a sticker pack file from a folder of pictures, or checks one.

    python3 app/tool/make_sticker_pack.py <folder> --title "My pack" [--id ID]
        [--author NAME] [--cover STICKER] [--number] [--version N] [-o out.zip]
    python3 app/tool/make_sticker_pack.py --check pack.zip

A sticker pack is a zip file of pack.json and its stickers' pictures, all at
its top level (see "Sticker packs" in docs/protocol.md). People add a pack
from any of its stickers sent to them, or import its file in the sticker tab.

Each picture in <folder> (PNG, APNG, GIF, WebP or JPEG) becomes a sticker,
its ID the file's name without its extension (or, with --number, 01, 02...
in the folder's order). One that is a sticker already (a WebP, PNG or GIF
no larger than 512x512 and 512 KiB) goes in byte for byte; any other is
fitted into 512x512 (never enlarged) and made WebP at quality 90, animated
ones keeping their frames. Only that needs Pillow with WebP:

    python3 -m pip install pillow

A pack's ID names it: the same ID is the same pack, so a new version of a
pack keeps its ID, and a new pack needs one of its own (one is made up if
--id is not given). Sticker IDs may never change once a pack is out either:
messages name stickers by their pack's ID and their own.
"""

import argparse
import io
import json
import pathlib
import re
import secrets
import struct
import sys
import zipfile

# As the app checks them (lib/data/packs/sticker_pack_file.dart and
# protocol/lib/src/sticker_packs.dart).
ID = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
FILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,59}\.(webp|png|gif)$')
MAX_STICKERS = 100
MAX_TEXT = 64
MAX_EMOJI = 16
MAX_PACK = 8 * 1024 * 1024
MAX_ENTRIES = 128
MAX_MANIFEST = 64 * 1024
MAX_STICKER = 512 * 1024
MAX_TOTAL = 16 * 1024 * 1024
MAX_SIDE = 1024
MAX_ANIMATED_SIDE = 512
MAX_FRAMES = 150

SIDE = 512  # What pictures are fitted into.
INPUTS = {'.png', '.apng', '.gif', '.webp', '.jpg', '.jpeg'}
DATE = (2026, 1, 1, 0, 0, 0)  # Every entry's: the same pack makes the same file.


class Refused(Exception):
    pass


def picture_info(data):
    """(kind, width, height, frames) of a WebP, PNG or GIF, from its header;
    None for anything else. Raises ValueError for a damaged one."""
    try:
        if data[:8] == b'\x89PNG\r\n\x1a\n':
            return _png(data)
        if data[:6] in (b'GIF87a', b'GIF89a'):
            return _gif(data)
        if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
            return _webp(data)
    except (struct.error, IndexError) as e:
        raise ValueError('damaged') from e
    return None


def _png(data):
    width, height = struct.unpack('>II', data[16:24])
    frames, at = 1, 8
    while at + 8 <= len(data):
        length, kind = struct.unpack('>I4s', data[at:at + 8])
        if kind == b'acTL':
            frames = struct.unpack('>I', data[at + 8:at + 12])[0]
        if kind == b'IDAT':
            break
        at += 12 + length
    return 'png', width, height, max(1, frames)


def _skip_blocks(data, at):
    while True:
        size = data[at]
        at += 1
        if size == 0:
            return at
        at += size


def _gif(data):
    width, height = struct.unpack('<HH', data[6:10])
    flags, at, frames = data[10], 13, 0
    if flags & 0x80:
        at += 3 * (2 << (flags & 7))
    while at < len(data) and data[at] != 0x3B:
        if data[at] == 0x21:
            at = _skip_blocks(data, at + 2)
        elif data[at] == 0x2C:
            frames += 1
            local = data[at + 9]
            at += 10
            if local & 0x80:
                at += 3 * (2 << (local & 7))
            at = _skip_blocks(data, at + 1)
        else:
            raise ValueError('damaged')
    return 'gif', width, height, max(1, frames)


def _webp(data):
    at, width, height, frames, animated = 12, None, None, 0, False
    while at + 8 <= len(data):
        kind, size = data[at:at + 4], struct.unpack('<I', data[at + 4:at + 8])[0]
        body = data[at + 8:at + 8 + size]
        if kind == b'VP8X':
            animated = bool(body[0] & 0x02)
            width = 1 + int.from_bytes(body[4:7], 'little')
            height = 1 + int.from_bytes(body[7:10], 'little')
        elif kind == b'ANMF':
            frames += 1
        elif kind == b'VP8 ' and width is None:
            w, h = struct.unpack('<HH', body[6:10])
            width, height = w & 0x3FFF, h & 0x3FFF
        elif kind == b'VP8L' and width is None:
            bits = int.from_bytes(body[1:5], 'little')
            width, height = (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        at += 8 + size + (size & 1)
    if width is None:
        raise ValueError('damaged')
    return 'webp', width, height, max(1, frames if animated else 1)


def check_sticker(sticker, name, data):
    """Refuses [data] as a sticker's picture the app would refuse."""
    try:
        info = picture_info(data)
    except ValueError:
        info = None
    if info is None or not name.endswith('.' + info[0]):
        raise Refused(f'sticker {sticker}: {name} is not the picture its name says')
    _, width, height, frames = info
    if len(data) > MAX_STICKER:
        raise Refused(f'sticker {sticker}: {name} is larger than {MAX_STICKER // 1024} KiB')
    if frames > MAX_FRAMES:
        raise Refused(f'sticker {sticker}: {name} has more than {MAX_FRAMES} frames')
    side = MAX_ANIMATED_SIDE if frames > 1 else MAX_SIDE
    if not (1 <= width <= side and 1 <= height <= side):
        raise Refused(f'sticker {sticker}: {name} is {width}x{height}, larger than {side}x{side}')
    return info


def _text(value):
    return value.strip() if isinstance(value, str) and 0 < len(value.strip()) <= MAX_TEXT else None


def check_manifest(manifest):
    if not isinstance(manifest, dict) or manifest.get('type') != 'sticker-pack':
        raise Refused('pack.json: not a sticker pack (its "type" is not "sticker-pack")')
    if manifest.get('format') != 1:
        raise Refused('pack.json: "format" must be 1')
    if not isinstance(manifest.get('id'), str) or not ID.match(manifest['id']):
        raise Refused('pack.json: "id" must be 1 to 64 of A-Z, a-z, 0-9, ".", "_" and "-"')
    if _text(manifest.get('title')) is None:
        raise Refused(f'pack.json: "title" must be 1 to {MAX_TEXT} characters')
    stickers = manifest.get('stickers')
    if not isinstance(stickers, list) or not 1 <= len(stickers) <= MAX_STICKERS:
        raise Refused(f'pack.json: "stickers" must list 1 to {MAX_STICKERS}')
    seen = set()
    for sticker in stickers:
        sticker_id = sticker.get('id') if isinstance(sticker, dict) else None
        if not isinstance(sticker_id, str) or not ID.match(sticker_id):
            raise Refused(f'pack.json: {sticker!r} has no valid "id"')
        if sticker_id.lower() in seen:
            raise Refused(f'pack.json: "{sticker_id}" is there twice (letter case aside)')
        seen.add(sticker_id.lower())
        if not isinstance(sticker.get('file'), str) or not FILE.match(sticker['file']):
            raise Refused(f'pack.json: sticker {sticker_id} has no valid "file" (a .webp, .png or .gif, in no folder)')


def check(data):
    """Refuses a pack file the app would refuse; else (manifest, pictures)."""
    if len(data) > MAX_PACK:
        raise Refused(f'the file is larger than {MAX_PACK // (1024 * 1024)} MiB')
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
        check_manifest(manifest)
        pictures = {}
        for sticker in manifest['stickers']:
            name = sticker['file']
            if name not in names:
                raise Refused(f'sticker {sticker["id"]}: there is no {name}')
            if archive.getinfo(name).file_size > MAX_STICKER:
                raise Refused(f'sticker {sticker["id"]}: {name} is larger than {MAX_STICKER // 1024} KiB')
            pictures[name] = check_sticker(sticker['id'], name, archive.read(name))
        return manifest, pictures


def _natural(path):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r'(\d+)', path.name)]


def _fitted(path):
    """(kind, bytes): [path] as it goes into a pack."""
    data = path.read_bytes()
    try:
        info = picture_info(data)
    except ValueError:
        info = None
    if info is not None:
        _, width, height, frames = info
        if len(data) <= MAX_STICKER and max(width, height) <= SIDE and frames <= MAX_FRAMES:
            return info[0], data
    try:
        from PIL import Image, ImageSequence
    except ImportError:
        sys.exit(f'{path.name} has to be fitted or made WebP, which needs Pillow: python3 -m pip install pillow')
    frames, durations = [], []
    with Image.open(path) as image:
        for frame in ImageSequence.Iterator(image):
            durations.append(image.info.get('duration', 100))
            frame = frame.convert('RGBA')
            if max(frame.size) > SIDE:
                frame.thumbnail((SIDE, SIDE), Image.LANCZOS)
            frames.append(frame.copy())
    if len(frames) > MAX_FRAMES:
        sys.exit(f'{path.name} has {len(frames)} frames; a sticker can have {MAX_FRAMES}')
    out = io.BytesIO()
    if len(frames) > 1:
        frames[0].save(out, 'WEBP', save_all=True, append_images=frames[1:], duration=durations, loop=0,
                       quality=90, method=6)
    else:
        frames[0].save(out, 'WEBP', quality=90, method=6)
    if out.tell() > MAX_STICKER:
        sys.exit(f'{path.name} is {out.tell() // 1024} KiB as WebP; a sticker can be {MAX_STICKER // 1024} KiB')
    return 'webp', out.getvalue()


def make(args):
    folder = pathlib.Path(args.folder)
    files = sorted((p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in INPUTS), key=_natural)
    if not files:
        sys.exit(f'No pictures in {folder}')
    if len(files) > MAX_STICKERS:
        sys.exit(f'{len(files)} pictures in {folder}; a pack can have {MAX_STICKERS}')
    ids = [f'{n:02d}' for n in range(1, len(files) + 1)] if args.number else [p.stem for p in files]
    seen = set()
    for sticker_id, path in zip(ids, files):
        if not ID.match(sticker_id):
            sys.exit(f'{path.name}: "{sticker_id}" cannot be a sticker ID (1 to 64 of A-Z, a-z, 0-9, ".", "_" and "-"):'
                     ' rename the file, or use --number')
        if sticker_id.lower() in seen:
            sys.exit(f'{path.name}: another picture has the ID "{sticker_id}" (letter case aside): rename one, or use --number')
        seen.add(sticker_id.lower())
    pack_id = args.id or secrets.token_hex(8)
    stickers, entries, used = [], [], set()
    for n, (sticker_id, path) in enumerate(zip(ids, files), start=1):
        kind, data = _fitted(path)
        # Named after its sticker where that makes a file name.
        name = f'{sticker_id}.{kind}'
        if not FILE.match(name) or name.lower() in used:
            name = f'sticker-{n:03d}.{kind}'
        used.add(name.lower())
        stickers.append({'id': sticker_id, 'file': name})
        entries.append((name, data))
    manifest = {
        'format': 1,
        'type': 'sticker-pack',
        'id': pack_id,
        'title': args.title,
        **({'author': args.author} if args.author else {}),
        'cover': args.cover or ids[0],
        'version': args.version,
        'stickers': stickers,
    }
    if manifest['cover'] not in ids:
        sys.exit(f'--cover {args.cover}: there is no such sticker')
    out = pathlib.Path(args.output or f'{folder.resolve().name}.zip')
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_STORED) as archive:
        json_bytes = (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode()
        for name, data in [('pack.json', json_bytes), *entries]:
            entry = zipfile.ZipInfo(name, date_time=DATE)
            entry.create_system = 0
            entry.compress_type = zipfile.ZIP_STORED
            archive.writestr(entry, data)
    try:
        check(buffer.getvalue())
    except Refused as e:
        sys.exit(f'The pack would not be taken: {e}')
    out.write_bytes(buffer.getvalue())
    print(f'{out}: "{args.title}" ({pack_id}), {len(stickers)} stickers, {len(buffer.getvalue()) // 1024} KiB')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('folder', nargs='?', help='a folder of pictures')
    parser.add_argument('--title', help=f'the pack\'s title, 1 to {MAX_TEXT} characters')
    parser.add_argument('--id', help='the pack\'s ID; keep it for later versions of the pack')
    parser.add_argument('--author', help='who made it')
    parser.add_argument('--cover', help='the ID of the sticker that stands for the pack (else the first)')
    parser.add_argument('--number', action='store_true', help='number the stickers 01, 02... in order')
    parser.add_argument('--version', type=int, default=1, help='the pack\'s version (1)')
    parser.add_argument('-o', '--output', help='the file to write (<folder>.zip)')
    parser.add_argument('--check', metavar='PACK', help='check a pack file instead')
    args = parser.parse_args()
    if args.check:
        try:
            manifest, pictures = check(pathlib.Path(args.check).read_bytes())
        except Refused as e:
            sys.exit(f'{args.check} is not a sticker pack the app takes: {e}')
        animated = sum(1 for (_, _, _, frames) in pictures.values() if frames > 1)
        print(f'{args.check}: "{manifest["title"]}" ({manifest["id"]}), {len(manifest["stickers"])} stickers'
              + (f', {animated} animated' if animated else '') + ': fine')
        return
    if not args.folder or not args.title:
        parser.error('give a folder and --title, or --check a pack')
    if args.author is not None and _text(args.author) is None:
        parser.error(f'--author must be 1 to {MAX_TEXT} characters')
    if args.id is not None and not ID.match(args.id):
        parser.error('--id must be 1 to 64 of A-Z, a-z, 0-9, ".", "_" and "-"')
    make(args)


if __name__ == '__main__':
    main()
