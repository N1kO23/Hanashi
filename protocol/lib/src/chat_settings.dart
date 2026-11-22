import 'dart:convert';

/// What in a chat notifies.
enum ChatNotify {
  /// Every message.
  all,

  /// Only replies and reactions to the user.
  replies,

  /// Nothing: the chat is muted.
  off,
}

/// A user's settings for one chat, the same on all of their devices: they
/// keep them in their account data (`chats`). Every field is optional, and
/// later versions add fields; those this version does not know are kept, so
/// changing the settings here never drops them.
class ChatSettings {
  const ChatSettings({this.notify, this.mutedUntil, this.sound, this.extra = const {}});

  static const empty = ChatSettings();

  /// What in the chat notifies; null: as the device's settings say.
  final ChatNotify? notify;

  /// The chat is muted until then (milliseconds since the epoch).
  final int? mutedUntil;

  /// Whether its notifications make a sound; null: as the device's settings say.
  final bool? sound;

  /// Fields from later versions, kept as they came.
  final Map<String, Object?> extra;

  static const _known = {'notify', 'mutedUntil', 'sound'};

  bool get isEmpty => notify == null && mutedUntil == null && sound == null && extra.isEmpty;

  /// Muted for good, or until a time after [now].
  bool mutedAt(DateTime now) =>
      notify == ChatNotify.off || (mutedUntil != null && now.millisecondsSinceEpoch < mutedUntil!);

  /// A malformed field is left out, not the whole entry.
  factory ChatSettings.fromJson(Map<String, Object?> json) {
    final (notify, mutedUntil, sound) = (json['notify'], json['mutedUntil'], json['sound']);
    return ChatSettings(
      notify: ChatNotify.values.where((n) => n.name == notify).firstOrNull,
      mutedUntil: mutedUntil is int ? mutedUntil : null,
      sound: sound is bool ? sound : null,
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (!_known.contains(key)) key: value,
      },
    );
  }

  Map<String, Object?> toJson() => {...extra, 'notify': ?notify?.name, 'mutedUntil': ?mutedUntil, 'sound': ?sound};

  /// These settings with the fields this version knows set as given.
  ChatSettings edit({required ChatNotify? notify, required int? mutedUntil, required bool? sound}) =>
      ChatSettings(notify: notify, mutedUntil: mutedUntil, sound: sound, extra: extra);

  @override
  bool operator ==(Object other) => other is ChatSettings && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
