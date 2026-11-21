import 'dart:convert';
import 'dart:io';

import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:test/test.dart';

const _hash = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Envelope _roundTrip(Envelope e) =>
    Envelope.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, Object?>);

void main() {
  group('ulid', () {
    test('has the right shape and sorts by time', () {
      final a = newUlid(now: DateTime.utc(2026, 1, 1));
      final b = newUlid(now: DateTime.utc(2026, 1, 2));
      expect(isUlid(a), isTrue);
      expect(a.length, 26);
      expect(a.compareTo(b), lessThan(0));
    });

    test('rejects malformed values', () {
      expect(isUlid('not-a-ulid'), isFalse);
      expect(isUlid('01ARZ3NDEKTSV4RRFFQ69G5FAI'), isFalse); // I is not Crockford.
    });
  });

  test('a MediaRef says which server has the blob, with its thumbnail', () {
    final ref = const MediaRef(
      hash: _hash,
      size: 9,
      mime: 'image/jpeg',
      thumb: MediaRef(hash: _hash, size: 1, mime: 'image/jpeg'),
    ).at('a.example');
    final back = MediaRef.fromJson(jsonDecode(jsonEncode(ref.toJson())) as Map<String, Object?>);
    expect((back.host, back.thumb!.host), ('a.example', 'a.example'));
    // Without one, or with what is no host: the reader's own server.
    expect(MediaRef.fromJson({'hash': _hash, 'size': 1, 'mime': 'image/png'}).host, isNull);
    expect(MediaRef.fromJson({'hash': _hash, 'size': 1, 'mime': 'image/png', 'host': 'no host'}).host, isNull);
  });

  group('UserId', () {
    test('parses name@host', () {
      final id = UserId.parse('sota@chat.example.org');
      expect(id.name, 'sota');
      expect(id.host, 'chat.example.org');
      expect(id.toString(), 'sota@chat.example.org');
    });

    test('allows a port on the host', () {
      expect(UserId.parse('michiko@localhost:8080').host, 'localhost:8080');
    });

    test('rejects invalid ids', () {
      expect(UserId.tryParse('nohost'), isNull);
      expect(UserId.tryParse('@host'), isNull);
      expect(UserId.tryParse('a@${'h' * 126}'), isNotNull);
      expect(UserId.tryParse('a@${'h' * 127}'), isNull, reason: '128 characters at most');
      expect(UserId.tryParse('Upper@host'), isNull);
      expect(UserId.tryParse('name@bad host'), isNull);
    });
  });

  group('shared fixtures (also checked by the Go server)', () {
    final fixtures = jsonDecode(File('testdata/envelopes.json').readAsStringSync()) as Map<String, Object?>;

    test('valid envelopes parse and round-trip unchanged', () {
      for (final json in (fixtures['valid'] as List).cast<Map<String, Object?>>()) {
        expect(EncryptedEnvelope.fromJson(json).toJson(), json);
      }
    });

    test('invalid envelopes, including plaintext ones, are rejected', () {
      for (final c in (fixtures['invalid'] as List).cast<Map<String, Object?>>()) {
        expect(
          () => EncryptedEnvelope.fromJson((c['envelope'] as Map).cast<String, Object?>()),
          throwsFormatException,
          reason: c['reason'] as String,
        );
      }
    });
  });

  test('device record bytes match the shared fixture (also checked by Go)', () {
    final f = jsonDecode(File('testdata/device_record.json').readAsStringSync()) as Map<String, Object?>;
    expect(
      deviceRecordMessage(f['userId'] as String, f['deviceId'] as String, f['mlsSigKey'] as String),
      base64.decode(f['message'] as String),
    );
  });

  test('web addresses in text, without the punctuation around them', () {
    List<String> addresses(String text) => [for (final l in findLinks(text)) l.address];
    expect(addresses('See https://example.com/a?b=c#d, and http://x.example.'), [
      'https://example.com/a?b=c#d',
      'http://x.example',
    ]);
    expect(addresses('(www.example.com/wiki/A_(b)) "https://fi.wikipedia.org/wiki/Hämeenlinna"'), [
      'https://www.example.com/wiki/A_(b)',
      'https://fi.wikipedia.org/wiki/Hämeenlinna',
    ]);
    expect(addresses('HTTPS://EXAMPLE.COM/X! <https://a.example/b> [https://b.example]…'), [
      'HTTPS://EXAMPLE.COM/X',
      'https://a.example/b',
      'https://b.example',
    ]);
    // Not an address of its own: in a word, an email address or another one.
    expect(addresses('awww.example.com me@www.example.com https:// https://. ftp://x.example'), isEmpty);
    expect(addresses('https://a.example/?u=https://b.example'), ['https://a.example/?u=https://b.example']);

    const text = 'Hi www.a.example!';
    final link = findLinks(text).single;
    expect((text.substring(link.start, link.end), link.uri.host), ('www.a.example', 'www.a.example'));
  });

  test('server info says the lowest client level, none on older servers', () {
    final base = {'host': 'a.example', 'version': '1', 'registration': 'open', 'maxUploadBytes': 1};
    expect(ServerInfo.fromJson(base).minClient, 0);
    final info = ServerInfo.fromJson({...base, 'minClient': 3});
    expect(info.minClient, 3);
    expect(info.toJson()['minClient'], 3);
  });

  test("server info says where the server's source is: a web address, or nothing", () {
    final base = {'host': 'a.example', 'version': '1', 'registration': 'open', 'maxUploadBytes': 1};
    expect(ServerInfo.fromJson(base).source, isNull);
    final info = ServerInfo.fromJson({...base, 'source': 'https://git.a.example/hanashi'});
    expect(info.source, Uri.parse('https://git.a.example/hanashi'));
    expect(info.toJson()['source'], 'https://git.a.example/hanashi');
    for (final other in ['', 'git.a.example/hanashi', 'javascript:alert(1)', 'file:///etc/passwd', 'https://']) {
      expect(ServerInfo.fromJson({...base, 'source': other}).source, isNull, reason: other);
    }
  });

  group('Envelope', () {
    test("lines about members say only what a member can say about their own change", () {
      Map<String, Object?> json(Map<String, Object?> body) =>
          Envelope.member(conv: 'c', from: 'a@b', change: 'left').toJson()..['body'] = body;
      for (final ok in [
        {'change': 'created'},
        {'change': 'left'},
        {'change': 'added', 'user': 'naoko@b'},
      ]) {
        final envelope = Envelope.fromJson(json(ok));
        expect((envelope.isGroupLine, envelope.isHidden, envelope.preview), (true, false, 'Group updated'));
      }
      for (final bad in [
        {'change': 'renamed', 'title': 'x'},
        {'change': 'added'},
        {'change': 'added', 'user': 'not an id'},
        {'change': 'left', 'user': 'naoko@b'},
      ]) {
        expect(() => Envelope.fromJson(json(bad)), throwsFormatException, reason: '$bad');
      }
      expect(Envelope.localTypes, containsAll([Envelope.membershipType, Envelope.encryptedType]));
      expect(Envelope.localTypes, isNot(contains(Envelope.memberType)));
    });

    test('text message round-trips', () {
      final e = Envelope.text(conv: 'c1', from: 'yuriko@localhost', text: 'Hello, Sota!');
      final back = _roundTrip(e);
      expect(back.id, e.id);
      expect(back.messageType, MessageType.text);
      expect(back.text, 'Hello, Sota!');
      expect(back.preview, 'Hello, Sota!');
    });

    test('media message round-trips with thumbnail', () {
      final e = Envelope.media(
        conv: 'c1',
        from: 'yuriko@localhost',
        type: MessageType.image,
        caption: 'look',
        media: const MediaRef(
          hash: _hash,
          size: 1234,
          mime: 'image/jpeg',
          name: 'cat.jpg',
          width: 800,
          height: 600,
          thumb: MediaRef(hash: _hash, size: 99, mime: 'image/jpeg'),
        ),
      );
      final back = _roundTrip(e);
      final media = back.media!;
      expect(media.width, 800);
      expect(media.thumb!.size, 99);
      expect(back.text, 'look');
      expect(back.preview, '[Photo] look');
      // Audio goes as a file.
      final song = Envelope.media(
        conv: 'c1',
        from: 'yuriko@localhost',
        type: MessageType.file,
        media: const MediaRef(hash: _hash, size: 9, mime: 'audio/mpeg', name: 'song.mp3', durationMs: 204000),
      );
      expect((_roundTrip(song).media!.durationMs, song.preview), (204000, '[Audio] song.mp3'));
    });

    test('GIFs: an uploaded file, or one KLIPY serves from its own hosts only', () {
      const klipy = RemoteMedia(
        provider: RemoteMedia.klipy,
        id: 'happy-dance',
        url: 'https://static.klipy.com/ii/abc/md.webp',
        mime: 'image/webp',
        width: 360,
        height: 270,
        title: 'Happy dance',
      );
      final remote = _roundTrip(Envelope.gif(conv: 'c', from: 'a@b', gif: const GifRef.remote(klipy)));
      expect(remote.messageType, MessageType.gif);
      expect((remote.gif!.remote!.url, remote.gif!.width, remote.gif!.key), (klipy.url, 360, 'klipy:happy-dance'));
      expect((remote.media, remote.preview), (null, '[GIF]'));

      const file = MediaRef(hash: _hash, size: 5000, mime: 'image/gif', width: 100, height: 80, key: 'a2V5');
      final uploaded = _roundTrip(Envelope.gif(
        conv: 'c',
        from: 'a@b',
        gif: const GifRef.media(file),
        replyTo: ReplyRef(id: newUlid(), from: 'x@y'),
      ));
      expect((uploaded.gif!.media!.hash, uploaded.gif!.key, uploaded.media!.key), (_hash, _hash, 'a2V5'));
      expect(uploaded.replyTo, isNotNull);

      Map<String, Object?> gif(Map<String, Object?> body) => remote.toJson()..['body'] = body;
      Map<String, Object?> klipyWith(String key, Object? value) => {'remote': {...klipy.toJson(), key: value}};
      for (final body in [
        <String, Object?>{},
        {...const GifRef.media(file).toJson(), ...const GifRef.remote(klipy).toJson()},
        klipyWith('url', 'http://static.klipy.com/a.webp'),
        klipyWith('url', 'https://evil.example/static.klipy.com/a.webp'),
        klipyWith('url', 'https://klipy.com.evil.example/a.webp'),
        klipyWith('url', 'https://user@static.klipy.com/a.webp'),
        klipyWith('provider', 'giphy'),
        klipyWith('mime', 'text/html'),
        klipyWith('w', 0),
      ]) {
        expect(() => Envelope.fromJson(gif(body)), throwsFormatException, reason: '$body');
      }
    });

    test('stickers: sent as their picture, neither a bubble nor a card; named only on the own devices', () {
      const file = MediaRef(hash: _hash, size: 30000, mime: 'image/png', width: 512, height: 512, key: 'a2V5');
      final own = _roundTrip(Envelope.sticker(
        conv: 'c',
        from: 'a@b',
        sticker: const StickerRef.media(file),
        replyTo: ReplyRef(id: newUlid(), from: 'x@y'),
      ));
      expect(own.messageType, MessageType.sticker);
      expect((own.sticker!.isNamed, own.sticker!.key, own.sticker!.media!.key), (false, _hash, 'a2V5'));
      expect((own.sticker!.source, own.sticker!.packSticker), (null, null));
      expect(own.sticker, const StickerRef.media(file));
      expect((own.preview, own.replyTo != null), ('[Sticker]', true));
      expect(MessageType.sticker.isMedia, isFalse, reason: 'shown by itself, not on a card');

      // Named: in the picker, or kept while its pack is not there; never sent.
      final named = StickerRef.fromJson(const StickerRef.named(pack: 'test-pack', id: '07').toJson());
      expect((named.pack, named.id, named.key), ('test-pack', '07', 'test-pack:07'));
      expect((named.isNamed, named.packSticker), (true, (pack: 'test-pack', id: '07')));

      Map<String, Object?> sticker(Map<String, Object?> body) => own.toJson()..['body'] = body;
      for (final body in [
        <String, Object?>{},
        const StickerRef.named(pack: 'test-pack', id: '07').toJson(),
        {'pack': 'p'},
        {'pack': 'p', 'id': '../../secrets'},
        // Never both.
        {'pack': 'p', 'id': '01', ...const StickerRef.media(file).toJson()},
        {'pack': 'p', 'id': '01', 'media': file.toJson(), 'from': {'pack': 'p', 'id': '01'}},
      ]) {
        expect(() => Envelope.fromJson(sticker(body)), throwsFormatException, reason: '$body');
      }
      for (final json in [
        {'pack': 'p', 'id': ''},
        {'pack': 'p', 'id': 'x' * 65},
        {'pack': 'p', 'id': 7},
      ]) {
        expect(() => StickerRef.fromJson(json), throwsFormatException, reason: '$json');
      }
    });

    test("a pack's sticker goes as its picture, with the pack beside it; a bad pack never fails the message", () {
      const picture = MediaRef(hash: _hash, size: 30000, mime: 'image/webp', width: 512, height: 512, key: 'a2V5');
      const archive = MediaRef(
        hash: 'sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        size: 600000,
        mime: 'application/zip',
        key: 'cGFjaw==',
        host: 'a.example',
      );
      const source = StickerSource(pack: 'test-pack', id: '07', title: 'Test pack', archive: archive);
      final sent = _roundTrip(Envelope.sticker(
        conv: 'c',
        from: 'a@b',
        sticker: const StickerRef.media(picture, source: source),
        replyTo: ReplyRef(id: newUlid(), from: 'x@y'),
      ));
      expect(sent.body.keys.toSet(), {'media', 'from', 'replyTo'});
      final sticker = sent.sticker!;
      expect((sticker.media!.hash, sticker.isNamed), (_hash, false));
      final from = sticker.source!;
      expect((from.pack, from.id, from.title, from.archive!.hash, from.archive!.host),
          ('test-pack', '07', 'Test pack', archive.hash, 'a.example'));
      // The same sticker as named, whoever uploaded its picture.
      expect((sticker.key, sticker.packSticker), ('test-pack:07', (pack: 'test-pack', id: '07')));
      expect(sticker, const StickerRef.named(pack: 'test-pack', id: '07'));
      final other = MediaRef(hash: 'sha256:${'2' * 64}', size: 1, mime: 'image/webp', key: 'a2V5');
      expect(StickerRef.media(other, source: source), sticker);

      StickerRef withFrom(Object? from) =>
          Envelope.fromJson(sent.toJson()..['body'] = {'media': picture.toJson(), 'from': from}).sticker!;
      expect(withFrom('a pack').source, isNull);
      expect(withFrom(<String, Object?>{'pack': 'test-pack'}).source, isNull);
      expect(withFrom(<String, Object?>{'pack': 'test-pack', 'id': '../x'}).source, isNull);
      expect(withFrom(<String, Object?>{'pack': 'test-pack', 'id': '07', 'title': 'x' * 65}).source!.title, isNull);
      expect(withFrom(<String, Object?>{'pack': 'test-pack', 'id': '07', 'title': '  '}).source!.title, isNull);
      expect(withFrom(<String, Object?>{'pack': 'test-pack', 'id': '07', 'archive': 'a file'}).source!.archive, isNull);
      final broken = withFrom(<String, Object?>{
        'pack': 'test-pack',
        'id': '07',
        'archive': {'hash': 'md5:x', 'size': 1, 'mime': 'application/zip'},
      });
      expect((broken.source!.pack, broken.source!.archive, broken.media!.hash), ('test-pack', null, _hash));
      // What later versions add to it stays, as saved stickers keep it.
      final later = withFrom(<String, Object?>{'pack': 'test-pack', 'id': '07', 'emoji': '👋', 'title': 'Test pack'});
      expect(later.toJson()['from'], {'emoji': '👋', 'pack': 'test-pack', 'id': '07', 'title': 'Test pack'});
      expect(source.withPack(title: 'Renamed', archive: picture).toJson(),
          {'pack': 'test-pack', 'id': '07', 'title': 'Renamed', 'archive': picture.toJson()});
    });

    test('custom emojis: text, captions and edits carry the pictures their :names: show', () {
      const cat = MediaRef(
        hash: _hash,
        size: 900,
        mime: 'image/png',
        width: 128,
        height: 96,
        key: 'a2V5',
        host: 'example.org',
      );
      // Not in times, nor in capitals, nor too short.
      List<String> found(String text, [Set<String>? has]) => [
        for (final at in CustomEmoji.find(text, has?.contains ?? (_) => true)) at.name,
      ];
      expect(found('Good :cat: :kumiko_happy::cat: at 12:30 :x: :Cat: ::'), ['cat', 'kumiko_happy', 'cat']);
      // Two do not share a colon; one there is none of does not take it.
      expect(found(':cat:dog:'), ['cat']);
      expect(found(':foo:cat:', {'cat'}), ['cat']);
      expect(CustomEmoji.find('Hi :cat:!', (_) => true).single, (start: 3, end: 8, name: 'cat'));

      final text = _roundTrip(Envelope.text(conv: 'c', from: 'a@b', text: 'Hi :cat:', emojis: const {'cat': cat}));
      final got = text.emojis['cat']!;
      expect((text.emojis.length, got.hash, got.key, got.host, got.width), (1, _hash, 'a2V5', 'example.org', 128));
      expect(
        Envelope.text(conv: 'c', from: 'a@b', text: 'Hi').body.containsKey('emojis'),
        isFalse,
        reason: 'none: left out',
      );
      final caption = _roundTrip(
        Envelope.media(
          conv: 'c',
          from: 'a@b',
          type: MessageType.image,
          media: cat,
          caption: ':cat:',
          emojis: const {'cat': cat},
        ),
      );
      expect(caption.emojis.keys, ['cat']);
      final edit = _roundTrip(
        Envelope.edit(conv: 'c', from: 'a@b', target: newUlid(), text: ':cat:', emojis: const {'cat': cat}),
      );
      expect((edit.isHidden, edit.emojis.keys.single), (true, 'cat'));

      // Malformed ones are left out, and the message still shows.
      final odd = _roundTrip(
        text.withBody({
          ...text.body,
          'emojis': {
            'cat': cat.toJson(),
            'Cat': cat.toJson(),
            'x': cat.toJson(),
            'doc': {...cat.toJson(), 'mime': 'application/pdf'},
            'dog': {'hash': 'nope'},
            'owl': 7,
          },
        }),
      );
      expect((odd.text, odd.emojis.keys.join()), ('Hi :cat:', 'cat'));
      expect(_roundTrip(text.withBody({...text.body, 'emojis': 'cat'})).emojis, isEmpty);

      // Taken into a set, a picture keeps only what showing it needs.
      final named = MediaRef(
        hash: _hash,
        size: 900,
        mime: 'image/png',
        name: 'cat.png',
        width: 128,
        height: 96,
        key: 'a2V5',
        thumb: cat,
      );
      expect(CustomEmoji.picture(named).toJson(), {
        'hash': _hash,
        'size': 900,
        'mime': 'image/png',
        'w': 128,
        'h': 96,
        'key': 'a2V5',
      });
    });
    test('text messages carry a preview of a link in their text', () {
      const thumb = MediaRef(hash: _hash, size: 900, mime: 'image/jpeg', width: 480, height: 360, key: 'a2V5');
      const preview = LinkPreview(
        url: 'https://www.youtube.com/watch?v=abc',
        kind: LinkKind.video,
        title: 'A video',
        description: 'A channel',
        site: 'YouTube',
        thumb: thumb,
      );
      final e = _roundTrip(
        Envelope.text(conv: 'c', from: 'a@b', text: 'Look www.youtube.com/watch?v=abc!', link: preview),
      );
      final link = e.link!;
      expect(
        (link.url, link.kind, link.title, link.description, link.site),
        (preview.url, LinkKind.video, 'A video', 'A channel', 'YouTube'),
      );
      expect((link.thumb!.key, link.mime, link.size), ('a2V5', null, null));
      expect(e.preview, 'Look www.youtube.com/watch?v=abc!');

      const file = LinkPreview(
        url: 'https://example.com/a.pdf',
        kind: LinkKind.file,
        title: 'a.pdf',
        mime: 'application/pdf',
        size: 2400,
      );
      final pdf = _roundTrip(Envelope.text(conv: 'c', from: 'a@b', text: file.url, link: file)).link!;
      expect((pdf.kind, pdf.title, pdf.mime, pdf.size), (LinkKind.file, 'a.pdf', 'application/pdf', 2400));
      expect(pdf.thumb, isNull);

      const video = MediaRef(hash: _hash, size: 4000000, mime: 'video/mp4', width: 1280, height: 720, durationMs: 9000);
      const tweet = LinkPreview(
        url: 'https://fxtwitter.com/a/status/1',
        kind: LinkKind.gif,
        site: 'FxTwitter',
        thumb: thumb,
        media: video,
        color: '#6363ff',
      );
      final gif = _roundTrip(Envelope.text(conv: 'c', from: 'a@b', text: tweet.url, link: tweet)).link!;
      expect((gif.kind, gif.media!.mime, gif.media!.durationMs, gif.color), (LinkKind.gif, 'video/mp4', 9000, '#6363ff'));

      Map<String, Object?> withLink(String text, Object? link) => e.toJson()..['body'] = {'text': text, 'link': link};
      // Nothing to play, or no colour: left out.
      final odd = Envelope.fromJson(
        withLink(tweet.url, {
          ...tweet.toJson(),
          'media': {...video.toJson(), 'mime': 'application/pdf'},
          'color': 'red; background: url(x)',
        }),
      ).link!;
      expect((odd.media, odd.color, odd.thumb!.hash), (null, null, _hash));

      // Where the site has it, for those who choose to load it from there.
      const big = LinkPreview(
        url: 'https://fxtwitter.com/a/status/2',
        kind: LinkKind.video,
        thumb: thumb,
        source: LinkSource(
          url: 'https://video.example/v.mp4',
          mime: 'video/mp4',
          width: 1280,
          height: 720,
          durationMs: 600000,
        ),
      );
      final source = _roundTrip(Envelope.text(conv: 'c', from: 'a@b', text: big.url, link: big)).link!.source!;
      expect(
        (source.url, source.mime, source.width, source.height, source.durationMs),
        ('https://video.example/v.mp4', 'video/mp4', 1280, 720, 600000),
      );
      // Anything else is left out, and the preview stays.
      for (final bad in [
        'https://video.example/v.mp4',
        {'url': 'http://video.example/v.mp4', 'mime': 'video/mp4'},
        {'url': 'https://user@video.example/v.mp4', 'mime': 'video/mp4'},
        {'url': 'https://video.example/v.mp4', 'mime': 'text/html'},
        {'url': 'https://video.example/v.mp4'},
      ]) {
        final link = Envelope.fromJson(withLink(big.url, {...big.toJson(), 'source': bad})).link!;
        expect((link.source, link.thumb!.hash), (null, _hash), reason: '$bad');
      }
      final odd2 = LinkSource.tryParse({'url': 'https://video.example/v.mp4', 'mime': 'video/mp4', 'w': -5, 'h': '7'})!;
      expect((odd2.width, odd2.height), (null, null));
      // Not (or no longer, after an edit) an address in the text: left out.
      expect(Envelope.fromJson(withLink('Look', preview.toJson())).link, isNull);
      expect(Envelope.fromJson(withLink('https://evil.example/', preview.toJson())).link, isNull);
      // Kinds from later versions show as pages.
      final poll = Envelope.fromJson(withLink('https://a.example/', {'url': 'https://a.example/', 'kind': 'poll'}));
      expect(poll.link!.kind, LinkKind.page);
      for (final link in [
        'https://a.example/',
        <String, Object?>{},
        {'url': 'javascript:alert(1)'},
        {'url': 'file:///etc/passwd'},
        {'url': 'https://a.example/', 'title': 5},
        {'url': 'https://a.example/', 'size': -1},
        {
          'url': 'https://a.example/',
          'thumb': {'hash': 'nope'},
        },
        {
          'url': 'https://a.example/',
          'media': {'hash': 'nope'},
        },
      ]) {
        expect(() => Envelope.fromJson(withLink('https://a.example/', link)), throwsFormatException, reason: '$link');
      }
    });

    test('unknown future types are preserved', () {
      final json = Envelope.text(conv: 'c', from: 'a@b', text: 'x').toJson()
        ..['type'] = 'poll'
        ..['body'] = {'question': '?'};
      final e = Envelope.fromJson(json);
      expect(e.messageType, isNull);
      expect(e.toJson()['body'], {'question': '?'});
    });

    test('replies carry a quote and survive a round trip', () {
      final original = Envelope.text(conv: 'c', from: 'yuriko@localhost', text: 'Hi');
      final reply = _roundTrip(Envelope.text(
        conv: 'c',
        from: 'noa@localhost',
        text: 'Hello',
        replyTo: ReplyRef(id: original.id, from: original.from, text: original.preview),
      ));
      expect((reply.replyTo!.id, reply.replyTo!.from, reply.replyTo!.text), (original.id, 'yuriko@localhost', 'Hi'));
      expect(reply.isHidden, isFalse);
      expect(() => Envelope.fromJson(reply.toJson()..['body'] = {'text': 'x', 'replyTo': {'id': 'nope', 'from': 'a@b'}}),
          throwsFormatException);
    });

    test('reactions, edits and deletions are hidden and point at their target', () {
      final target = newUlid();
      final reaction = _roundTrip(Envelope.reaction(conv: 'c', from: 'a@b', target: target, emoji: '👍'));
      expect((reaction.isHidden, reaction.target, reaction.emoji, reaction.preview), (true, target, '👍', 'Reacted 👍'));
      final removed = _roundTrip(Envelope.reaction(conv: 'c', from: 'a@b', target: target, emoji: '👍', remove: true));
      expect((removed.emoji, removed.removesReaction, removed.preview), ('👍', true, 'Removed a reaction'));
      expect(reaction.removesReaction, isFalse);
      // A reaction always says which.
      expect(() => Envelope.fromJson(reaction.toJson()..['body'] = {'target': target, 'emoji': null}), throwsFormatException);
      expect(() => Envelope.fromJson(reaction.toJson()..['body'] = {'target': target}), throwsFormatException);
      final edit = _roundTrip(Envelope.edit(conv: 'c', from: 'a@b', target: target, text: 'fixed'));
      expect((edit.target, edit.text), (target, 'fixed'));
      expect(_roundTrip(Envelope.delete(conv: 'c', from: 'a@b', target: target)).target, target);

      // The history shared with someone just added: its keys come when it is sent.
      const keys = MediaRef(hash: _hash, size: 900, mime: 'application/json', key: 'a2V5');
      final queued = _roundTrip(Envelope.history(conv: 'c', from: 'a@b', user: 'n@b'));
      expect((queued.isHidden, queued.target, queued.sharedWith, queued.historyKeys), (true, null, 'n@b', null));
      final shared = _roundTrip(Envelope.history(conv: 'c', from: 'a@b', user: 'n@b', keys: keys));
      expect((shared.historyKeys!.key, shared.preview), ('a2V5', 'Shared the chat history'));
    });

    test('rejects malformed reactions, edits and control messages', () {
      final target = newUlid();
      Map<String, Object?> of(String type, Map<String, Object?> body) =>
          Envelope.text(conv: 'c', from: 'a@b', text: 'x').toJson()
            ..['type'] = type
            ..['body'] = body;
      for (final (type, body) in [
        (Envelope.reactionType, {'target': 'nope', 'emoji': '👍'}),
        (Envelope.reactionType, {'target': target, 'emoji': ''}),
        (Envelope.reactionType, {'target': target, 'emoji': 'x' * 65}),
        (Envelope.reactionType, {'target': target, 'emoji': '👍', 'remove': 'yes'}),
        (Envelope.editType, {'target': target, 'text': '  '}),
        (Envelope.deleteType, <String, Object?>{}),
        (Envelope.profileKeyType, <String, Object?>{}),
        (Envelope.profileKeyType, {'key': ''}),
        (Envelope.historyType, <String, Object?>{}),
        (Envelope.historyType, {'user': 'nope'}),
        (Envelope.historyType, {'user': 'n@b', 'keys': {'hash': 'nope'}}),
      ]) {
        expect(() => Envelope.fromJson(of(type, body)), throwsFormatException, reason: '$type $body');
      }
    });

    test('rejects malformed envelopes', () {
      Map<String, Object?> valid() =>
          Envelope.text(conv: 'c', from: 'a@b', text: 'x').toJson();
      expect(() => Envelope.fromJson(valid()..['id'] = 'nope'), throwsFormatException);
      expect(() => Envelope.fromJson(valid()..['from'] = 'nope'), throwsFormatException);
      expect(() => Envelope.fromJson(valid()..['body'] = {'text': 5}), throwsFormatException);
      expect(
        () => Envelope.fromJson(valid()
          ..['type'] = 'image'
          ..['body'] = {'media': {'hash': 'md5:x', 'size': 1, 'mime': 'a/b'}}),
        throwsFormatException,
      );
      expect(
        () => Envelope.fromJson(valid()..['body'] = {'text': 'x' * (Envelope.maxBodyBytes + 1)}),
        throwsFormatException,
      );
    });
  });

  group('documents', () {
    const avatar = MediaRef(hash: _hash, size: 10, mime: 'image/jpeg', key: 'a2V5');

    test('a profile keeps what later versions add', () {
      final json = <String, Object?>{'displayName': 'Kumiko', 'avatar': avatar.toJson(), 'pronouns': 'she/her'};
      final document = ProfileDocument.fromJson(json);
      expect((document.displayName, document.avatar!.key, document.card, document.extra['pronouns']),
          ('Kumiko', 'a2V5', null, 'she/her'));
      expect(document.toJson(), json);
      expect(const ProfileDocument().toJson(), isEmpty);
      for (final bad in [
        {'displayName': ''},
        {'displayName': 5},
        {'displayName': 'x' * 65},
        {'avatar': {'hash': 'nope'}},
      ]) {
        expect(() => ProfileDocument.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('a group keeps what later versions add, and always has its salt', () {
      final json = <String, Object?>{'salt': 'c2FsdA==', 'title': 'Club', 'picture': avatar.toJson(), 'rules': 'none'};
      final document = GroupDocument.fromJson(json);
      expect((document.salt, document.title, document.picture!.key, document.extra['rules']),
          ('c2FsdA==', 'Club', 'a2V5', 'none'));
      expect(document.toJson(), json);
      final described = GroupDocument.fromJson({...json, 'description': 'After school.\nBring snacks.'});
      expect((described.description, described.toJson()['description']), ('After school.\nBring snacks.', 'After school.\nBring snacks.'));
      // A malformed description is left out, not the group.
      for (final description in [5, ' ', 'x' * 501]) {
        expect(GroupDocument.fromJson({...json, 'description': description}).description, isNull, reason: '$description');
      }
      for (final bad in [
        <String, Object?>{},
        {'salt': ''},
        {'salt': 's', 'title': ' '},
        {'salt': 's', 'title': 'x' * 65},
        {'salt': 's', 'picture': {'hash': 'nope'}},
      ]) {
        expect(() => GroupDocument.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });

    test("a group's emojis are in its document; malformed ones are left out, not the group", () {
      const cat = MediaRef(hash: _hash, size: 900, mime: 'image/png', width: 128, height: 128, key: 'a2V5');
      final json = <String, Object?>{
        'salt': 'c2FsdA==',
        'title': 'Club',
        'emojis': {'cat': cat.toJson()},
        'rules': 'none',
      };
      final document = GroupDocument.fromJson(json);
      expect(
        (document.emojis.keys.join(), document.emojis['cat']!.key, document.extra['rules']),
        ('cat', 'a2V5', 'none'),
      );
      expect(document.toJson(), json);
      final odd = GroupDocument.fromJson({
        ...json,
        'emojis': {'cat': cat.toJson(), 'Bad name': cat.toJson(), 'dog': 5},
      });
      expect((odd.title, odd.emojis.keys.join()), ('Club', 'cat'));
      expect(GroupDocument.fromJson({'salt': 's', 'emojis': []}).emojis, isEmpty);
      expect(const GroupDocument(salt: 's').toJson(), {'salt': 's'}, reason: 'none: left out');
    });
    test('names and titles count in characters, as the server did', () {
      final emoji = '😀' * 64;
      expect(ProfileDocument.fromJson({'displayName': emoji}).displayName, emoji);
      expect(GroupDocument.fromJson({'salt': 's', 'title': emoji}).title, emoji);
      expect(() => GroupDocument.fromJson({'salt': 's', 'title': '$emoji!'}), throwsFormatException);
    });

    test('a control message carries a profile key', () {
      final message = _roundTrip(Envelope.profileKey(conv: 'c', from: 'a@b', key: 'a2V5'));
      expect((message.profileKey, message.isHidden), ('a2V5', false));
    });
  });

  group('ProfileCard', () {
    test('round-trips, keeping the fields of later versions', () {
      final card = ProfileCard.fromJson({
        'statusMessage': '  Only the best for you!  ',
        'birthday': {'month': 3, 'day': 24},
        'bio': ' Gunslinger.\nLikes sweets. ',
        'pronouns': 'from a later version',
      });
      expect(
        (card.statusMessage, card.bio, card.birthday, card.isEmpty),
        ('Only the best for you!', 'Gunslinger.\nLikes sweets.', const Birthday(3, 24), false),
      );
      final edited = card.edit(statusMessage: ' ', bio: card.bio, birthday: const Birthday(2, 29));
      expect(edited.toJson(), {
        'pronouns': 'from a later version',
        'bio': 'Gunslinger.\nLikes sweets.',
        'birthday': {'month': 2, 'day': 29},
      });
      expect(card.edit(statusMessage: null, bio: '\n', birthday: null).toJson(), {'pronouns': 'from a later version'});
      expect(ProfileCard.fromJson(edited.toJson()), edited);
      expect(ProfileCard.fromJson(const {}).isEmpty, isTrue);
    });

    test('leaves out malformed fields, not the whole card', () {
      for (final birthday in [
        {'month': 2, 'day': 30},
        {'month': 4, 'day': 31},
        {'month': 13, 'day': 1},
        {'month': '3', 'day': 24},
        '03-24',
      ]) {
        final card = ProfileCard.fromJson({'statusMessage': 'hi', 'birthday': birthday});
        expect((card.statusMessage, card.birthday), ('hi', null), reason: '$birthday');
      }
      expect(ProfileCard.fromJson({'statusMessage': 5}).statusMessage, isNull);
      expect(ProfileCard.fromJson({'bio': ['no']}).bio, isNull);
    });

    test('presence from the wire; unknown values are safe', () {
      expect((Presence.parse('focus'), Presence.parse('away'), PresenceMode.parse('invisible'), PresenceMode.parse(null)),
          (Presence.focus, Presence.offline, PresenceMode.invisible, PresenceMode.auto));
    });
  });

  group('ChatSettings', () {
    test('round-trips, keeping the fields of later versions, leaving out malformed ones', () {
      final settings = ChatSettings.fromJson({'notify': 'replies', 'mutedUntil': 2000, 'sound': false, 'pinned': true});
      expect((settings.notify, settings.mutedUntil, settings.sound), (ChatNotify.replies, 2000, false));
      expect(ChatSettings.fromJson(settings.toJson()), settings);
      final cleared = settings.edit(notify: null, mutedUntil: null, sound: null);
      expect(cleared.toJson(), {'pinned': true});
      expect(cleared.isEmpty, isFalse);
      expect(ChatSettings.fromJson({'notify': 'loud', 'mutedUntil': 'soon', 'sound': 1}).isEmpty, isTrue);
    });

    test('muted for good, or until a time', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1000);
      expect(ChatSettings.empty.mutedAt(at), isFalse);
      expect(const ChatSettings(notify: ChatNotify.off).mutedAt(at), isTrue);
      expect(const ChatSettings(mutedUntil: 1001).mutedAt(at), isTrue);
      expect(const ChatSettings(mutedUntil: 1000).mutedAt(at), isFalse);
    });
  });

  group('calls', () {
    test("a call message is a call's place in the chat: its ID, nothing more", () {
      final id = newUlid();
      final message = _roundTrip(Envelope.call(conv: 'c', from: 'a@b', call: id));
      expect((message.messageType, message.callId, message.preview), (MessageType.call, id, '[Voice call]'));
      expect(MessageType.call.isMedia, isFalse, reason: 'not on a card with a file');
      expect([for (final t in MessageType.values) if (t.isMedia) t.name], ['image', 'video', 'file', 'gif']);
      for (final body in [<String, Object?>{}, {'call': 'not-a-ulid'}, {'call': 5}]) {
        expect(() => Envelope.fromJson(message.toJson()..['body'] = body), throwsFormatException, reason: '$body');
      }
    });

    test('a call as the server tells of it', () {
      final json = <String, Object?>{
        'id': newUlid(),
        'conv': 'c',
        'direct': true,
        'startedBy': 'a@b',
        'startedDevice': '01HZXQ8Z7K3V5M2N4P6R8T0W9Y',
        'startedAt': 1000,
        'ringUntil': 46000,
        'endedAt': 5000,
        'reason': 'a reason of a later version',
        'version': 3,
        'participants': [
          {'user': 'a@b', 'device': '01HZXQ8Z7K3V5M2N4P6R8T0W9Y', 'joinedAt': 1500},
        ],
      };
      final call = Call.fromJson(json);
      expect((call.direct, call.ringUntil!.millisecondsSinceEpoch, call.active, call.unanswered, call.version), (true, 46000, false, false, 3));
      expect(call.users, {'a@b'});
      expect(call.toJson(), json);
      for (final bad in [
        {...json, 'id': 'x'},
        {...json}..remove('startedAt'),
        {...json, 'endedAt': 'soon'},
        {...json, 'participants': [{'user': 'a@b'}]},
      ]) {
        expect(() => Call.fromJson(bad), throwsFormatException, reason: '$bad');
      }
      final join = CallJoin.fromJson({'call': json, 'livekit': {'url': 'wss://lk.example.org', 'token': 'jwt'}});
      expect((join.url, join.token, join.call.id), ('wss://lk.example.org', 'jwt', json['id']));
      expect(() => CallJoin.fromJson({'call': json}), throwsFormatException);
      expect((Integrations.fromJson({'calls': true}).calls, Integrations.fromJson({}).calls), (true, false));
      final video = Integrations.fromJson({'calls': true, 'video': true});
      expect((video.video, Integrations.fromJson({'calls': true}).video), (true, false));
      expect(video.toJson(), {'calls': true, 'video': true});
    });

    test('a video call says so; one that does not is a voice call', () {
      final json = <String, Object?>{
        'id': newUlid(),
        'conv': 'c',
        'direct': true,
        'video': true,
        'startedBy': 'a@b',
        'startedDevice': '01HZXQ8Z7K3V5M2N4P6R8T0W9Y',
        'startedAt': 1000,
        'version': 1,
        'participants': <Object?>[],
      };
      final call = Call.fromJson(json);
      expect((call.video, Call.fromJson({...json}..remove('video')).video), (true, false));
      expect(call.toJson(), json);
    });
  });
}
