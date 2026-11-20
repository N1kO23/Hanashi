import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../theme/hanashi_theme.dart';
import '../widgets/emoji_text.dart';
import 'custom_emoji_image.dart';

/// An emoji the composer suggests for the `:name` being written: a custom
/// one, or one of the emoji picker's.
class EmojiSuggestion {
  const EmojiSuggestion.custom(this.name, MediaRef this.picture) : emoji = null;
  const EmojiSuggestion.emoji(String this.emoji, this.name) : picture = null;

  /// A custom one's name, or what the picker calls the emoji.
  final String name;
  final MediaRef? picture;
  final String? emoji;

  /// What choosing it writes.
  String get text => emoji ?? ':$name: ';
}

/// `:` and at least 2 letters of a name, right before the cursor ([String]
/// up to it), at the start or after a space: the name being the first group.
final typedEmojiName = RegExp(r'(?:^|\s):([A-Za-z0-9_]{2,32})$');

/// Every emoji of the picker, with its name in lower case.
final _pickerEmojis = [
  for (final category in defaultEmojiSet)
    for (final emoji in category.emoji) (emoji: emoji.emoji, name: emoji.name.toLowerCase()),
];

/// Up to [max] emojis for [query] (`:query` being written): the [custom]
/// ones whose name has it, those it begins first; then the picker's whose
/// name has a word beginning with it (`_` standing for a space), those with
/// it as words of their own first (`joy` is 😂 before 🕹️, a joystick).
List<EmojiSuggestion> suggestEmojis(String query, Map<String, MediaRef> custom, {int max = 5}) {
  final q = query.toLowerCase();
  final names = custom.keys.toList()..sort();
  final words = q.replaceAll('_', ' ');
  int? rank(String name) => switch (name) {
    _ when ' $name '.contains(' $words ') => 0,
    _ when name.startsWith(words) => 1,
    _ when name.contains(' $words') => 2,
    _ => null,
  };
  final picker = [
    for (final e in _pickerEmojis)
      if (rank(e.name) case final rank?) (emoji: e, rank: rank),
  ]..sort((a, b) => a.rank - b.rank);
  return [
    for (final name in names)
      if (name.startsWith(q)) EmojiSuggestion.custom(name, custom[name]!),
    for (final name in names)
      if (!name.startsWith(q) && name.contains(q)) EmojiSuggestion.custom(name, custom[name]!),
    for (final (:emoji, rank: _) in picker) EmojiSuggestion.emoji(emoji.emoji, emoji.name),
  ].take(max).toList();
}

/// The emojis suggested for what is being written, [highlighted] one being
/// what Enter or Tab chooses.
class EmojiSuggestions extends StatelessWidget {
  const EmojiSuggestions({super.key, required this.suggestions, required this.highlighted, required this.onChoose});

  final List<EmojiSuggestion> suggestions;
  final int highlighted;
  final ValueChanged<EmojiSuggestion> onChoose;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('emoji-suggestions'),
    margin: const EdgeInsets.fromLTRB(12, 0, 0, 8),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: context.palette.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: context.palette.fieldBorder),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, suggestion) in suggestions.indexed)
          Material(
            color: i == highlighted ? context.palette.listBackground : Colors.transparent,
            child: InkWell(
              key: ValueKey('emoji-suggestion-${suggestion.name}'),
              onTap: () => onChoose(suggestion),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 26,
                      child: switch (suggestion) {
                        EmojiSuggestion(:final picture?) => CustomEmojiImage(
                          name: suggestion.name,
                          picture: picture,
                          size: 26,
                        ),
                        _ => Center(child: Text(suggestion.emoji!, style: emojiStyle.copyWith(fontSize: 20))),
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        suggestion.picture == null ? suggestion.name : ':${suggestion.name}:',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: context.palette.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
