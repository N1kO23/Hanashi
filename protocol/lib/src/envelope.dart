import 'dart:convert';

import 'links.dart';
import 'ulid.dart';
import 'user_id.dart';

/// Message kinds understood by this protocol version.
///
/// [Envelope.type] is kept as a raw string so that messages of kinds added in
/// later versions survive a round trip through older servers and clients.
enum MessageType {
  text,
  image,
  video,
  file,

  /// A GIF (see [GifRef]): shown playing, like a sticker would be.
  gif,

  /// A sticker (see [StickerRef]): a picture shown by itself, without a
  /// bubble.
  sticker,

  /// A voice call started in the chat: `{"call": callId}`, sent by whoever
  /// started it. It is the call's place in the chat; how the call goes is the
  /// server's to say (see `Call`).
  call;

  static MessageType? tryParse(String value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }

  /// Shown on a card with its file.
  bool get isMedia => this == image || this == video || this == file || this == gif;
}

final _contentHashPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

/// Media is addressed by the SHA-256 of its bytes: `sha256:<64 hex chars>`.
bool isContentHash(String value) => _contentHashPattern.hasMatch(value);

/// Reference to an uploaded blob, as carried inside a media message body.
///
/// Dimensions, duration and the thumbnail are produced by the sending client,
/// never by the server, so the same shape works once media is encrypted.
class MediaRef {
  const MediaRef({
    required this.hash,
    required this.size,
    required this.mime,
    this.name,
    this.width,
    this.height,
    this.durationMs,
    this.thumb,
    this.key,
    this.host,
  });

  /// SHA-256 of the stored (encrypted) blob.
  final String hash;
  final int size;
  final String mime;
  final String? name;
  final int? width;
  final int? height;
  final int? durationMs;
  final MediaRef? thumb;

  /// Base64 key the blob is encrypted with; [size] is the plaintext size.
  final String? key;

  /// The host of the server that has the blob, the uploader's. Readers of
  /// other servers get it through their own, which fetches it from there;
  /// without it, the blob is on the reader's own server.
  final String? host;

  /// This reference, saying the blob (and its thumbnail) is on [host]'s server.
  MediaRef at(String host) => MediaRef(
    hash: hash,
    size: size,
    mime: mime,
    name: name,
    width: width,
    height: height,
    durationMs: durationMs,
    thumb: thumb?.at(host),
    key: key,
    host: host,
  );

