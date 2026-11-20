import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../encryption/verification_dialog.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/format.dart';
import '../widgets/presence.dart';
import 'edit_profile_dialog.dart';

Future<void> showProfileCard(BuildContext context, String userId) =>
    showDialog<void>(context: context, builder: (_) => ProfileCardDialog(userId: userId));

/// Opens the chat with [userId], starting it if there is none: its ID, or
/// null after saying why it could not be started.
Future<String?> startChatWith(BuildContext context, WidgetRef ref, String userId) async {
  try {
    return await ref.read(chatRepositoryProvider).openDirectConversation(userId);
  } on Object catch (e) {
    final message = switch (e) {
      StateError(:final message) => message,
      ApiException() => e.toString(),
      _ => 'Could not start the chat: $e',
    };
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    return null;
  }
}

/// A user's profile card as a dialog, opened from their picture.
class ProfileCardDialog extends StatelessWidget {
  const ProfileCardDialog({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: context.palette.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProfileDetails(userId: userId),
            const SizedBox(height: 16),
            ProfileActions(userId: userId, inDialog: true),
          ],
        ),
      ),
    ),
  );
}

/// A user's profile as the game's messenger shows a student's: picture with
/// their status at its corner, name, status message, below them the facts
/// they tell (their birthday, so far) as pills, and what they wrote about
/// themself. The same in the dialog and beside the contacts ([large]), so both
/// grow as profiles say more.
class ProfileDetails extends ConsumerWidget {
  const ProfileDetails({super.key, required this.userId, this.large = false});

  final String userId;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(chatRepositoryProvider).me;
    final profile = ref.watch(profilesProvider.select((p) => p.value?[userId]));
    final name = profile?.displayName ?? UserId.fallbackName(userId, me: me);
    final card = profile?.card ?? ProfileCard.empty;
    final verified = ref.watch(verifiedUsersProvider.select((v) => v.value?.contains(userId) ?? false));
    final invisible =
        userId == me && ref.watch(presenceModeProvider.select((m) => m.value == PresenceMode.invisible));
    final birthday = card.birthday;
    final facts = [
      if (birthday != null)
        _Fact(key: const Key('profile-birthday'), icon: Icons.cake_rounded, text: formatBirthday(birthday)),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: context.palette.mediaCardBorder, shape: BoxShape.circle),
          child: PresenceAvatar(
            id: userId,
            label: name,
            size: large ? 128 : 96,
            showOffline: true,
            statusLabel: invisible ? 'Invisible' : null,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: EmojiText(
                name,
                key: const Key('profile-name'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: large ? 24 : 21,
                  fontWeight: FontWeight.bold,
                  color: context.palette.textHeading,
                ),
              ),
            ),
            if (verified) ...[const SizedBox(width: 6), const VerifiedBadge(size: 18)],
          ],
        ),
        if (card.statusMessage case final message?) ...[
          const SizedBox(height: 4),
          EmojiText(
            message,
            key: const Key('profile-status-message'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: large ? 16 : 15, color: context.palette.profileText),
          ),
        ],
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: facts),
        ],
        if (card.bio case final bio?) ...[
          const SizedBox(height: 14),
          Container(
            key: const Key('profile-bio'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(color: context.palette.listSelected, borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'About me',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.palette.textSecondary),
                ),
                const SizedBox(height: 4),
                EmojiText(
                  bio,
                  style: TextStyle(fontSize: large ? 15 : 14, height: 1.35, color: context.palette.profileText),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(userId, style: TextStyle(fontSize: 12.5, color: context.palette.textMuted)),
      ],
    );
  }
}

/// What one can do from a profile: message a contact, ask or answer someone
/// who is not one, or edit one's own. Beside the contacts there is room to
/// verify them too. In the dialog ([inDialog]), with a button to close it, and
/// closing it first.
class ProfileActions extends ConsumerWidget {
  const ProfileActions({super.key, required this.userId, this.inDialog = false});

  final String userId;
  final bool inDialog;

  Future<void> _message(BuildContext context, WidgetRef ref) async {
    final conv = await startChatWith(context, ref, userId);
    if (conv == null || !context.mounted) return;
    final router = GoRouter.of(context);
    if (inDialog) Navigator.pop(context);
    router.go('/chats/$conv');
  }

