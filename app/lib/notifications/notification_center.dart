import 'dart:async';
import 'dart:io';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../data/local/database.dart';
import '../ui/theme/hanashi_theme.dart' show appTitle;
import '../data/models.dart';

/// One conversation's notification.
class ChatNotification {
  const ChatNotification({
    required this.conversationId,
    required this.title,
    required this.isGroup,
    required this.lines,
    required this.unread,
    this.audible = true,
  });

  final String conversationId;

  /// The group's title, or the other person's name. "Hanashi" when
  /// previews are off.
  final String title;
  final bool isGroup;

  /// The latest unread messages, oldest first; empty when previews are off.
  final List<NotificationLine> lines;

  /// How many messages it stands for.
  final int unread;

  /// With a sound; otherwise it only shows.
  final bool audible;
}

class NotificationLine {
  const NotificationLine({required this.sender, required this.text, required this.time, this.picture});

  final String sender;
  final String text;
  final DateTime time;

  /// The sender's profile picture, decrypted on this device (a file path).
  final String? picture;
}

/// What a contact notification tells.
enum ContactNotice {
  /// They ask to become the user's contact.
  request,

  /// They accepted the user's request.
  accepted,
}

/// A notification about one person: their request, or their answer to the
/// user's. At most one shows per person.
class ContactNotification {
  const ContactNotification({
    required this.userId,
    required this.notice,
    required this.title,
    required this.body,
    this.audible = true,
  });

  final String userId;
  final ContactNotice notice;
  final String title;
  final String body;
  final bool audible;
}

/// A notification the user opened the app with: what it is about (a
/// conversation ID, a route such as `/contacts`, or `call:<id>`), and the
/// action of it that was tapped, if one was.
class NotificationOpen {
  const NotificationOpen(this.target, {this.action});

  final String target;
  final String? action;
}

/// Shows notifications on the platform; an interface so tests can record them.
abstract interface class NotificationDisplay {
  /// Shows or replaces the conversation's notification, alerting the user.
  Future<void> show(ChatNotification notification);

  Future<void> cancel(String conversationId);

  /// Shows or replaces the notification about [ContactNotification.userId].
  Future<void> showContact(ContactNotification notification);

  Future<void> cancelContact(String userId);

  /// Removes every notification, e.g. when signing out.
  Future<void> cancelAll();

  /// Asks for permission where the platform requires it; false if refused.
  Future<bool> requestPermission();
}

/// What a notification is about, for choosing which notify and how.
enum NotifyKind {
  direct,
  group,

  /// Replies to the user in a group.
  replies,

  /// Reactions to the user's messages.
  reactions,

  /// Contact requests to the user, and answers to theirs.
  requests,
}

/// How one [NotifyKind] notifies.
enum NotifyStyle { off, silent, sound }

/// The user's notification settings on this device, kept in the local
/// database. (Per-chat settings are the account's: see [ChatSettings].)
class NotificationPreferences {
  const NotificationPreferences({this.enabled = true, this.preview = true, this.styles = const {}});

  static const _enabledKey = 'notify.enabled';
  static const _previewKey = 'notify.preview';
  static const _stylePrefix = 'notify.style.';

  final bool enabled;

  /// Show who wrote and what; off, only "New message".
  final bool preview;

  /// How each kind notifies; those missing, with a sound.
  final Map<NotifyKind, NotifyStyle> styles;

  NotifyStyle styleOf(NotifyKind kind) => styles[kind] ?? NotifyStyle.sound;

  NotificationPreferences copyWith({bool? enabled, bool? preview, Map<NotifyKind, NotifyStyle>? styles}) =>
      NotificationPreferences(
        enabled: enabled ?? this.enabled,
        preview: preview ?? this.preview,
        styles: styles ?? this.styles,
      );

  /// These preferences with [kind] notifying as [style].
  NotificationPreferences withStyle(NotifyKind kind, NotifyStyle style) => copyWith(styles: {...styles, kind: style});