  factory MediaRef.fromJson(Map<String, Object?> json) {
    final hash = json['hash'];
    final size = json['size'];
    final mime = json['mime'];
    if (hash is! String || !isContentHash(hash)) {
      throw FormatException('media.hash must be sha256:<hex>', hash);
    }
    if (size is! int || size < 0) {
      throw FormatException('media.size must be a non-negative int', size);
    }
    if (mime is! String || mime.isEmpty) {
      throw FormatException('media.mime must be a string', mime);
    }
    final thumb = json['thumb'];
    return MediaRef(
      hash: hash,
      size: size,
      mime: mime,
      name: _optional<String>(json, 'name'),
      width: _optional<int>(json, 'w'),
      height: _optional<int>(json, 'h'),
      durationMs: _optional<int>(json, 'durationMs'),
      thumb: thumb == null ? null : MediaRef.fromJson(_asMap(thumb, 'media.thumb')),
      key: _optional<String>(json, 'key'),
      // One that is no host is as good as none: the reader's own server.
      host: switch (json['host']) {
        final String host when UserId.isValidHost(host) => host,
        _ => null,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'hash': hash,
    'size': size,
    'mime': mime,
    if (name != null) 'name': name,
    if (width != null) 'w': width,
    if (height != null) 'h': height,
    if (durationMs != null) 'durationMs': durationMs,
    if (thumb != null) 'thumb': thumb!.toJson(),
    'key': ?key,
    'host': ?host,
  };
}

/// Media a provider serves, such as a GIF from KLIPY. Every device loads it
/// from the provider itself (providers do not allow copies elsewhere), so
/// only the provider's own hosts are accepted: a message cannot make the
/// app contact anyone else.
class RemoteMedia {
  const RemoteMedia({
    required this.provider,
    required this.id,
    required this.url,
    required this.mime,
    required this.width,
    required this.height,
    this.title,
  });

  static const klipy = 'klipy';

  /// Who serves it: [klipy].
  final String provider;

  /// The provider's ID for it (KLIPY: the slug).
  final String id;

  /// HTTPS, on one of [provider]'s hosts (see [isAllowed]).
  final String url;
  final String mime;
  final int width;
  final int height;

  /// The provider's description, e.g. for screen readers.
  final String? title;

  /// Longest [title] kept.
  static const maxTitle = 100;

  /// Whether [url] is where [provider] serves media.
  static bool isAllowed(String provider, Uri url) =>
      url.scheme == 'https' &&
      url.userInfo.isEmpty &&
      switch (provider) {
        klipy => url.host == 'klipy.com' || url.host.endsWith('.klipy.com'),
        _ => false,
      };

  factory RemoteMedia.fromJson(Map<String, Object?> json) {
    final provider = json['provider'];
    final id = json['id'];
    final url = json['url'];
    final mime = json['mime'];
    final width = json['w'];
    final height = json['h'];
    if (provider is! String || id is! String || id.isEmpty) {
      throw FormatException('remote media needs "provider" and "id"', json);
    }
    if (url is! String || !isAllowed(provider, Uri.tryParse(url) ?? Uri())) {
      throw FormatException('remote.url must be an HTTPS address of $provider', url);
    }
    if (mime is! String || !mime.startsWith('image/')) {
      throw FormatException('remote.mime must be an image type', mime);
    }
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      throw const FormatException('remote media needs its size ("w", "h")');
    }
    return RemoteMedia(
      provider: provider,
      id: id,
      url: url,
      mime: mime,
      width: width,
      height: height,
      title: _optional<String>(json, 'title'),
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'id': id,
    'url': url,
    'mime': mime,
    'w': width,
    'h': height,
    'title': ?title,
  };
}

/// A GIF: a file uploaded like any attachment ([media]), or one a provider
/// serves ([remote]). Exactly one is set.
class GifRef {
  const GifRef.media(MediaRef this.media) : remote = null;
  const GifRef.remote(RemoteMedia this.remote) : media = null;

  final MediaRef? media;
  final RemoteMedia? remote;

  int? get width => media?.width ?? remote?.width;
  int? get height => media?.height ?? remote?.height;

  /// The same for the same GIF, wherever it was sent or saved.
  String get key => media?.hash ?? '${remote!.provider}:${remote!.id}';

  /// From a message body or a saved GIF: `{"media": MediaRef}` or
  /// `{"remote": RemoteMedia}`.
  factory GifRef.fromJson(Map<String, Object?> json) {
    final media = json['media'];
    final remote = json['remote'];
    if ((media == null) == (remote == null)) {
      throw const FormatException('a GIF needs either "media" or "remote"');
    }
    return media != null
        ? GifRef.media(MediaRef.fromJson(_asMap(media, 'gif.media')))
        : GifRef.remote(RemoteMedia.fromJson(_asMap(remote, 'gif.remote')));
  }

  Map<String, Object?> toJson() => media != null ? {'media': media!.toJson()} : {'remote': remote!.toJson()};
}

/// The picture of a sticker message: one sent as its picture, encrypted and
/// uploaded like any file (`media`), maybe from a sticker pack (`from`, see
/// [StickerSource]). On the user's own devices a pack's sticker may also be
/// named by its pack and ID (`pack` and `id`, with nothing uploaded): in the
/// picker, and kept while they do not have its pack. A message always
/// carries the picture: it goes when it is sent.
///
/// Never both: one is either named or a picture.
class StickerRef {
  const StickerRef.named({required String this.pack, required String this.id}) : media = null, source = null;
  const StickerRef.media(MediaRef this.media, {this.source}) : pack = null, id = null;

  final String? pack;
  final String? id;
  final MediaRef? media;

  /// The pack a sticker sent as its picture comes from, if any: shown and
  /// offered to whoever gets it, never in place of the picture.
  final StickerSource? source;

  /// Named by its pack and ID, with nothing uploaded.
  bool get isNamed => pack != null;

  /// The pack and ID of a pack's sticker, named or sent as its picture.
  ({String pack, String id})? get packSticker {
    if (pack != null) return (pack: pack!, id: id!);
    final from = source;
    return from == null ? null : (pack: from.pack, id: from.id);
  }

  /// The same for the same sticker, wherever it was sent or saved: a pack's
  /// sticker by its pack and ID (whoever uploaded its picture), any other by
  /// its file.
  String get key => switch (packSticker) {
    (:final pack, :final id) => '$pack:$id',
    null => media!.hash,
  };

  /// What a pack or sticker ID can be.
  static final idPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

  /// From a message body or a saved sticker: `{"pack", "id"}` or
  /// `{"media": MediaRef, "from"?: StickerSource}`.
  factory StickerRef.fromJson(Map<String, Object?> json) {
    final (pack, id, media) = (json['pack'], json['id'], json['media']);
    if (media != null) {
      if (pack != null || id != null) throw const FormatException('a sticker is either named or "media"');
      return StickerRef.media(
        MediaRef.fromJson(_asMap(media, 'sticker.media')),
        source: StickerSource.tryParse(json['from']),
      );
    }
    if (pack is! String || id is! String || !idPattern.hasMatch(pack) || !idPattern.hasMatch(id)) {
      throw const FormatException('a sticker needs "pack" and "id", or "media"');
    }
    return StickerRef.named(pack: pack, id: id);
  }

  Map<String, Object?> toJson() =>
      media != null ? {'media': media!.toJson(), 'from': ?source?.toJson()} : {'pack': pack, 'id': id};

  @override
  bool operator ==(Object other) => other is StickerRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'StickerRef($key)';
}

/// Where a sticker sent as its picture comes from: a sticker pack, as
/// `"from": {"pack", "id", "title"?, "archive"?}` beside `"media"`. Whoever
/// gets it sees the pack's title and can add the pack, whose file is
/// [archive] (encrypted and uploaded like any; see `StickerPackManifest`).
/// Only ever shown and offered: the picture is the message's `media`,
/// whatever packs a reader has.
class StickerSource {
  const StickerSource({required this.pack, required this.id, this.title, this.archive, this.extra = const {}});

  /// The pack's ID (the same ID is the same pack), and the sticker's in it.
  final String pack;
  final String id;

  /// The pack's title as the sender's app has it: a claim until the pack is
  /// fetched.
  final String? title;

  /// The pack's file.
  final MediaRef? archive;

  /// Fields from later versions, kept as they came.
  final Map<String, Object?> extra;

  /// The longest a pack's title (or author) can be.
  static const maxTitle = 64;

  static const _known = {'pack', 'id', 'title', 'archive'};

  /// Null unless [json] names a pack and a sticker in it. A malformed title
  /// or archive is left out, never the source, so never the message either.
  static StickerSource? tryParse(Object? json) {
    if (json is! Map) return null;
    final (pack, id, title, archive) = (json['pack'], json['id'], json['title'], json['archive']);
    if (pack is! String ||
        id is! String ||
        !StickerRef.idPattern.hasMatch(pack) ||
        !StickerRef.idPattern.hasMatch(id)) {
      return null;
    }
    MediaRef? file;
    if (archive is Map) {
      try {
        file = MediaRef.fromJson(archive.cast<String, Object?>());
      } on FormatException {
        file = null;
      }
    }
    return StickerSource(
      pack: pack,
      id: id,
      title: title is String && title.trim().isNotEmpty && title.length <= maxTitle ? title : null,
      archive: file,
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && !_known.contains(key)) key: value,
      },
    );
  }

