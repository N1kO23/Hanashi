/// Formatting helpers shared by list and chat widgets.
library;

import 'package:hanashi_protocol/hanashi_protocol.dart';

String formatClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// Clock time for today, otherwise a short date.
String formatListTime(DateTime time, {DateTime? now}) {
  final today = now ?? DateTime.now();
  if (time.year == today.year &&
      time.month == today.month &&
      time.day == today.day) {
    return formatClock(time);
  }
  return '${time.month}/${time.day}';
}

String formatDay(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '$bytes B'
      : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The name of [month] (1 to 12).
String monthName(int month) => _months[month - 1];

/// "March 24th", as the game writes birthdays.
String formatBirthday(Birthday birthday) {
  final day = birthday.day;
  final suffix = day >= 11 && day <= 13
      ? 'th'
      : switch (day % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '${monthName(birthday.month)} $day$suffix';
}

/// Days from [now] until [birthday] comes round: 0 on the day. In other
/// years than leap years, February 29 falls on February 28.
int daysUntilBirthday(Birthday birthday, DateTime now) {
  // In UTC, so that a change to or from summer time never makes a day short.
  final today = DateTime.utc(now.year, now.month, now.day);
  DateTime inYear(int year) {
    final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    return DateTime.utc(year, birthday.month, birthday.month == 2 && birthday.day == 29 && !leap ? 28 : birthday.day);
  }

  var next = inYear(today.year);
  if (next.isBefore(today)) next = inYear(today.year + 1);
  return next.difference(today).inDays;
}

/// A change to a group in words, from a line ([Envelope.isGroupLine]):
/// "Kumiko added Naoko", "You renamed the group to "Club Room"". One that only
/// the server's events say, and not the member who made it, says so.
String describeGroupChange(
  Envelope line, {
  required String me,
  required String Function(String userId) nameOf,
}) {
  String who(String id) => id == me ? 'You' : nameOf(id);
  final by = who(line.from);
  final user = line.body['user'];
  final title = line.body['title'];
  final (emoji, was) = (line.body['name'], line.body['was']);
  final text = switch (line.body['change']) {
    'created' when title == null => '$by created the group',
    'created' => '$by created the group "$title"',
    'added' when user == me => '$by added you',
    'added' when user is String => '$by added ${nameOf(user)}',
    'history' when user == me => '$by shared the chat history with you',
    'history' when user is String => '$by shared the chat history with ${nameOf(user)}',
    'left' => '$by left',
    'renamed' => '$by renamed the group to "$title"',
    'picture' => '$by changed the group picture',
    'pictureRemoved' => '$by removed the group picture',
    'description' => '$by changed the group description',
    'descriptionRemoved' => '$by removed the group description',
    'emojiAdded' => '$by added the emoji :$emoji:',
    'emojiRemoved' => '$by removed the emoji :$emoji:',
    'emojiRenamed' => '$by renamed the emoji :$was: to :$emoji:',
    'emojiChanged' => '$by changed the emoji :$emoji:',
    'emojis' => "$by changed the group's emojis",
    'keyChanged' => "${nameOf(line.from)}'s security key changed",
    _ => 'The group changed',
  };
  return line.body['server'] == true ? '$text (according to the server)' : text;
}

/// "Kumiko is typing...", "Kumiko and Naoko are typing...", "3 people are typing...".
String typingText(List<String> names) => switch (names.length) {
  0 => '',
  1 => '${names[0]} is typing...',
  2 => '${names[0]} and ${names[1]} are typing...',
  final n => '$n people are typing...',
};
