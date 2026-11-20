import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../data/remote/api_client.dart';
import '../../e2ee/encryption_identity.dart';
import '../../e2ee/sas.dart';
import '../../e2ee/verification_service.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';

/// Asks [userId] to compare emoji, and shows the verification.
Future<void> verifyContact(BuildContext context, WidgetRef ref, String userId) async {
  final service = ref.read(verificationServiceProvider);
  if (service == null) return;
  final String txn;
  try {
    txn = await service.requestUserVerification(userId);
  } on Exception catch (e) {
    if (context.mounted) {
      final message = switch (e) {
        VerificationException(:final message) => message,
        ApiException() => e.toString(),
        _ => 'Could not start the verification: $e',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
    return;
  }
  if (context.mounted) await showVerificationDialog(context, txn);
}

/// Green shield for a contact the user verified.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Verified',
    child: Icon(Icons.verified_user, key: const Key('verified-badge'), size: size, color: context.palette.success),
  );
}

/// Shows an emoji verification from request to result.
Future<void> showVerificationDialog(BuildContext context, String txn) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => VerificationDialog(txn: txn),
);

class VerificationDialog extends ConsumerStatefulWidget {
  const VerificationDialog({super.key, required this.txn});

  final String txn;

  @override
  ConsumerState<VerificationDialog> createState() => _VerificationDialogState();
}

class _VerificationDialogState extends ConsumerState<VerificationDialog> {
  var _closed = false;

  /// The verification showed up at least once (the list may still be loading
  /// on the first frames).
  var _seen = false;

  void _close() {
    if (_closed) return;
    _closed = true;
    ref.read(verificationServiceProvider)?.dismiss(widget.txn);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final txn = widget.txn;
    final service = ref.watch(verificationServiceProvider);
    final v = (ref.watch(verificationsProvider).value ?? const []).where((v) => v.txn == txn).firstOrNull;
    final profiles = ref.watch(profilesProvider).value ?? const {};
    if (service == null || v == null) {
      if (_seen) {
        // Gone (e.g. accepted on another device): close.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _close();
        });
      }
      return const SizedBox.shrink();
    }
    _seen = true;
    final peer = v.mode == VerificationMode.device
        ? (v.peerDeviceName == null ? 'your other device' : '"${v.peerDeviceName}"')
        : profiles[v.peerUser]?.displayName ??
              UserId.fallbackName(v.peerUser, me: ref.read(chatRepositoryProvider).me);

    void close() => _close();

    Future<void> cancel(String reason) async {
      await service.cancel(txn, reason: reason);
      if (mounted) close();
    }

    final (String title, Widget body, List<Widget> actions) = switch (v.state) {
      SasState.requested when v.incoming => (
        v.mode == VerificationMode.device ? 'Verify a new device?' : 'Verify $peer?',
        Text(
          v.mode == VerificationMode.device
              ? '$peer wants to read your chats. Accept only if you just signed in there yourself.'
              : '$peer wants to confirm that you are who you say. Compare emoji together, in person or on a call.',
        ),
        [
          TextButton(key: const Key('verification-decline'), onPressed: () => cancel('Declined'), child: const Text('Decline')),
          FilledButton(key: const Key('verification-accept'), onPressed: () => service.accept(txn), child: const Text('Accept')),
        ],
      ),
      SasState.requested => (
        'Waiting for $peer',
        _Waiting(
          v.mode == VerificationMode.device
              ? 'Open ${context.appName} on a device where you are signed in, and accept the request there.'
              : 'Ask $peer to accept the request in ${context.appName}.',
        ),
        [TextButton(onPressed: () => cancel('Cancelled'), child: const Text('Cancel'))],
      ),
      SasState.exchanging => ('Connecting', const _Waiting('Setting up a secure exchange...'), const <Widget>[]),
      SasState.comparing => (
        'Compare emoji',
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              v.mode == VerificationMode.device
                  ? 'Check that the other device shows the same emoji in the same order.'
                  : 'Check with $peer that you both see the same emoji in the same order.',
            ),
            const SizedBox(height: 20),
            _EmojiRow(indices: v.emoji!),
          ],
        ),
        [
          TextButton(
            key: const Key('verification-mismatch'),
            style: TextButton.styleFrom(foregroundColor: context.palette.failed),
            onPressed: () => cancel('The emoji did not match'),
            child: const Text('They do not match'),
          ),
          FilledButton(key: const Key('verification-match'), onPressed: () => service.confirm(txn), child: const Text('They match')),
        ],
      ),
      SasState.waitingForOther => ('Compare emoji', _Waiting('Waiting for $peer to confirm...'), const <Widget>[]),
      SasState.verified when !v.done => ('Verified', const _Waiting('Receiving your keys...'), const <Widget>[]),
      SasState.verified => (
        'Verified',
        _Result(
          success: true,
          text: switch (v.mode) {
            VerificationMode.device when v.incoming => '$peer is verified and can read your chats.',
            VerificationMode.device => 'This device is verified and can read your chats.',
            VerificationMode.user => '$peer is verified. You will be warned if their security key changes.',
          },
        ),
        [FilledButton(key: const Key('verification-done'), onPressed: close, child: const Text('Done'))],
      ),
      SasState.cancelled => (
        'Not verified',
        _Result(success: false, text: v.cancelReason ?? 'The verification was cancelled.'),
        [TextButton(key: const Key('verification-close'), onPressed: close, child: const Text('Close'))],
      ),
    };
    return AlertDialog(
      key: const Key('verification-dialog'),
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: body),
      actions: actions,
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
      const SizedBox(width: 16),
      Expanded(child: Text(text)),
    ],
  );
}

class _Result extends StatelessWidget {
  const _Result({required this.success, required this.text});

  final bool success;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        success ? Icons.verified_user : Icons.gpp_bad_outlined,
        color: success ? context.palette.success : context.palette.failed,
        size: 32,
      ),
      const SizedBox(width: 16),
      Expanded(child: Text(text)),
    ],
  );
}

/// The seven emoji with their names, the same on both devices.
class _EmojiRow extends StatelessWidget {
  const _EmojiRow({required this.indices});

  final List<int> indices;

  @override
  Widget build(BuildContext context) => Wrap(
    key: const Key('verification-emoji'),
    alignment: WrapAlignment.center,
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final i in indices)
        SizedBox(
          width: 64,
          child: Column(
            children: [
              Text(sasEmoji[i].emoji, style: const TextStyle(fontSize: 34)),
              const SizedBox(height: 4),
              Text(
                sasEmoji[i].name,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
              ),
            ],
          ),
        ),
    ],
  );
}
