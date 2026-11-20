import 'package:hanashi_protocol/hanashi_protocol.dart';

/// A set of custom emojis cannot hold more than [CustomEmoji.maxPerSet].
class TooManyEmojis implements Exception {
  const TooManyEmojis();

  @override
  String toString() => 'A set holds at most ${CustomEmoji.maxPerSet} emojis';
}

/// The custom emojis [text] uses (`:name:`), for a message to carry: [known]
/// ones first (those of a message being edited, which keep their pictures),
/// then a group's, then the user's own. Names none of them has stay text.
Map<String, MediaRef> emojisIn(
  String text, {
  Map<String, MediaRef> known = const {},
  Map<String, MediaRef> group = const {},
  Map<String, MediaRef> mine = const {},
}) {
  MediaRef? pictureOf(String name) => known[name] ?? group[name] ?? mine[name];
  final emojis = <String, MediaRef>{};
  for (final (:name, start: _, end: _) in CustomEmoji.find(text, (name) => pictureOf(name) != null)) {
    if (emojis.length == CustomEmoji.maxPerMessage && !emojis.containsKey(name)) break;
    emojis[name] = pictureOf(name)!;
  }
  return emojis;
}

/// A message's [body] with the text of [edit] and the custom emojis it uses:
/// an edit carries those of its text.
Map<String, Object?> editedBody(Map<String, Object?> body, Envelope edit) {
  final emojis = edit.body['emojis'];
  return {
    for (final MapEntry(:key, :value) in body.entries)
      if (key != 'emojis') key: value,
    'text': edit.text,
    if (emojis is Map && emojis.isNotEmpty) 'emojis': emojis,
  };
}

/// What [change] makes of the set [current], checked: names as
/// [CustomEmoji.namePattern] says, no more than [CustomEmoji.maxPerSet] (a
/// set that has more, from a later version, can still shrink), and each
/// picture just what showing it needs.
Map<String, MediaRef> changedEmojis(
  Map<String, MediaRef> current,
  Map<String, MediaRef> Function(Map<String, MediaRef> current) change,
) {
  final next = change(Map.unmodifiable(current));
  if (next.length > CustomEmoji.maxPerSet && next.length > current.length) throw const TooManyEmojis();
  for (final name in next.keys) {
    if (!CustomEmoji.namePattern.hasMatch(name)) throw ArgumentError.value(name, 'name', 'Not an emoji name');
  }
  return {for (final MapEntry(:key, :value) in next.entries) key: CustomEmoji.picture(value)};
}

/// The body of a group's line about a change to its emojis, from [before] to
/// [after]; null if there is none. One emoji added, removed, renamed or given
/// a new picture is named, with its picture; more at once are not.
Map<String, Object?>? emojiChangeLine(Map<String, MediaRef> before, Map<String, MediaRef> after) {
  final added = [
    for (final name in after.keys)
      if (!before.containsKey(name)) name,
  ];
  final removed = [
    for (final name in before.keys)
      if (!after.containsKey(name)) name,
  ];
  final changed = [
    for (final name in after.keys)
      if (before[name] case final was? when was.hash != after[name]!.hash) name,
  ];
  Map<String, Object?> line(String change, String name, MediaRef picture, {String? was}) => {
    'change': change,
    'name': name,
    'was': ?was,
    'picture': picture.toJson(),
  };
  return switch ((added, removed, changed)) {
    ([], [], []) => null,
    ([final name], [final was], []) when after[name]!.hash == before[was]!.hash => line(
      'emojiRenamed',
      name,
      after[name]!,
      was: was,
    ),
    ([final name], [], []) => line('emojiAdded', name, after[name]!),
    ([], [final name], []) => line('emojiRemoved', name, before[name]!),
    ([], [], [final name]) => line('emojiChanged', name, after[name]!),
    _ => {'change': 'emojis'},
  };
}