  /// This source with its pack's [title] and file as given.
  StickerSource withPack({required String title, required MediaRef archive}) =>
      StickerSource(pack: pack, id: id, title: title, archive: archive, extra: extra);

  Map<String, Object?> toJson() => {...extra, 'pack': pack, 'id': id, 'title': ?title, 'archive': ?archive?.toJson()};
}

/// Custom emoji: pictures that text shows wherever it says `:name:`. A
/// message carries those its text uses, as `"emojis": {name: MediaRef}`, so
/// it shows the same to everyone, whatever becomes of the set they came from:
/// the sender's own, or a group's ([GroupDocument.emojis]).
abstract final class CustomEmoji {
  /// A name: 2 to 32 of `a-z`, `0-9` and `_`.
  static final namePattern = RegExp(r'^[a-z0-9_]{2,32}$');

  /// `:name` with a `:` after it, the name being the first group.
  static final _candidate = RegExp(r':([a-z0-9_]{2,32})(?=:)');

  /// The most a message carries; others it names stay text.
  static const maxPerMessage = 50;

  /// The most a set holds, the user's own or a group's.
  static const maxPerSet = 100;

  /// The longest side of a picture, in pixels.
  static const size = 128;

  /// Where [text] shows custom emojis: each `:name:` whose name it [has], in
  /// order. Two do not share a colon: `:a:b:` is `a`, then `b:` as text.
  static Iterable<({int start, int end, String name})> find(String text, bool Function(String name) has) sync* {
    var at = 0;
    for (final match in _candidate.allMatches(text)) {
      final name = match[1]!;
      if (match.start < at || !has(name)) continue;
      at = match.end + 1;
      yield (start: match.start, end: at, name: name);
    }
  }

  /// The well-formed ones of [json] (`{name: MediaRef}`): a name, and a
  /// picture. The rest are left out, so a later version's (or a malformed)
  /// one cannot stop a message from showing.
  static Map<String, MediaRef> parse(Object? json) {
    if (json is! Map) return const {};
    final emojis = <String, MediaRef>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || !namePattern.hasMatch(key) || value is! Map) continue;
      try {
        final picture = MediaRef.fromJson(value.cast<String, Object?>());
        if (picture.mime.startsWith('image/')) emojis[key] = picture;
      } on FormatException {
        continue;
      }
    }
    return emojis;
  }

  /// Null for none, to leave the field out.
  static Map<String, Object?>? toJson(Map<String, MediaRef> emojis) =>
      emojis.isEmpty ? null : {for (final MapEntry(:key, :value) in emojis.entries) key: value.toJson()};

  /// Just what a picture needs to be shown: one taken from a message keeps
  /// nothing else of it (a file name, say) in a set.
  static MediaRef picture(MediaRef media) => MediaRef(
    hash: media.hash,
    size: media.size,
    mime: media.mime,
    width: media.width,
    height: media.height,
    key: media.key,
    host: media.host,
  );
}