  static Future<NotificationPreferences> load(AppDatabase db) async {
    final stored = await db.valuesWithPrefix(_stylePrefix);
    return NotificationPreferences(
      enabled: await db.getValue(_enabledKey) != 'false',
      preview: await db.getValue(_previewKey) != 'false',
      styles: {
        for (final kind in NotifyKind.values)
          kind: ?NotifyStyle.values.where((s) => s.name == stored['$_stylePrefix${kind.name}']).firstOrNull,
      },
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setValue(_enabledKey, enabled ? null : 'false');
    await db.setValue(_previewKey, preview ? null : 'false');
    for (final kind in NotifyKind.values) {
      final style = styleOf(kind);
      await db.setValue('$_stylePrefix${kind.name}', style == NotifyStyle.sound ? null : style.name);
    }
  }
}

/// Keeps the platform's notifications in line with unread messages: one per
/// conversation that has messages from others the user has not read. It
/// alerts once per new message and removes a notification when the
/// conversation is read, here or on another device. Call [update] after
/// every sync; it reads everything it needs from the database, so it works
/// the same in the app and in a headless push engine.
///
/// What notifies, and with a sound or not, follows the chat's settings (see
/// [ChatSettings]) and then the [NotificationPreferences]. In Focus nothing
/// does: once it ends, what waited shows, without a sound.
class NotificationCenter {
  NotificationCenter({
    required this.db,
    required this.me,
    required this.notifier,
    bool Function()? appInForeground,
    DateTime Function()? clock,
    this.pictureFile,
    String Function()? appName,
  }) : _appInForeground = appInForeground ?? (() => false),
       _clock = clock ?? DateTime.now,
       _appName = appName ?? (() => appTitle);

  final AppDatabase db;
  final String me;
  final NotificationDisplay notifier;

  /// While the user is looking at the app, nothing pops up.
  final bool Function() _appInForeground;

  /// The name the app goes by in the theme shown: the title of notifications
  /// that keep what they are about private.
  final String Function() _appName;

  /// Whether a chat is still muted.
  final DateTime Function() _clock;

  /// A local copy of a profile picture, downloaded and decrypted if need be.
  final Future<File?> Function(MediaRef picture)? pictureFile;

  static const maxLines = 5;

  /// Messages up to this seq were there before notifications started; they
  /// never alert (e.g. the history a new device downloads).
  static const _baselineKey = 'notify.from';

  /// Per conversation: the newest seq already notified, negative while no
  /// notification shows for it (muted, say, or seen in the app).
  static const _notifiedPrefix = 'notify.conv.';

  /// Conversations whose notifications wait for Focus to end.
  static const _heldKey = 'notify.held';

  /// Per person asking: [_shown] while their request's notification shows,
  /// [_seen] once there is none to show (seen in the app, say).
  static const _requestPrefix = 'notify.request.';
  static const _shown = 'shown';
  static const _seen = 'seen';

  /// Those the user asked, as last seen: who of them accepts gets told.
  static const _askedKey = 'notify.asked';

  /// Who accepted, not told yet (in Focus, say).
  static const _acceptedKey = 'notify.accepted';

  /// People whose notification waits for Focus to end.
  static const _contactsHeldKey = 'notify.contacts.held';

  /// Set once the requests there were when notifications started were taken
  /// as seen: those never alert.
  static const _contactsStartedKey = 'notify.contacts.started';

  Future<void>? _running;
  var _again = false;

  /// Brings notifications up to date. Calls during a run are folded into
  /// one more run afterwards.
  Future<void> update() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = () async {
      try {
        do {
          _again = false;
          await _update();
        } while (_again);
      } finally {
        _running = null;
      }
    }();
  }

