import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import 'member_picker.dart';

/// Asks for a name and members, creates the group and returns its ID.
Future<String?> showNewGroupDialog(BuildContext context) =>
    showDialog<String>(context: context, builder: (_) => const NewGroupDialog());

class NewGroupDialog extends ConsumerStatefulWidget {
  const NewGroupDialog({super.key});

  @override
  ConsumerState<NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends ConsumerState<NewGroupDialog> {
  final _title = TextEditingController();
  var _members = <String>{};
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _ready => !_busy && _title.text.trim().isNotEmpty && _members.isNotEmpty;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref.read(chatRepositoryProvider).createGroup(_title.text.trim(), _members.toList());
      if (mounted) Navigator.pop(context, id);
    } on StateError catch (e) {
      setState(() => _error = e.message);
    } on ApiException catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New group', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                key: const Key('group-title-field'),
                controller: _title,
                maxLength: 64,
                decoration: const InputDecoration(labelText: 'Group name'),
              ),
              Flexible(
                child: MemberPicker(selected: _members, onChanged: (m) => setState(() => _members = m)),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, key: const Key('group-error'), style: TextStyle(color: context.palette.failed)),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('group-create'),
                    onPressed: _ready ? _create : null,
                    child: Text(_members.isEmpty ? 'Create' : 'Create with ${_members.length + 1}'),
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