/// The message a reply quotes: enough to show the quote where the original
/// is not available (e.g. to a member who joined later).
class ReplyRef {
  const ReplyRef({required this.id, required this.from, this.text});

  /// The quoted message.
  final String id;
  final String from;

  /// Its preview when the reply was written, at most [maxText] characters.
  final String? text;

  static const maxText = 200;

  factory ReplyRef.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final from = json['from'];
    if (id is! String || !isUlid(id)) throw FormatException('replyTo.id must be a ULID', id);
    if (from is! String || UserId.tryParse(from) == null) {
      throw FormatException('replyTo.from must be name@host', from);
    }
    return ReplyRef(id: id, from: from, text: _optional<String>(json, 'text'));
  }

  Map<String, Object?> toJson() => {'id': id, 'from': from, 'text': ?text};
}

/// What a user tells everyone they chat with about themself: the document in
/// their signed profile record, encrypted with their profile key. Later
/// versions add fields; [extra] keeps them when the user edits it here.
class ProfileDocument {
  const ProfileDocument({this.displayName, this.avatar, this.card, this.extra = const {}});

  /// Null: only their user ID to go by.
  final String? displayName;

  /// Null: no picture.
  final MediaRef? avatar;

  /// The JSON file of the user's `ProfileCard`; null: nothing to tell.
  final MediaRef? card;
  final Map<String, Object?> extra;

  static const maxDisplayName = 64;
  static const _known = {'displayName', 'avatar', 'card'};

  /// Throws [FormatException] for one that is malformed.
  factory ProfileDocument.fromJson(Map<String, Object?> json) {
    final (name, avatar, card) = (json['displayName'], json['avatar'], json['card']);
    if (name != null && (name is! String || name.trim().isEmpty || name.runes.length > maxDisplayName)) {
      throw FormatException('displayName must be 1 to $maxDisplayName characters', name);
    }
    return ProfileDocument(
      displayName: name as String?,
      avatar: avatar == null ? null : MediaRef.fromJson(_asMap(avatar, 'avatar')),
      card: card == null ? null : MediaRef.fromJson(_asMap(card, 'card')),
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (!_known.contains(key)) key: value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'displayName': ?displayName,
    'avatar': ?avatar?.toJson(),
    'card': ?card?.toJson(),
  };
}

/// What a group's members agree it is called and looks like: its state, sealed
/// for them on the server and pinned by a hash that commits carry. [salt] keeps
/// the server from testing guesses against that hash.
class GroupDocument {
  const GroupDocument({
    required this.salt,
    this.title,
    this.description,
    this.picture,
    this.emojis = const {},
    this.extra = const {},
  });

  /// Base64 of 32 random bytes, new with every change.
  final String salt;

  /// Null for direct chats.
  final String? title;

  /// What the group is about, in a few lines: at most [maxDescription]
  /// characters. Null: none.
  final String? description;

  /// Null: no picture.
  final MediaRef? picture;

  /// The group's custom emojis, by name ([CustomEmoji]), which any member
  /// can change. Malformed ones are left out.
  final Map<String, MediaRef> emojis;
  final Map<String, Object?> extra;

  static const maxTitle = 64;
  static const maxDescription = 500;
  static const _known = {'salt', 'title', 'description', 'picture', 'emojis'};

  /// Throws [FormatException] for one that is malformed. A malformed
  /// description is left out instead.
  factory GroupDocument.fromJson(Map<String, Object?> json) {
    final (salt, title, description, picture) = (json['salt'], json['title'], json['description'], json['picture']);
    if (salt is! String || salt.isEmpty) throw FormatException('salt must be a string', salt);
    if (title != null && (title is! String || title.trim().isEmpty || title.runes.length > maxTitle)) {
      throw FormatException('title must be 1 to $maxTitle characters', title);
    }
    return GroupDocument(
      salt: salt,
      title: title as String?,
      description: description is String && description.trim().isNotEmpty && description.runes.length <= maxDescription
          ? description
          : null,
      picture: picture == null ? null : MediaRef.fromJson(_asMap(picture, 'picture')),
      emojis: CustomEmoji.parse(json['emojis']),
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (!_known.contains(key)) key: value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'salt': salt,
    'title': ?title,
    'description': ?description,
    'picture': ?picture?.toJson(),
    'emojis': ?CustomEmoji.toJson(emojis),
  };
}

/// What a link leads to: a web page, a video page (e.g. YouTube), a GIF (a
/// page whose content is one, or the file itself), or a file such as an
/// image.
enum LinkKind {
  page,
  video,
  gif,
  image,
  file;

