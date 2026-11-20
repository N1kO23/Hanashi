import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';

/// Contacts to tick: nobody else can be added to a group.
class MemberPicker extends ConsumerStatefulWidget {
  const MemberPicker({super.key, required this.selected, required this.onChanged, this.exclude = const {}});

  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  /// Users not to offer (e.g. already members).
  final Set<String> exclude;

  @override
  ConsumerState<MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends ConsumerState<MemberPicker> {
  void _toggle(String userId, bool on) =>
      widget.onChanged(on ? {...widget.selected, userId} : ({...widget.selected}..remove(userId)));

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(chatRepositoryProvider).me;
    final profiles = ref.watch(profilesProvider).value ?? const {};
    final contacts = ref.watch(contactsProvider).value ?? const {};
    final candidates = [
      for (final MapEntry(key: id, value: state) in contacts.entries)
        if (state == ContactState.accepted && id != me && !widget.exclude.contains(id))
          (id: id, name: profiles[id]?.displayName ?? UserId.fallbackName(id, me: me)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No contacts to add: people need to accept your request on the Contacts tab first.',
          style: TextStyle(color: context.palette.textSecondary),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final c in candidates)
          CheckboxListTile(
            key: ValueKey('member-${c.id}'),
            value: widget.selected.contains(c.id),
            onChanged: (on) => _toggle(c.id, on ?? false),
            secondary: Avatar(id: c.id, label: c.name, size: 36),
            title: Text(c.name),
            subtitle: Text(c.id, style: TextStyle(color: context.palette.textSecondary)),
            controlAffinity: ListTileControlAffinity.trailing,
          ),
      ],
    );
  }
}
