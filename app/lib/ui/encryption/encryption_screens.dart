import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/remote/api_client.dart';
import '../../e2ee/encryption_identity.dart';
import '../../state/providers.dart';
import '../settings/log_view.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/hanashi_title_bar.dart';
import 'verification_dialog.dart';

/// Pink title bar over a centered card, shared by the encryption screens.
class _GateScaffold extends StatelessWidget {
  const _GateScaffold({required this.icon, required this.title, required this.children});

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.listBackground,
      body: Column(
        children: [
          const HanashiTitleBar(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Card(
                    color: context.palette.surface,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(icon, size: 44, color: context.palette.replyAccent),
                          const SizedBox(height: 12),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: context.palette.textHeading,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ...children,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _errorText(Object error) => switch (error) {
  VerificationException(:final message) => message,
  FormatException(:final message) => message,
  PlatformException(:final message?) => message,
  ApiException() => error.toString(),
  _ => 'Something went wrong: $error',
};

TextStyle _bodyStyle(BuildContext context) => TextStyle(fontSize: 15, height: 1.45, color: context.palette.textPrimary);

ButtonStyle _primary(BuildContext context) => FilledButton.styleFrom(
  backgroundColor: context.palette.replyAccent,
  padding: const EdgeInsets.symmetric(vertical: 14),
);

/// First run for an account without an encryption identity.
class EncryptionSetupScreen extends ConsumerStatefulWidget {
  const EncryptionSetupScreen({super.key});

  @override
  ConsumerState<EncryptionSetupScreen> createState() => _EncryptionSetupScreenState();
}

class _EncryptionSetupScreenState extends ConsumerState<EncryptionSetupScreen> {
  var _busy = false;
  String? _error;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(encryptionProvider.notifier).setUp();
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _GateScaffold(
      icon: Icons.lock_outline,
      title: 'Protect your chats',
      children: [
        Text(
          '${context.appName} encrypts your messages and files on your device, so only you and the people you talk '
          'to can read them. Not even the server can.\n\n'
          'Next you get a recovery key. With it you can read your chats on a new device, even when your '
          'other devices are not around.',
          style: _bodyStyle(context),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: context.palette.failed)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('create-recovery-key'),
          style: _primary(context),
          onPressed: _busy ? null : _create,
          child: _busy ? const _Spinner() : const Text('Create my recovery key'),
        ),
        const SizedBox(height: 8),
        const _SignOutButton(),
      ],
    );
  }
}

/// Shows a newly created recovery key once.
class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key});

  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  var _stored = false;

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(encryptionProvider).value?.recoveryKeyToShow ?? '';
    return _GateScaffold(
      icon: Icons.key_outlined,
      title: 'Your recovery key',
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.palette.replyPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.palette.fieldBorder),
          ),
          child: SelectableText(
            key,
            key: const Key('recovery-key-text'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 17, height: 1.6, letterSpacing: 1),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recovery key copied')));
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Store it in a password manager or write it down and keep it somewhere safe. '
          '${context.appName} will not show it again. If you lose it, you can create a new one from any verified device.',
          style: _bodyStyle(context),
        ),
        CheckboxListTile(
          key: const Key('recovery-key-stored'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _stored,
          onChanged: (v) => setState(() => _stored = v ?? false),
          title: const Text('I have stored my recovery key'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('recovery-key-continue'),
          style: _primary(context),
          onPressed: _stored ? ref.read(encryptionProvider.notifier).acknowledgeRecoveryKey : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// A signed-in device that has not been verified yet.
class VerifyDeviceScreen extends ConsumerStatefulWidget {
  const VerifyDeviceScreen({super.key});

  @override
  ConsumerState<VerifyDeviceScreen> createState() => _VerifyDeviceScreenState();
}

class _VerifyDeviceScreenState extends ConsumerState<VerifyDeviceScreen> {
  final _key = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Emoji verification with one of the user's other devices, which then
  /// hands this one the account's keys.
  Future<void> _useAnotherDevice() async {
    final service = ref.read(verificationServiceProvider);
    if (service == null) return;
    final String txn;
    try {
      txn = await service.requestDeviceVerification();
    } catch (e) {
      setState(() => _error = _errorText(e));
      return;
    }
    // This device does not sync yet, so it fetches the answers itself.
    final poll = Timer.periodic(const Duration(seconds: 1), (_) => service.pollInbox().catchError((Object _) {}));
    try {
      if (mounted) await showVerificationDialog(context, txn);
    } finally {
      poll.cancel();
    }
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset encryption?'),
        content: const Text(
          'Only do this if you lost your recovery key and have no other verified device.\n\n'
          'You get a new identity and recovery key. Messages sent before cannot be read anymore, '
          'your other devices must be verified again, and your contacts are told your security key changed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.failed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(() => ref.read(encryptionProvider.notifier).setUp(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    return _GateScaffold(
      icon: Icons.verified_user_outlined,
      title: 'Verify this device',
      children: [
        Text(
          'Your chats are end-to-end encrypted. To read them here, enter your recovery key.',
          style: _bodyStyle(context),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('recovery-key-field'),
          controller: _key,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 1,
          maxLines: 3,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(labelText: 'Recovery key'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            key: const Key('verify-error'),
            style: TextStyle(color: context.palette.failed),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('verify-submit'),
          style: _primary(context),
          onPressed: _busy
              ? null
              : () => _run(() => ref.read(encryptionProvider.notifier).verifyWithRecoveryKey(_key.text)),
          child: _busy ? const _Spinner() : const Text('Verify'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('verify-with-device'),
          onPressed: _busy ? null : _useAnotherDevice,
          child: const Text('Use another device'),
        ),
        const Divider(height: 32),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: context.palette.failed),
          onPressed: _busy ? null : _reset,
          child: const Text('Lost your recovery key and all devices? Reset encryption'),
        ),
        const _SignOutButton(),
        const _LogButton(),
      ],
    );
  }
}

/// The server could not be reached and this device was never verified.
/// The account (from secure storage) or the encryption state (from the
/// server) could not be loaded.
class EncryptionUnavailableScreen extends ConsumerWidget {
  const EncryptionUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountError = ref.watch(accountProvider).error;
    final error = accountError ?? ref.watch(encryptionProvider).error;
    return _GateScaffold(
      icon: accountError != null ? Icons.key_off_outlined : Icons.cloud_off_outlined,
      title: accountError != null ? "Cannot read this device's keys" : 'Cannot reach the server',
      children: [
        Text(error == null ? '' : _errorText(error), style: _bodyStyle(context)),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('unavailable-retry'),
          style: _primary(context),
          onPressed: accountError != null
              ? () => ref.invalidate(accountProvider)
              : ref.read(encryptionProvider.notifier).retry,
          child: const Text('Try again'),
        ),
        // Signing out needs the keys too.
        if (accountError == null) ...[const SizedBox(height: 8), const _SignOutButton()],
        const _LogButton(),
      ],
    );
  }
}

/// Shown before the app when the system keyring cannot be used (Linux without
/// a Secret Service, or a keyring that stays locked): try again once there
/// is one, or keep the keys in a file instead.
class KeyringMissingScreen extends StatefulWidget {
  const KeyringMissingScreen({super.key, required this.onRetry, required this.onUseFile});

  /// Whether the keyring works now.
  final Future<bool> Function() onRetry;
  final Future<void> Function() onUseFile;

  @override
  State<KeyringMissingScreen> createState() => _KeyringMissingScreenState();
}

class _KeyringMissingScreenState extends State<KeyringMissingScreen> {
  var _busy = false;
  var _stillMissing = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await action();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return _GateScaffold(
      icon: Icons.key_off_outlined,
      title: 'No keyring available',
      children: [
        Text(
          '${context.appName} keeps your login and encryption keys in the system keyring, but it cannot use one: '
          'none is running, or it stays locked.',
          style: _bodyStyle(context),
        ),
        const SizedBox(height: 12),
        Text(
          'Start or install one, such as GNOME Keyring, KWallet or KeePassXC (with Secret Service on), '
          'then try again.',
          style: _bodyStyle(context),
        ),
        if (_stillMissing)
          Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Still no keyring.', style: TextStyle(color: context.palette.failed)),
          ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('keyring-retry'),
          style: _primary(context),
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final works = await widget.onRetry();
                  if (mounted) setState(() => _stillMissing = !works);
                }),
          child: const Text('Try again'),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 12),
        Text(
          'Or keep the keys in a file that only your user account can open. It is not encrypted: anyone '
          'who can read your files can read your keys.',
          style: TextStyle(fontSize: 13.5, height: 1.4, color: context.palette.textSecondary),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('keyring-use-file'),
          onPressed: _busy ? null : () => _run(widget.onUseFile),
          child: const Text('Keep keys in a file instead'),
        ),
      ],
    );
  }
}

class _SignOutButton extends ConsumerWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      TextButton(onPressed: () => ref.read(accountProvider.notifier).signOut(), child: const Text('Sign out'));
}

/// The app's log, for finding out why setting up encryption failed.
class _LogButton extends StatelessWidget {
  const _LogButton();

  @override
  Widget build(BuildContext context) => TextButton(
    key: const Key('gate-log'),
    style: TextButton.styleFrom(foregroundColor: context.palette.textSecondary),
    onPressed: () => showLog(context),
    child: const Text('View log'),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: context.palette.onAccent));
}