  /// Kinds added later show as pages.
  static LinkKind parse(Object? value) => values.firstWhere((k) => k.name == value, orElse: () => page);
}

/// Where a link's video or GIF is on its site. Recipients who choose to can
/// load it from there when it did not come with the message
/// ([LinkPreview.media]): apps ask first, and then the site sees who loads it.
class LinkSource {
  const LinkSource({required this.url, required this.mime, this.width, this.height, this.durationMs});

  /// HTTPS.
  final String url;

  /// `video/*` or `image/*`.
  final String mime;
  final int? width;
  final int? height;
  final int? durationMs;

  /// Null for anything that is not one: a preview goes on without it.
  static LinkSource? tryParse(Object? json) {
    if (json is! Map) return null;
    final (url, mime) = (json['url'], json['mime']);
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    if (mime is! String || !(mime.startsWith('video/') || mime.startsWith('image/'))) return null;
    int? size(Object? value) => value is int && value > 0 ? value : null;
    return LinkSource(
      url: url as String,
      mime: mime,
      width: size(json['w']),
      height: size(json['h']),
      durationMs: size(json['durationMs']),
    );
  }

  Map<String, Object?> toJson() => {'url': url, 'mime': mime, 'w': ?width, 'h': ?height, 'durationMs': ?durationMs};
}

/// A preview of a link in a text message, made by the sender's app before
/// sending: recipients show it without contacting the site. Its picture, and
/// the video or GIF it embeds, are encrypted blobs like any attachment.
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.kind = LinkKind.page,
    this.title,
    this.description,
    this.site,
    this.thumb,
    this.media,
    this.source,
    this.color,
    this.mime,
    this.size,
  });

  /// The link, as [findLinks] finds it in the message's text.
  final String url;
  final LinkKind kind;

  /// A page's title, or a file's name.
  final String? title;
  final String? description;

  /// The site's name, e.g. "YouTube".
  final String? site;

  /// The page's picture, or the image itself, made small.
  final MediaRef? thumb;

  /// The page's video or GIF, or the file itself (`video/*` or `image/*`),
  /// played in the chat: for [LinkKind.gif] in place, over and over without
  /// sound; for [LinkKind.video] on a tap. Or the page's still picture, or
  /// the image itself, as the site has it: shown in the viewer, while [thumb]
  /// is in the chat.
  final MediaRef? media;

  /// Where the site has the video or GIF, also when it is not [media] (too
  /// large to send, say).
  final LinkSource? source;

  /// The site's colour (its `theme-color`), as `#rrggbb`.
  final String? color;

  /// A file's type and size, if the site told.
  final String? mime;
  final int? size;

  /// Longest [title], [description] and [site] kept.
  static const maxTitle = 200;
  static const maxDescription = 300;
  static const maxSite = 100;

  /// A page's picture smaller than this on its long side (in pixels) is an
  /// icon: shown small beside the text, where larger ones are shown large.
  static const iconSize = 300;

  factory LinkPreview.fromJson(Map<String, Object?> json) {
    final url = json['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw FormatException('link.url must be an http(s) address', url);
    }
    final size = _optional<int>(json, 'size');
    if (size != null && size < 0) throw FormatException('link.size must not be negative', size);
    final thumb = json['thumb'];
    final media = json['media'] == null ? null : MediaRef.fromJson(_asMap(json['media'], 'link.media'));
    final color = _optional<String>(json, 'color');
    return LinkPreview(
      url: url as String,
      kind: LinkKind.parse(json['kind']),
      title: _optional<String>(json, 'title'),
      description: _optional<String>(json, 'description'),
      site: _optional<String>(json, 'site'),
      thumb: thumb == null ? null : MediaRef.fromJson(_asMap(thumb, 'link.thumb')),
      // Only what the chat can play.
      media: media != null && (media.mime.startsWith('video/') || media.mime.startsWith('image/')) ? media : null,
      source: LinkSource.tryParse(json['source']),
      color: color != null && isLinkColor(color) ? color : null,
      mime: _optional<String>(json, 'mime'),
      size: size,
    );
  }

  /// Whether [color] is `#rrggbb`.
  static bool isLinkColor(String color) => _colorPattern.hasMatch(color);

  static final _colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

  Map<String, Object?> toJson() => {
    'url': url,
    'kind': kind.name,
    'title': ?title,
    'description': ?description,
    'site': ?site,
    'thumb': ?thumb?.toJson(),
    'media': ?media?.toJson(),
    'source': ?source?.toJson(),
    'color': ?color,
    'mime': ?mime,
    'size': ?size,
  };
}

/// A chat message as it travels between clients.
///
/// The server stores and relays envelopes but treats [body] as opaque apart
/// from a size limit, so the body can later be replaced by ciphertext.
class Envelope {
  const Envelope({
    this.v = version,
    required this.id,
    required this.conv,
    required this.from,
    required this.ts,
    required this.type,
    required this.body,
  });

  static const version = 1;

  /// Local placeholder type for a received message that could not be
  /// decrypted (yet). Never sent.
  static const encryptedType = 'encrypted';