  Future<void> _update() async {
    final preferences = await NotificationPreferences.load(db);
    final chats = await db.chatSettings();
    final focus = await db.presenceMode() == PresenceMode.focus;
    final now = _clock();
    var baseline = int.tryParse(await db.getValue(_baselineKey) ?? '');
    if (baseline == null) {
      baseline = await db.cursor();
      await db.setValue(_baselineKey, '$baseline');
    }
    final names = await db.profileNames();
    String nameOf(String id) => names[id] ?? UserId.fallbackName(id, me: me);
    await _updateContacts(preferences, focus: focus, foreground: _appInForeground(), nameOf: nameOf);
    // What is new per conversation: messages from others, and their
    // reactions to the user's own messages.
    final unread = <String, List<_Item>>{};
    for (final MapEntry(key: conv, value: messages) in (await db.unreadIncoming(me, after: baseline)).entries) {
      for (final m in messages) {
        unread.putIfAbsent(conv, () => []).add((
          seq: m.seq!,
          sender: m.senderId,
          text: _text(m),
          time: m.sentAt,
          toMe: m.replyTo?.from == me,
          reaction: false,
          call: m.envelope.messageType == MessageType.call,
        ));
      }
    }
    for (final MapEntry(key: conv, value: reactions) in (await db.unreadReactions(me, after: baseline)).entries) {
      for (final r in reactions) {
        final quote = AppDatabase.quotePreview(r.target);
        unread.putIfAbsent(conv, () => []).add((
          seq: r.seq,
          sender: r.from,
          text: 'Reacted ${r.emoji} to "${quote.length > 40 ? '${quote.substring(0, 37)}...' : quote}"',
          time: r.time,
          toMe: true,
          reaction: true,
          call: false,
        ));
      }
    }
    for (final items in unread.values) {
      items.sort((a, b) => a.seq.compareTo(b.seq));
    }
    final notified = {
      for (final MapEntry(:key, :value) in (await db.valuesWithPrefix(_notifiedPrefix)).entries)
        key.substring(_notifiedPrefix.length): int.tryParse(value) ?? 0,
    };
    final held = {...?(await db.getValue(_heldKey))?.split(',').where((c) => c.isNotEmpty)};

    // Read meanwhile (or notifications turned off): remove.
    for (final conv in notified.keys) {
      if (!preferences.enabled || !unread.containsKey(conv)) {
        await notifier.cancel(conv);
        await db.setValue('$_notifiedPrefix$conv', null);
      }
    }
    held.removeWhere((conv) => !preferences.enabled || !unread.containsKey(conv));
    if (!preferences.enabled) return db.setValue(_heldKey, null);

    final foreground = _appInForeground();
    for (final MapEntry(key: conv, value: items) in unread.entries) {
      final conversation = await db.conversation(conv);
      if (conversation == null) continue;
      final chat = chats[conv] ?? ChatSettings.empty;
      final stored = notified[conv] ?? 0;
      final before = stored.abs();
      var showing = stored > 0;
      // What notifies, and whether with a sound.
      final shown = [
        for (final item in items)
          if (_alert(item, direct: conversation.isDirect, chat: chat, preferences: preferences, now: now)
              case final audible?)
            (item: item, audible: audible),
      ];
      final fresh = [for (final s in shown) if (s.item.seq > before) s];
      if (focus && !foreground) {
        // Not marked as notified: shown once Focus ends.
        if (fresh.isNotEmpty) held.add(conv);
        continue;
      }
      final waited = held.remove(conv);
      if (shown.isEmpty) {
        // Muted, or nothing in it notifies (any more).
        if (showing) await notifier.cancel(conv);
        showing = false;
      } else if (!foreground && (fresh.isNotEmpty || waited)) {
        await _show(conv, conversation, shown, preferences, nameOf, audible: !waited && fresh.any((s) => s.audible));
        showing = true;
      }
      // Notified, or seen arriving in the app: either way, not again.
      final marker = showing ? items.last.seq : -items.last.seq;
      if (marker != stored) await db.setValue('$_notifiedPrefix$conv', '$marker');
    }
    await db.setValue(_heldKey, held.isEmpty ? null : held.join(','));
  }

  Future<void> _show(
    String conv,
    ConversationRow conversation,
    List<({_Item item, bool audible})> shown,
    NotificationPreferences preferences,
    String Function(String id) nameOf, {
    required bool audible,
  }) async {
    final lines = [for (final s in shown) s.item];
    final pictures = <String, String?>{};
    final latest = lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
    // Only with previews: a picture shows who wrote.
    if (preferences.preview) {
      for (final m in latest) {
        if (!pictures.containsKey(m.sender)) pictures[m.sender] = await _picture(m.sender);
      }
    }
    await notifier.show(
        preferences.preview
            ? ChatNotification(
                conversationId: conv,
                title: conversation.title ?? nameOf(lines.last.sender),
                isGroup: !conversation.isDirect,
                unread: lines.length,
                lines: [
                  for (final m in latest)
                    NotificationLine(sender: nameOf(m.sender), text: m.text, time: m.time, picture: pictures[m.sender]),
                ],
                audible: audible,
              )
            : ChatNotification(
                conversationId: conv,
                title: _appName(),
                isGroup: false,
                unread: lines.length,
                lines: const [],
                audible: audible,
              ),
    );
  }

