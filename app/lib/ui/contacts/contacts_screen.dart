import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/models.dart';
import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../encryption/verification_dialog.dart';
import '../groups/new_group_dialog.dart';
import '../home/home_shell.dart';
import '../profile/profile_card.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';
import '../widgets/format.dart';
import '../widgets/list_header.dart';
import '../widgets/presence.dart';
import '../window/window_caption.dart';

/// The "Contacts" tab, laid out as the game's student list: birthdays
/// first, then everyone, each with their status message and status. The
/// profile of the one picked shows beside the list on wide layouts, and in
/// its place on phones.
class ContactsPane extends StatelessWidget {
  const ContactsPane({super.key, this.selectedUser});

  final String? selectedUser;

  @override
  Widget build(BuildContext context) {
    final selected = selectedUser;
    if (!isWideLayout(context)) return selected == null ? const ContactList() : _ContactProfileScreen(userId: selected);
    return Row(
      children: [
        SizedBox(width: 340, child: ContactList(selectedUser: selected)),
        VerticalDivider(width: 1, color: context.palette.panelDivider),
        Expanded(child: selected == null ? const _NoContactSelected() : _ContactProfile(userId: selected)),
      ],
    );
  }
}

enum ContactSort {
  name('Name'),
  status('Status'),
  birthday('Birthday');

  const ContactSort(this.label);

  final String label;
}

/// Birthdays this many days ahead count as upcoming.
const upcomingBirthdayDays = 7;

class ContactList extends ConsumerStatefulWidget {
  const ContactList({super.key, this.selectedUser});

  final String? selectedUser;

  @override
  ConsumerState<ContactList> createState() => _ContactListState();
}

enum _NewChat { contact, group }

class _ContactListState extends ConsumerState<ContactList> {
  var _sort = ContactSort.name;
  var _ascending = true;

  /// Shows [userId]'s profile (see [ContactsPane]).
  void _pick(String userId) => context.go('/contacts/${Uri.encodeComponent(userId)}');

