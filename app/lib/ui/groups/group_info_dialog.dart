import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/attachments.dart';
import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../encryption/verification_dialog.dart';
import '../theme/hanashi_theme.dart';
import '../profile/profile_card.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';
import '../widgets/presence.dart';
import 'member_picker.dart';

/// Members of a group, and renaming, describing, adding people and leaving.
Future<void> showGroupInfo(BuildContext context, String conversationId) =>
    showDialog<void>(
      context: context,
      builder: (_) => GroupInfoDialog(conversationId: conversationId),
    );

class GroupInfoDialog extends ConsumerStatefulWidget {
  const GroupInfoDialog({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<GroupInfoDialog> createState() => _GroupInfoDialogState();
}

class _GroupInfoDialogState extends ConsumerState<GroupInfoDialog> {
  var _busy = false;
  String? _error;

  /// Runs a change, showing what went wrong in the dialog.
  Future<void> _run(Future<void> Function() change) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await change();
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on AttachmentException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(String current) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(current: current),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == current) return;
    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .renameGroup(widget.conversationId, trimmed),
    );
  }

  Future<void> _describe(String? current) async {
    final description = await showDialog<String>(
      context: context,
      builder: (_) => _DescriptionDialog(current: current ?? ''),
    );
    if (description == null || description.trim() == (current ?? '')) return;
    await _run(
      () => ref
          .read(chatRepositoryProvider)
          .setGroupDescription(widget.conversationId, description),
    );
  }

  Future<void> _addMembers(Set<String> current) async {
    final picked = await showDialog<({Set<String> users, bool shareHistory})>(
      context: context,
      builder: (_) => _AddMembersDialog(exclude: current),
    );
    if (picked == null || picked.users.isEmpty) return;
    await _run(() async {
      for (final user in picked.users) {
        await ref
            .read(chatRepositoryProvider)
            .addMember(
              widget.conversationId,
              user,
              shareHistory: picked.shareHistory,
            );
      }
    });
  }

  Future<void> _leave(String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Leave "$title"?'),
        content: const Text(
          'The group disappears from all your devices, and you will not see new messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('leave-confirm'),
            style: FilledButton.styleFrom(backgroundColor: context.palette.failed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await ref.read(chatRepositoryProvider).leaveGroup(widget.conversationId);
      if (!mounted) return;
      Navigator.pop(context);
      GoRouter.of(context).go('/chats');
    });
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(conversationProvider(widget.conversationId));
    final profiles = ref.watch(profilesProvider).value ?? const {};
    final me = ref.watch(chatRepositoryProvider).me;
    final verified = ref.watch(verifiedUsersProvider).value ?? const {};
    if (summary == null) return const SizedBox.shrink();
    final title = summary.title;
    final members = [...summary.conversation.members]
      ..sort(
        (a, b) => a == me
            ? -1
            : b == me
            ? 1
            : (profiles[a]?.displayName ?? a).compareTo(
                profiles[b]?.displayName ?? b,
              ),
      );

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  PopupMenuButton<bool>(
                    key: const Key('group-picture'),
                    tooltip: 'Group picture',
                    enabled: !_busy,
                    // true: a new picture; false: none.
                    onSelected: (change) async {
                      final path = change ? await pickPicture() : null;
                      if (change && path == null) return;
                      await _run(
                        () => ref
                            .read(chatRepositoryProvider)
                            .setGroupPicture(widget.conversationId, path),
                      );
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        key: Key('group-picture-change'),
                        value: true,
                        child: Text('Change picture'),
                      ),
                      if (summary.picture != null)
                        const PopupMenuItem(
                          key: Key('group-picture-remove'),
                          value: false,
                          child: Text('Remove picture'),
                        ),
                    ],
                    child: Avatar(
                      id: summary.avatarId,
                      label: title,
                      picture: summary.picture,
                      size: 48,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          key: const Key('group-info-title'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          '${members.length} members',
                          style: TextStyle(
                            color: context.palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('group-rename'),
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _busy ? null : () => _rename(title),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (summary.description case final description?)
                InkWell(
                  key: const Key('group-description'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: _busy ? null : () => _describe(description),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(
                        child: EmojiText(
                          description,
                          style: TextStyle(
                            color: context.palette.textPrimary,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('group-describe'),
                    icon: const Icon(Icons.notes, size: 18),
                    label: const Text('Add a description'),
                    onPressed: _busy ? null : () => _describe(null),
                  ),
                ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in members)
                      ListTile(
                        key: ValueKey('group-member-$id'),
                        leading: PresenceAvatar(
                          id: id,
                          label: profiles[id]?.displayName ?? id,
                          size: 36,
                        ),
                        onTap: () => showProfileCard(context, id),
                        title: Text(
                          id == me
                              ? 'You'
                              : profiles[id]?.displayName ??
                                    UserId.fallbackName(id, me: me),
                        ),
                        subtitle: Text(
                          id,
                          style: TextStyle(
                            color: context.palette.textSecondary,
                          ),
                        ),
                        trailing: id == me
                            ? null
                            : verified.contains(id)
                            ? const VerifiedBadge(size: 20)
                            : IconButton(
                                key: ValueKey('verify-$id'),
                                tooltip:
                                    'Verify ${profiles[id]?.displayName ?? id}',
                                icon: const Icon(
                                  Icons.shield_outlined,
                                  size: 20,
                                ),
                                onPressed: () =>
                                    verifyContact(context, ref, id),
                              ),
                      ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
                  child: Text(
                    _error!,
                    key: const Key('group-error'),
                    style: TextStyle(color: context.palette.failed),
                  ),
                ),
              const SizedBox(height: 8),
              if (_busy) const LinearProgressIndicator(),
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton.icon(
                    key: const Key('group-leave'),
                    style: TextButton.styleFrom(
                      foregroundColor: context.palette.failed,
                    ),
                    icon: const Icon(Icons.logout),
                    label: const Text('Leave group'),
                    onPressed: _busy ? null : () => _leave(title),
                  ),
                  FilledButton.icon(
                    key: const Key('group-add-members'),
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('Add people'),
                    onPressed: _busy
                        ? null
                        : () => _addMembers(members.toSet()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename group'),
      content: TextField(
        key: const Key('rename-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('rename-save'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DescriptionDialog extends StatefulWidget {
  const _DescriptionDialog({required this.current});

  final String current;

  @override
  State<_DescriptionDialog> createState() => _DescriptionDialogState();
}

class _DescriptionDialogState extends State<_DescriptionDialog> {
  late final _controller = EmojiEditingController()..text = widget.current;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Group description'),
      content: SizedBox(
        width: 400,
        child: TextField(
          key: const Key('description-field'),
          controller: _controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: GroupDocument.maxDescription,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'What the group is about, its rules...',
            helperText: 'Only members can see it: it is end-to-end encrypted.',
          ),
        ),
      ),
      actions: [
        if (widget.current.isNotEmpty)
          TextButton(
            key: const Key('description-remove'),
            style: TextButton.styleFrom(foregroundColor: context.palette.failed),
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('description-save'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AddMembersDialog extends StatefulWidget {
  const _AddMembersDialog({required this.exclude});

  final Set<String> exclude;

  @override
  State<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<_AddMembersDialog> {
  var _picked = <String>{};
  var _shareHistory = true;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add people', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Flexible(
                child: MemberPicker(
                  selected: _picked,
                  exclude: widget.exclude,
                  onChanged: (p) => setState(() => _picked = p),
                ),
              ),
              CheckboxListTile(
                key: const Key('share-history'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _shareHistory,
                onChanged: (on) => setState(() => _shareHistory = on ?? true),
                title: const Text('Share chat history'),
                subtitle: Text(
                  'They can read the messages from before they joined',
                  style: TextStyle(color: context.palette.textSecondary),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('add-members-confirm'),
                    onPressed: _picked.isEmpty
                        ? null
                        : () => Navigator.pop(context, (
                            users: _picked,
                            shareHistory: _shareHistory,
                          )),
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