  /// Local type for a change to a group, shown in its timeline ("Kumiko
  /// added Naoko"). Never sent, and refused from others ([localTypes]): what
  /// members say about their own changes comes as [memberType]. `from` is who
  /// made the change; `body` is `{"change": "created"|"added"|"left"|"renamed"|...,
  /// "user"?, "title"?, "server"?: true}`, where `server` marks a line that
  /// only the server's events say, until the member's own word replaces it.
  static const membershipType = 'membership';

  /// A member's own word on a change they made to the group's members, sent
  /// to the group and shown as a line in its timeline: `{"change": "created"}`
  /// (by its creator), `{"change": "added", "user": userId}` or
  /// `{"change": "left"}` (sent just before leaving). Encrypted and signed like
  /// any message, so it is the sender's say, not the server's.
  static const memberType = 'member';

  /// The changes a [memberType] message can be about.
  static const memberChanges = {'created', 'added', 'left'};

  /// Local type for a message from someone else that claimed one of the
  /// [localTypes]: shown as unsupported, never as what it claims to be.
  static const refusedType = 'refused';

  /// A reaction to a message: `{"target": id, "emoji": "👍"}` adds the
  /// sender's 👍, and with `"remove": true` takes it back. A user can react
  /// with several emoji.
  static const reactionType = 'reaction';

  /// New text for one of the sender's own messages: `{"target", "text",
  /// "emojis"?}`, the emojis being those of the new text (see [CustomEmoji]).
  static const editType = 'edit';

  /// Deletes one of the sender's own messages for everyone: `{"target"}`.
  static const deleteType = 'delete';

  /// Control message (never part of a chat): the sender's profile key,
  /// `{"key": base64}`, which opens their profile record.
  static const profileKeyType = 'profile_key';

  /// Hands someone just added the keys to the messages from before:
  /// `{"user": userId, "keys": MediaRef}`, the keys in an encrypted file
  /// (see [historyKeys]). In the outbox, "keys" is left out until it is sent.
  static const historyType = 'history';

  /// Local type for what remains of a deleted message. Never sent.
  static const deletedType = 'deleted';

  /// Types this device makes for itself, which nobody else can send it.
  static const localTypes = {encryptedType, membershipType, deletedType, refusedType};

  /// Types that change other messages instead of showing in the timeline.
  static const hiddenTypes = {reactionType, editType, deleteType, historyType};

  /// Hidden types about one message ([target]).
  static const _targetedTypes = {reactionType, editType, deleteType};

  /// Longest reaction, in UTF-16 code units (emoji sequences can be long).
  static const maxReactionLength = 64;

  /// Upper bound for the JSON-encoded body. Large content goes in media blobs.
  static const maxBodyBytes = 64 * 1024;

  final int v;

  /// Client-generated ULID; makes retries idempotent across devices.
  final String id;

  /// Conversation ID.
  final String conv;

  /// Sender as `name@host`.
  final String from;

  /// Sender's clock, milliseconds since the Unix epoch.
  final int ts;

  final String type;
  final Map<String, Object?> body;

  factory Envelope.text({
    required String conv,
    required String from,
    required String text,
    Map<String, MediaRef> emojis = const {},
    ReplyRef? replyTo,
    LinkPreview? link,
    DateTime? now,
  }) => Envelope._new(conv, from, MessageType.text.name, {
    'text': text,
    'emojis': ?CustomEmoji.toJson(emojis),
    'replyTo': ?replyTo?.toJson(),
    'link': ?link?.toJson(),
  }, now);

  factory Envelope.media({
    required String conv,
    required String from,
    required MessageType type,
    required MediaRef media,
    String? caption,
    Map<String, MediaRef> emojis = const {},
    ReplyRef? replyTo,
    DateTime? now,
  }) {
    assert(type.isMedia);
    return Envelope._new(conv, from, type.name, {
      'media': media.toJson(),
      'text': ?caption,
      'emojis': ?CustomEmoji.toJson(emojis),
      'replyTo': ?replyTo?.toJson(),
    }, now);
  }

  factory Envelope.gif({
    required String conv,
    required String from,
    required GifRef gif,
    ReplyRef? replyTo,
    DateTime? now,
  }) => Envelope._new(conv, from, MessageType.gif.name, {...gif.toJson(), 'replyTo': ?replyTo?.toJson()}, now);

  factory Envelope.sticker({
    required String conv,
    required String from,
    required StickerRef sticker,
    ReplyRef? replyTo,
    DateTime? now,
  }) => Envelope._new(conv, from, MessageType.sticker.name, {...sticker.toJson(), 'replyTo': ?replyTo?.toJson()}, now);

  /// The record of the voice call [call] the sender started.
  factory Envelope.call({required String conv, required String from, required String call, DateTime? now}) =>
      Envelope._new(conv, from, MessageType.call.name, {'call': call}, now);