  /// Notifies requests to the user, one per person asking, until they are
  /// answered here or on another device; and that someone the user asked
  /// accepted. Who is a contact goes by the user's own list, as in the app.
  Future<void> _updateContacts(
    NotificationPreferences preferences, {
    required bool focus,
    required bool foreground,
    required String Function(String id) nameOf,
  }) async {
    final rows = await db.allContacts();
    final incoming = {
      for (final c in rows)
        if (c.state == ContactState.incoming) c.userId,
    };
    final contacts = {
      for (final c in rows)
        if (c.state == ContactState.accepted && c.trusted) c.userId,
    };
    final started = await db.getValue(_contactsStartedKey) != null;
    // Those asked who said yes since; no longer contacts, nothing to tell.
    final accepted = {
      ..._setOf(await db.getValue(_acceptedKey)),
      if (started) ..._setOf(await db.getValue(_askedKey)).intersection(contacts),
    }..retainAll(contacts);
    final markers = {
      for (final MapEntry(:key, :value) in (await db.valuesWithPrefix(_requestPrefix)).entries)
        key.substring(_requestPrefix.length): value,
    };
    final held = _setOf(await db.getValue(_contactsHeldKey))
      ..removeWhere((user) => !incoming.contains(user) && !accepted.contains(user));

    // Answered meanwhile, here or on another device: remove.
    for (final MapEntry(key: user, value: marker) in markers.entries) {
      if (incoming.contains(user)) continue;
      if (marker == _shown) await notifier.cancelContact(user);
      await db.setValue('$_requestPrefix$user', null);
    }
    final style = preferences.styleOf(NotifyKind.requests);
    final fresh = [
      for (final user in incoming)
        if (markers[user] == null) user,
    ];
    if (!started || !preferences.enabled || style == NotifyStyle.off) {
      // Those there from before, or none wanted: none show.
      for (final user in incoming) {
        if (markers[user] == _shown) await notifier.cancelContact(user);
        if (markers[user] != _seen) await db.setValue('$_requestPrefix$user', _seen);
      }
      accepted.clear();
      held.clear();
    } else if (focus && !foreground) {
      // Shown once Focus ends, without a sound.
      held.addAll([...fresh, ...accepted]);
    } else {
      ContactNotification notification(String user, ContactNotice notice) {
        final (title, body) = switch ((notice, preferences.preview)) {
          (ContactNotice.request, false) => (_appName(), 'New contact request'),
          (ContactNotice.accepted, false) => (_appName(), 'A contact request was accepted'),
          // A request carries no name: only the ID cannot be faked.
          (ContactNotice.request, true) => ('Contact request', '$user wants to be your contact'),
          (ContactNotice.accepted, true) => (nameOf(user), 'Accepted your contact request'),
        };
        final audible = !held.contains(user) && style == NotifyStyle.sound;
        return ContactNotification(userId: user, notice: notice, title: title, body: body, audible: audible);
      }

      for (final user in fresh) {
        if (!foreground) await notifier.showContact(notification(user, ContactNotice.request));
        await db.setValue('$_requestPrefix$user', foreground ? _seen : _shown);
      }
      for (final user in accepted) {
        if (!foreground) await notifier.showContact(notification(user, ContactNotice.accepted));
      }
      accepted.clear();
      held.clear();
    }
    await db.setValue(
      _askedKey,
      _joined({
        for (final c in rows)
          if (c.state == ContactState.outgoing) c.userId,
      }),
    );
    await db.setValue(_acceptedKey, _joined(accepted));
    await db.setValue(_contactsHeldKey, _joined(held));
    if (!started) await db.setValue(_contactsStartedKey, '1');
  }

  /// User IDs, which have no commas, as one value; null for none.
  static Set<String> _setOf(String? value) => {...?value?.split(',').where((user) => user.isNotEmpty)};
  static String? _joined(Set<String> users) => users.isEmpty ? null : users.join(',');

  /// [user]'s profile picture as a local file; null without one, or if it
  /// cannot be had now (offline, say): the notification shows without it.
  Future<String?> _picture(String user) async {
    final avatar = AppDatabase.mediaRefOf((await db.profileRow(user))?.avatar);
    final file = pictureFile;
    if (avatar == null || file == null) return null;
    try {
      return (await file(avatar))?.path;
    } on Object {
      return null;
    }
  }

  /// Whether [item] notifies, and if so, whether with a sound: per the chat's
  /// settings first, then the user's for its kind.
  static bool? _alert(
    _Item item, {
    required bool direct,
    required ChatSettings chat,
    required NotificationPreferences preferences,
    required DateTime now,
  }) {
    // A call of two rings instead.
    if (chat.mutedAt(now) || (direct && item.call)) return null;
    final style = preferences.styleOf(
      item.reaction
          ? NotifyKind.reactions
          : direct
          ? NotifyKind.direct
          : item.toMe
          ? NotifyKind.replies
          : NotifyKind.group,
    );
    switch (chat.notify) {
      case ChatNotify.replies when !item.toMe:
        return null;
      case null when style == NotifyStyle.off:
        return null;
      default:
        // Asked for in the chat, though off for its kind: with a sound.
        return chat.sound ?? style != NotifyStyle.silent;
    }
  }

  String _text(ChatMessage message) {
    if (message.envelope.type == Envelope.encryptedType) return 'New message';
    final preview = message.envelope.preview;
    return message.replyTo?.from == me ? 'Replied to you: $preview' : preview;
  }
}

/// One line of a notification, from a message or a reaction; [toMe] for
/// replies and reactions to the user.
typedef _Item = ({int seq, String sender, String text, DateTime time, bool toMe, bool reaction, bool call});
