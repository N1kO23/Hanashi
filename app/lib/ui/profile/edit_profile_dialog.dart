import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/attachments.dart';
import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';
import '../widgets/format.dart';

Future<void> showEditProfile(BuildContext context, {required String userId, required String name}) =>
    showDialog<void>(context: context, builder: (_) => EditProfileDialog(userId: userId, name: name));

/// Changes the display name (seen by the server, like before), the profile
/// picture and the profile card (status message, bio, birthday); the last two are
/// end-to-end encrypted for the people the user chats with.
class EditProfileDialog extends ConsumerStatefulWidget {
  const EditProfileDialog({super.key, required this.userId, required this.name});

  final String userId;
  final String name;

  @override
  ConsumerState<EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends ConsumerState<EditProfileDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final ProfileCard _card = ref.read(profilesProvider).value?[widget.userId]?.card ?? ProfileCard.empty;
  late final _statusMessage = EmojiEditingController()..text = _card.statusMessage ?? '';
  late final _bio = EmojiEditingController()..text = _card.bio ?? '';
  late Birthday? _birthday = _card.birthday;
  var _busy = false;
  String? _error;

  ProfileCard get _edited => _card.edit(statusMessage: _statusMessage.text, bio: _bio.text, birthday: _birthday);

  @override
  void dispose() {
    _name.dispose();
    _statusMessage.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on Exception catch (e) {
      _error = e is AttachmentException || e is ApiException ? '$e' : 'Something went wrong: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickBirthday() async {
    final picked = await showDialog<Birthday>(context: context, builder: (_) => _BirthdayDialog(initial: _birthday));
    if (picked != null) setState(() => _birthday = picked);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.read(chatRepositoryProvider);
    final hasPicture = ref.watch(profilesProvider.select((p) => p.value?[widget.userId]?.avatar != null));
    final name = _name.text.trim();
    final edited = _edited;
    final birthday = _birthday;
    return AlertDialog(
      title: const Text('Edit profile'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar(id: widget.userId, label: name.isEmpty ? widget.name : name, size: 96),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton.icon(
                    key: const Key('avatar-change'),
                    icon: const Icon(Icons.photo_outlined),
                    label: const Text('Change picture'),
                    onPressed: _busy
                        ? null
                        : () async {
                            final path = await pickPicture();
                            if (path != null) await _run(() => repository.setAvatar(path));
                          },
                  ),
                  if (hasPicture)
                    TextButton.icon(
                      key: const Key('avatar-remove'),
                      icon: const Icon(Icons.hide_image_outlined),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(foregroundColor: context.palette.failed),
                      onPressed: _busy ? null : () => _run(() => repository.setAvatar(null)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('display-name-field'),
                controller: _name,
                maxLength: 64,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Display name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('status-message-field'),
                controller: _statusMessage,
                maxLength: ProfileCard.maxStatusMessage,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Status message', hintText: 'Only the best for you!'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('bio-field'),
                controller: _bio,
                minLines: 2,
                maxLines: 5,
                maxLength: ProfileCard.maxBio,
                keyboardType: TextInputType.multiline,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'About me', alignLabelWithHint: true),
                onChanged: (_) => setState(() {}),
              ),
              Row(
                children: [
                  Icon(Icons.cake_rounded, size: 20, color: context.palette.incomingBubble),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      birthday == null ? 'No birthday' : formatBirthday(birthday),
                      key: const Key('birthday-value'),
                      style: TextStyle(color: birthday == null ? context.palette.textMuted : context.palette.textPrimary),
                    ),
                  ),
                  TextButton(
                    key: const Key('birthday-change'),
                    onPressed: _busy ? null : _pickBirthday,
                    child: Text(birthday == null ? 'Add birthday' : 'Change'),
                  ),
                  if (birthday != null)
                    IconButton(
                      key: const Key('birthday-remove'),
                      tooltip: 'Remove birthday',
                      icon: Icon(Icons.close, size: 20, color: context.palette.textSecondary),
                      onPressed: _busy ? null : () => setState(() => _birthday = null),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Your picture, status message, about me and birthday are end-to-end encrypted: '
                'only people you chat with can see them.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: context.palette.textMuted),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: context.palette.failed)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          key: const Key('profile-save'),
          onPressed: _busy || name.isEmpty || (name == widget.name && edited == _card)
              ? null
              : () async {
                  await _run(() async {
                    if (name != widget.name) await repository.setDisplayName(name);
                    if (edited != _card) await repository.setProfileCard(edited);
                  });
                  if (mounted && _error == null) Navigator.pop(this.context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Month and day, without a year.
class _BirthdayDialog extends StatefulWidget {
  const _BirthdayDialog({this.initial});

  final Birthday? initial;

  @override
  State<_BirthdayDialog> createState() => _BirthdayDialogState();
}

class _BirthdayDialogState extends State<_BirthdayDialog> {
  late var _month = widget.initial?.month ?? 1;
  late var _day = widget.initial?.day ?? 1;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Birthday'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<int>(
                  key: const Key('birthday-month'),
                  initialValue: _month,
                  decoration: const InputDecoration(labelText: 'Month'),
                  items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(monthName(m)))],
                  onChanged: (month) => setState(() {
                    _month = month!;
                    _day = min(_day, Birthday.daysIn(_month));
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<int>(
                  // Rebuilt when the month changes, which can shorten it.
                  key: ValueKey('birthday-day-$_month'),
                  initialValue: _day,
                  decoration: const InputDecoration(labelText: 'Day'),
                  items: [
                    for (var d = 1; d <= Birthday.daysIn(_month); d++) DropdownMenuItem(value: d, child: Text('$d')),
                  ],
                  onChanged: (day) => setState(() => _day = day!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Only the month and day: no year, so nobody learns your age.',
            style: TextStyle(fontSize: 12.5, color: context.palette.textMuted),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('birthday-save'),
          onPressed: () => Navigator.pop(context, Birthday(_month, _day)),
          child: const Text('Set'),
        ),
      ],
    );
  }
}