  /// Adds [emoji] to the sender's reactions to [target], or with [remove]
  /// takes it back.
  factory Envelope.reaction({
    required String conv,
    required String from,
    required String target,
    required String emoji,
    bool remove = false,
    DateTime? now,
  }) => Envelope._new(conv, from, reactionType, {'target': target, 'emoji': emoji, if (remove) 'remove': true}, now);

  factory Envelope.edit({
    required String conv,
    required String from,
    required String target,
    required String text,
    Map<String, MediaRef> emojis = const {},
    DateTime? now,
  }) =>
      Envelope._new(conv, from, editType, {'target': target, 'text': text, 'emojis': ?CustomEmoji.toJson(emojis)}, now);

  factory Envelope.delete({required String conv, required String from, required String target, DateTime? now}) =>
      Envelope._new(conv, from, deleteType, {'target': target}, now);

  factory Envelope.profileKey({required String conv, required String from, required String key, DateTime? now}) =>
      Envelope._new(conv, from, profileKeyType, {'key': key}, now);

  /// The sender's own word on a change of members ([memberType]).
  factory Envelope.member({
    required String conv,
    required String from,
    required String change,
    String? user,
    DateTime? now,
  }) => Envelope._new(conv, from, memberType, {'change': change, 'user': ?user}, now);

  /// Shares the history with [user], just added; the [keys] come when it is sent.
  factory Envelope.history({
    required String conv,
    required String from,
    required String user,
    MediaRef? keys,
    DateTime? now,
  }) => Envelope._new(conv, from, historyType, {'user': user, 'keys': ?keys?.toJson()}, now);

  factory Envelope._new(String conv, String from, String type, Map<String, Object?> body, DateTime? now) {
    final time = now ?? DateTime.now();
    return Envelope(
      id: newUlid(now: time),
      conv: conv,
      from: from,
      ts: time.millisecondsSinceEpoch,
      type: type,
      body: body,
    );
  }

  /// The same message with another body (e.g. edited).
  Envelope withBody(Map<String, Object?> body) =>
      Envelope(v: v, id: id, conv: conv, from: from, ts: ts, type: type, body: body);

  /// Parses and validates an envelope. Throws [FormatException] when invalid.
  factory Envelope.fromJson(Map<String, Object?> json) {
    final v = json['v'];
    final id = json['id'];
    final conv = json['conv'];
    final from = json['from'];
    final ts = json['ts'];
    final type = json['type'];
    final body = json['body'];
    if (v is! int || v < 1) {
      throw FormatException('v must be a positive int', v);
    }
    if (id is! String || !isUlid(id)) {
      throw FormatException('id must be a ULID', id);
    }
    if (conv is! String || conv.isEmpty) {
      throw FormatException('conv must be a string', conv);
    }
    if (from is! String || UserId.tryParse(from) == null) {
      throw FormatException('from must be name@host', from);
    }
    if (ts is! int) throw FormatException('ts must be an int', ts);
    if (type is! String || type.isEmpty) {
      throw FormatException('type must be a string', type);
    }
    final bodyMap = _asMap(body, 'body');
    if (utf8.encode(jsonEncode(bodyMap)).length > maxBodyBytes) {
      throw const FormatException('body is too large');
    }
    final envelope = Envelope(v: v, id: id, conv: conv, from: from, ts: ts, type: type, body: bodyMap);
    envelope._validateKnownBody();
    return envelope;
  }

  Map<String, Object?> toJson() => {'v': v, 'id': id, 'conv': conv, 'from': from, 'ts': ts, 'type': type, 'body': body};

  MessageType? get messageType => MessageType.tryParse(type);

  DateTime get sentAt => DateTime.fromMillisecondsSinceEpoch(ts);

  /// Text of a text message, or the caption of a media message.
  String? get text => body['text'] as String?;

  /// The custom emojis its [text] (or an edit's) shows, by name.
  Map<String, MediaRef> get emojis => CustomEmoji.parse(body['emojis']);

  MediaRef? get media {
    final media = body['media'];
    return media == null ? null : MediaRef.fromJson(_asMap(media, 'body.media'));
  }

  /// The GIF of a GIF message.
  GifRef? get gif => messageType == MessageType.gif ? GifRef.fromJson(body) : null;

  /// The sticker of a sticker message.
  StickerRef? get sticker => messageType == MessageType.sticker ? StickerRef.fromJson(body) : null;

  /// The call a call message is the record of.
  String? get callId => messageType == MessageType.call ? body['call'] as String? : null;

  /// The preview of a link in a text message. One for an address that is
  /// not in the text (any more, after an edit) is left out.
  LinkPreview? get link {
    final link = messageType == MessageType.text ? body['link'] : null;
    if (link == null) return null;
    final preview = LinkPreview.fromJson(_asMap(link, 'body.link'));
    return findLinks(text ?? '').any((l) => l.address == preview.url) ? preview : null;
  }

