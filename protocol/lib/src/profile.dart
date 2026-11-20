import 'dart:convert';

/// What a user tells about themself besides their name and picture: the
/// file their `ProfileRef.card` points to, encrypted like any attachment.
/// `{"statusMessage"?, "bio"?, "birthday"?}`; later versions add fields.
/// Fields this version does not know are kept, so editing the card here never
/// drops them.
class ProfileCard {
  const ProfileCard({this.statusMessage, this.bio, this.birthday, this.extra = const {}});

  static const empty = ProfileCard();

  /// A line under the name, at most [maxStatusMessage] characters.
  final String? statusMessage;

  /// What they tell about themself, in a few lines: at most [maxBio]
  /// characters.
  final String? bio;
  final Birthday? birthday;

  /// Fields from later versions, kept as they came.
  final Map<String, Object?> extra;

  static const maxStatusMessage = 100;
  static const maxBio = 300;

  /// Card files larger than this are not read.
  static const maxBytes = 16 * 1024;

  static const _known = {'statusMessage', 'bio', 'birthday'};

  bool get isEmpty => statusMessage == null && bio == null && birthday == null && extra.isEmpty;

  /// A malformed field is left out, not the whole card.
  factory ProfileCard.fromJson(Map<String, Object?> json) {
    final (message, bio) = (json['statusMessage'], json['bio']);
    return ProfileCard(
      statusMessage: message is String && message.trim().isNotEmpty ? message.trim() : null,
      bio: bio is String && bio.trim().isNotEmpty ? bio.trim() : null,
      birthday: Birthday.tryParse(json['birthday']),
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (!_known.contains(key)) key: value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'statusMessage': ?statusMessage,
    'bio': ?bio,
    'birthday': ?birthday?.toJson(),
  };

  /// This card with the fields this version knows set as given (null: none).
  ProfileCard edit({required String? statusMessage, required String? bio, required Birthday? birthday}) {
    String? trimmed(String? text) => text == null || text.trim().isEmpty ? null : text.trim();
    return ProfileCard(statusMessage: trimmed(statusMessage), bio: trimmed(bio), birthday: birthday, extra: extra);
  }

  @override
  bool operator ==(Object other) => other is ProfileCard && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// A birthday: month and day, without a year.
class Birthday {
  const Birthday(this.month, this.day);

  /// 1 to 12.
  final int month;
  final int day;

  /// Null unless [json] is `{"month", "day"}` naming a day of the year
  /// (February 29 included).
  static Birthday? tryParse(Object? json) {
    if (json is! Map) return null;
    final (month, day) = (json['month'], json['day']);
    if (month is! int || day is! int || month < 1 || month > 12 || day < 1 || day > daysIn(month)) return null;
    return Birthday(month, day);
  }

  /// Days [month] can have.
  static int daysIn(int month) => const [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];

  Map<String, Object?> toJson() => {'month': month, 'day': day};

  @override
  bool operator ==(Object other) => other is Birthday && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(month, day);
}