  /// Runs a change between the user and them, saying what went wrong if it does.
  Future<void> _change(BuildContext context, Future<void> Function() change) async {
    try {
      await change();
    } on Object catch (e) {
      final message = switch (e) {
        StateError(:final message) => message,
        ApiException() => e.toString(),
        _ => 'That did not work: $e',
      };
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  List<Widget> _contactButtons(BuildContext context, WidgetRef ref, ContactState state) {
    final repository = ref.read(chatRepositoryProvider);
    return switch (state) {
      ContactState.accepted => [
        PopupMenuButton<_ContactAction>(
          key: const Key('profile-contact-menu'),
          tooltip: 'Contact',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) => _change(
            context,
            () => action == _ContactAction.remove ? repository.removeContact(userId) : repository.blockContact(userId),
          ),
          itemBuilder: (_) => const [
            PopupMenuItem(key: Key('profile-remove'), value: _ContactAction.remove, child: Text('Remove contact')),
            PopupMenuItem(key: Key('profile-block'), value: _ContactAction.block, child: Text('Block')),
          ],
        ),
        if (!inDialog && !_isVerified(ref))
          OutlinedButton.icon(
            key: const Key('profile-verify'),
            icon: const Icon(Icons.shield_outlined, size: 18),
            label: const Text('Verify'),
            onPressed: () => verifyContact(context, ref, userId),
          ),
        FilledButton.icon(
          key: const Key('profile-message'),
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: const Text('Message'),
          onPressed: () => _message(context, ref),
        ),
      ],
      ContactState.incoming => [
        TextButton(
          key: const Key('profile-block'),
          onPressed: () => _change(context, () => repository.blockContact(userId)),
          child: const Text('Block'),
        ),
        OutlinedButton(
          key: const Key('profile-decline'),
          onPressed: () => _change(context, () => repository.declineContact(userId)),
          child: const Text('Decline'),
        ),
        FilledButton(
          key: const Key('profile-accept'),
          onPressed: () => _change(context, () => repository.acceptContact(userId)),
          child: const Text('Accept'),
        ),
      ],
      ContactState.outgoing => [
        OutlinedButton(
          key: const Key('profile-cancel-request'),
          onPressed: () => _change(context, () => repository.cancelContactRequest(userId)),
          child: const Text('Cancel request'),
        ),
      ],
      ContactState.blocked => [
        OutlinedButton(
          key: const Key('profile-unblock'),
          onPressed: () => _change(context, () => repository.unblockContact(userId)),
          child: const Text('Unblock'),
        ),
      ],
      ContactState.none => [
        TextButton(
          key: const Key('profile-block'),
          onPressed: () => _change(context, () => repository.blockContact(userId)),
          child: const Text('Block'),
        ),
        FilledButton.icon(
          key: const Key('profile-add-contact'),
          icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
          label: const Text('Add contact'),
          onPressed: () => _change(context, () => repository.requestContact(userId)),
        ),
      ],
    };
  }

  bool _isVerified(WidgetRef ref) => ref.watch(verifiedUsersProvider.select((v) => v.value?.contains(userId) ?? false));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(chatRepositoryProvider).me;
    final state = ref.watch(contactsProvider.select((c) => c.value?[userId])) ?? ContactState.none;
    final name =
        ref.watch(profilesProvider.select((p) => p.value?[userId]?.displayName)) ?? UserId.fallbackName(userId, me: me);
    // Like a dialog's buttons: one above the other when they do not fit.
    return OverflowBar(
      alignment: inDialog ? MainAxisAlignment.end : MainAxisAlignment.center,
      overflowAlignment: inDialog ? OverflowBarAlignment.end : OverflowBarAlignment.center,
      spacing: 8,
      overflowSpacing: 8,
      children: [
        if (inDialog) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (userId == me)
          FilledButton.icon(
            key: const Key('profile-edit'),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit profile'),
            onPressed: () {
              final navigator = Navigator.of(context);
              if (inDialog) navigator.pop();
              showEditProfile(navigator.context, userId: userId, name: name);
            },
          )
        else
          ..._contactButtons(context, ref, state),
      ],
    );
  }
}

enum _ContactAction { remove, block }

/// One thing a user tells about themself, as a pill under their name.
class _Fact extends StatelessWidget {
  const _Fact({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: context.palette.profilePill, borderRadius: BorderRadius.circular(8)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: context.palette.incomingBubble),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: context.palette.textPrimary),
        ),
      ],
    ),
  );
}