  /// The message this one replies to.
  ReplyRef? get replyTo {
    final reply = body['replyTo'];
    return reply == null ? null : ReplyRef.fromJson(_asMap(reply, 'body.replyTo'));
  }

  /// The sender's profile key, of a [profileKeyType] message.
  String? get profileKey => type == profileKeyType ? body['key'] as String? : null;

  /// Who a [historyType] message shares the history with.
  String? get sharedWith => type == historyType ? body['user'] as String? : null;

  /// The file with the keys of a [historyType] message.
  MediaRef? get historyKeys {
    final keys = type == historyType ? body['keys'] : null;
    return keys == null ? null : MediaRef.fromJson(_asMap(keys, 'body.keys'));
  }

  /// The message a reaction, edit or deletion is about.
  String? get target => _targetedTypes.contains(type) ? body['target'] as String? : null;

  /// Changes other messages; not shown in the timeline.
  bool get isHidden => hiddenTypes.contains(type);

  /// A line about the group in its timeline, made here or said by a member.
  bool get isGroupLine => type == membershipType || type == memberType;

  /// A reaction's emoji.
  String? get emoji => type == reactionType ? body['emoji'] as String? : null;

  /// This reaction takes [emoji] back.
  bool get removesReaction => type == reactionType && body['remove'] == true;

  /// Short human-readable summary for conversation lists and notifications.
  String get preview {
    switch (messageType) {
      case MessageType.text:
        return text ?? '';
      case MessageType.image:
        return text?.isNotEmpty == true ? '[Photo] $text' : '[Photo]';
      case MessageType.video:
        return text?.isNotEmpty == true ? '[Video] $text' : '[Video]';
      case MessageType.file:
        final kind = media?.mime.startsWith('audio/') == true ? 'Audio' : 'File';
        return '[$kind] ${media?.name ?? ''}'.trimRight();
      case MessageType.gif:
        return '[GIF]';
      case MessageType.sticker:
        return '[Sticker]';
      case MessageType.call:
        return '[Voice call]';
      case null:
        return switch (type) {
          encryptedType => 'Encrypted message',
          membershipType || memberType => 'Group updated',
          deletedType => 'This message was deleted',
          reactionType => removesReaction ? 'Removed a reaction' : 'Reacted $emoji',
          editType => 'Edited a message',
          deleteType => 'Deleted a message',
          historyType => 'Shared the chat history',
          _ => '[Unsupported message]',
        };
    }
  }

  void _validateKnownBody() {
    switch (messageType) {
      case MessageType.text:
        if (body['text'] is! String) {
          throw const FormatException('text body needs "text"');
        }
        replyTo; // These throw if malformed.
        link;
      case MessageType.image || MessageType.video || MessageType.file:
        if (body['media'] == null) {
          throw const FormatException('media body needs "media"');
        }
        media;
        replyTo;
        final caption = body['text'];
        if (caption != null && caption is! String) {
          throw const FormatException('caption must be a string');
        }
      case MessageType.gif:
        gif;
        replyTo;
      case MessageType.sticker:
        if (sticker?.media == null) throw const FormatException('a sticker message carries its picture ("media")');
        replyTo;
      case MessageType.call:
        if (body['call'] case final String call when isUlid(call)) break;
        throw FormatException('call body needs "call", a ULID', body['call']);
      case null:
        _validateHiddenBody();
    }
  }

  void _validateHiddenBody() {
    if (type == profileKeyType) {
      final key = body['key'];
      if (key is! String || key.isEmpty) throw FormatException('key must be a string', key);
      return;
    }
    if (type == memberType) {
      final change = body['change'];
      if (!memberChanges.contains(change)) throw FormatException('change must be one of $memberChanges', change);
      final user = body['user'];
      if (change == 'added' ? user is! String || UserId.tryParse(user) == null : user != null) {
        throw FormatException('user must be name@host for "added", and nothing otherwise', user);
      }
      return;
    }
    if (type == historyType) {
      final user = body['user'];
      if (user is! String || UserId.tryParse(user) == null) throw FormatException('user must be name@host', user);
      historyKeys;
      return;
    }
    if (!isHidden) return; // Unknown future type: relayed as-is.
    final target = body['target'];
    if (target is! String || !isUlid(target)) {
      throw FormatException('target must be a ULID', target);
    }
    switch (type) {
      case reactionType:
        final emoji = body['emoji'];
        if (emoji is! String || emoji.isEmpty || emoji.length > maxReactionLength) {
          throw FormatException('emoji must be a short string', emoji);
        }
        final remove = body['remove'];
        if (remove != null && remove is! bool) throw FormatException('remove must be true or false', remove);
      case editType:
        final text = body['text'];
        if (text is! String || text.trim().isEmpty) {
          throw const FormatException('edit body needs "text"');
        }
    }
  }
}

T? _optional<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is T) return value;
  throw FormatException('$key has the wrong type', value);
}

Map<String, Object?> _asMap(Object? value, String field) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('$field must be an object', value);
}