  /// Asks [userId] to become a contact, saying how that went.
  Future<void> _addContact(String userId) async {
    final messenger = ScaffoldMessenger.of(context);
    final String message;
    try {
      final state = await ref.read(chatRepositoryProvider).requestContact(userId);
      message = switch (state) {
        ContactState.accepted => '$userId is now a contact',
        _ => 'Asked $userId. They become a contact once they accept.',
      };
    } on ApiException catch (e) {
      final host = UserId.tryParse(userId)?.host;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (e.code) {
            'user_not_found' => 'There is no user $userId',
            'other_server' => 'Users on $host can\'t be reached from your server',
            'server_unreachable' => '$host can\'t be reached right now. Try again later.',
            _ => e.toString(),
          }),
        ),
      );
      return;
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _newChat(_NewChat kind) async {
    switch (kind) {
      case _NewChat.contact:
        final userId = await showDialog<String>(context: context, builder: (_) => const _AddContactDialog());
        if (userId != null) await _addContact(userId);
      case _NewChat.group:
        final id = await showNewGroupDialog(context);
        if (id != null && mounted) context.go('/chats/$id');
    }
  }

  List<UserProfile> _sorted(List<UserProfile> contacts, Map<String, Presence> presence, DateTime now) {
    int byName(UserProfile a, UserProfile b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    // Who can answer now first.
    int rank(UserProfile p) => switch (presence[p.id] ?? Presence.offline) {
      Presence.online => 0,
      Presence.idle => 1,
      Presence.focus => 2,
      Presence.offline => 3,
    };
    // Those who told none last.
    int untilBirthday(UserProfile p) => switch (p.card.birthday) {
      final b? => daysUntilBirthday(b, now),
      null => 400,
    };
    final sorted = [...contacts]
      ..sort(
        (a, b) => switch (_sort) {
          ContactSort.name => byName(a, b),
          ContactSort.status => rank(a).compareTo(rank(b)) == 0 ? byName(a, b) : rank(a).compareTo(rank(b)),
          ContactSort.birthday =>
            untilBirthday(a).compareTo(untilBirthday(b)) == 0
                ? byName(a, b)
                : untilBirthday(a).compareTo(untilBirthday(b)),
        },
      );
    return _ascending ? sorted : sorted.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(chatRepositoryProvider).me;
    final profiles = ref.watch(profilesProvider);
    final states = ref.watch(contactsProvider).value ?? const {};
    final presence = ref.watch(presenceProvider).value ?? const {};
    final now = ref.watch(clockProvider)();

    return ColoredBox(
      color: context.palette.listBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListHeader(
            title: profiles.maybeWhen(
              data: (_) => 'Contacts (${states.values.where((s) => s == ContactState.accepted).length})',
              orElse: () => 'Contacts',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListSortMenu(
                  value: _sort,
                  options: ContactSort.values,
                  labelOf: (s) => s.label,
                  onSelected: (s) => setState(() => _sort = s),
                ),
                ListHeaderButton(
                  key: const Key('contacts-order'),
                  tooltip: _ascending ? 'Ascending' : 'Descending',
                  onPressed: () => setState(() => _ascending = !_ascending),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sort, size: 18, color: context.palette.incomingBubble),
                      Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 15,
                        color: context.palette.incomingBubble,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<_NewChat>(
                  tooltip: 'Add',
                  onSelected: _newChat,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      key: Key('add-contact'),
                      value: _NewChat.contact,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.person_add_alt_1_outlined),
                        title: Text('Add contact'),
                      ),
                    ),
                    PopupMenuItem(
                      key: Key('new-group'),
                      value: _NewChat.group,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.group_add_outlined),
                        title: Text('New group'),
                      ),
                    ),
                  ],
                  child: IgnorePointer(
                    child: ListHeaderButton(child: Icon(Icons.add, size: 20, color: context.palette.incomingBubble)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: profiles.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load contacts: $e')),
              data: (map) {
                final contacts = [
                  for (final p in map.values)
                    if (p.id != me && states[p.id] == ContactState.accepted) p,
                ];
                UserProfile personOf(String id) =>
                    map[id] ?? UserProfile(id: id, displayName: UserId.fallbackName(id, me: me));
                List<UserProfile> withState(ContactState state) => [
                  for (final MapEntry(key: id, value: s) in states.entries)
                    if (s == state) personOf(id),
                ]..sort((a, b) => a.id.compareTo(b.id));
                final (incoming, outgoing) = (withState(ContactState.incoming), withState(ContactState.outgoing));
                if (contacts.isEmpty && incoming.isEmpty && outgoing.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No contacts yet. Add someone by their user ID with the + above.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                    ),
                  );
                }
                int? until(UserProfile p) => switch (p.card.birthday) {
                  final b? => daysUntilBirthday(b, now),
                  null => null,
                };
                final byName = [...contacts]
                  ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
                final today = [for (final p in byName) if (until(p) == 0) p];
                final upcoming = [
                  for (final p in byName)
                    if (until(p) case final days? when days > 0 && days <= upcomingBirthdayDays) p,
                ]..sort((a, b) => until(a)!.compareTo(until(b)!));
                Widget tile(UserProfile p) => ContactTile(
                  profile: p,
                  birthdayIn: until(p),
                  selected: p.id == widget.selectedUser,
                  onTap: () => _pick(p.id),
                );
                List<Widget> section(String? title, List<UserProfile> people) => [
                  if (title != null) SectionHeader(title: title),
                  for (final (i, p) in people.indexed) ...[
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    tile(p),
                  ],
                ];
                final birthdays = today.isNotEmpty || upcoming.isNotEmpty;
                final requests = incoming.isNotEmpty || outgoing.isNotEmpty;
                return ListView(
                  children: [
                    if (incoming.isNotEmpty) ...[
                      SectionHeader(title: 'Contact Requests (${incoming.length})'),
                      for (final p in incoming)
                        _RequestTile(profile: p, selected: p.id == widget.selectedUser, onTap: () => _pick(p.id)),
                    ],
                    if (outgoing.isNotEmpty) ...[
                      const SectionHeader(title: 'Waiting for an Answer'),
                      for (final p in outgoing)
                        _RequestTile(profile: p, selected: p.id == widget.selectedUser, onTap: () => _pick(p.id)),
                    ],
                    if (today.isNotEmpty) ...section("Today's Birthdays", today),
                    if (upcoming.isNotEmpty) ...section('Upcoming Birthdays', upcoming),
                    if (contacts.isNotEmpty)
                      ...section(birthdays || requests ? 'All Contacts' : null, _sorted(contacts, presence, now)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Someone who asked to be a contact, or whom the user asked: until they are
/// one, all there is to go by is their user ID, which nobody can fake, unlike a
/// name they would give themself. It opens their profile, with what can be done.
class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.profile, required this.onTap, this.selected = false});

  final UserProfile profile;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? context.palette.listSelected : context.palette.listBackground,
    child: InkWell(
      key: ValueKey('contact-request-${profile.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Avatar(id: profile.id, label: profile.id, size: 54),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                profile.id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.palette.textPrimary),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One contact as the game lists a student: picture, name, status message,
/// and their status where the game shows the relationship rank. [birthdayIn]
/// days until their birthday, if they told it.
class ContactTile extends ConsumerWidget {
  const ContactTile({
    super.key,
    required this.profile,
    required this.onTap,
    this.birthdayIn,
    this.selected = false,
  });

  final UserProfile profile;
  /// Shows their profile, picture and all.
  final VoidCallback onTap;
  final int? birthdayIn;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = profile;
    final verified = ref.watch(verifiedUsersProvider.select((v) => v.value?.contains(p.id) ?? false));
    final presence = ref.watch(presenceOfProvider(p.id));
    final days = birthdayIn;
    return Material(
      color: selected ? context.palette.listSelected : context.palette.listBackground,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          // As a chat in the chat list.
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Stack(
                key: ValueKey('contact-profile-${p.id}'),
                clipBehavior: Clip.none,
                alignment: Alignment.bottomCenter,
                children: [
                  Avatar(id: p.id, label: p.displayName, size: 54),
                  if (days == 0) const Positioned(bottom: -5, child: _BirthdayTag()),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: EmojiText(
                            p.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: context.palette.textPrimary),
                          ),
                        ),
                        if (verified) ...[const SizedBox(width: 6), const VerifiedBadge()],
                        if (days != null && days > 0 && days <= upcomingBirthdayDays) _DaysLeft(days: days),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Their status message, as the game lists students; else who they are.
                    EmojiText(
                      p.card.statusMessage ?? p.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              StatusBadge(presence: presence, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// "B-DAY" across the bottom of the picture of someone whose birthday is today.
class _BirthdayTag extends StatelessWidget {
  const _BirthdayTag();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('birthday-today'),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: context.palette.birthday,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: context.palette.surface, width: 1.5),
    ),
    child: Text(
      'B-DAY',
      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: context.palette.birthdayText, height: 1.2),
    ),
  );
}

/// "D-5": days until an upcoming birthday.
class _DaysLeft extends StatelessWidget {
  const _DaysLeft({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: context.palette.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: context.palette.fieldBorder),
    ),
    child: Text('D-$days', style: TextStyle(fontSize: 11.5, color: context.palette.textSecondary)),
  );
}

/// [userId]'s profile in place of the list on phones, under a bar as an
/// open chat's: back returns to the list.
class _ContactProfileScreen extends StatelessWidget {
  const _ContactProfileScreen({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) {
    final bar = SizedBox(
      height: 56,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            icon: Icon(Icons.arrow_back, color: context.palette.onHeader),
            onPressed: () => context.go('/contacts'),
          ),
          // Also the window's title bar on desktop.
          Expanded(
            child: WindowDragArea(
              child: SizedBox.expand(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Profile',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.palette.onHeader),
                  ),
                ),
              ),
            ),
          ),
          const WindowButtons(),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: context.palette.header,
            border: Border(bottom: BorderSide(color: context.palette.panelDivider)),
          ),
          child: SafeArea(bottom: false, child: bar),
        ),
        Expanded(child: _ContactProfile(userId: userId)),
      ],
    );
  }
}

/// [userId]'s profile beside the list on wide layouts, or filling the screen
/// on phones, with room to grow as profiles say more.
class _ContactProfile extends StatelessWidget {
  const _ContactProfile({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.palette.chatBackground,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProfileDetails(key: ValueKey(userId), userId: userId, large: true),
              const SizedBox(height: 24),
              ProfileActions(userId: userId),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NoContactSelected extends StatelessWidget {
  const _NoContactSelected();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.palette.chatBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_outline, size: 56, color: context.palette.divider),
            SizedBox(height: 12),
            Text('Select a contact.', style: TextStyle(color: context.palette.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim().toLowerCase();
    if (UserId.tryParse(value) == null) {
      setState(() => _error = 'Enter an ID like name@host');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a contact'),
      content: TextField(
        key: const Key('add-contact-field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: 'name@host', errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const Key('add-contact-confirm'), onPressed: _submit, child: const Text('Ask')),
      ],
    );
  }
}
