import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/remote/api_client.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/hanashi_title_bar.dart';

/// The Android emulator reaches the host machine at 10.0.2.2.
String defaultServerUrl() => Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://localhost:8080';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController(text: defaultServerUrl());
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  final _invite = TextEditingController();
  var _register = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_server, _name, _password, _displayName, _invite]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).signIn(
        serverUrl: _server.text.trim(),
        name: _name.text.trim().toLowerCase(),
        password: _password.text,
        register: _register,
        displayName: _register && _displayName.text.trim().isNotEmpty ? _displayName.text.trim() : null,
        inviteCode: _register && _invite.text.trim().isNotEmpty ? _invite.text.trim() : null,
      );
    } on ApiException catch (e) {
      setState(() => _error = e.toString());
    } on FormatException {
      setState(() => _error = 'The server address is not a valid URL');
    } on ArgumentError {
      setState(() => _error = 'The server address is not a valid URL');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Card(
                    color: context.palette.surface,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: false, label: Text('Sign in')),
                                ButtonSegment(value: true, label: Text('Create account')),
                              ],
                              selected: {_register},
                              onSelectionChanged: (s) => setState(() {
                                _register = s.first;
                                _error = null;
                              }),
                            ),
                            const SizedBox(height: 20),
                            _field(
                              _server,
                              'Server',
                              keyboardType: TextInputType.url,
                              validator: (v) => v == null || !v.trim().startsWith(RegExp('https?://'))
                                  ? 'Start with http:// or https://'
                                  : null,
                            ),
                            _field(
                              _name,
                              'User name',
                              validator: (v) => v == null || v.trim().isEmpty ? 'Enter your user name' : null,
                            ),
                            _field(
                              _password,
                              'Password',
                              obscure: true,
                              validator: (v) => _register && (v == null || v.length < 8)
                                  ? 'At least 8 characters'
                                  : (v == null || v.isEmpty ? 'Enter your password' : null),
                            ),
                            if (_register) ...[
                              _field(_displayName, 'Display name (optional)'),
                              _field(_invite, 'Invite code (if the server requires one)'),
                            ],
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(_error!, style: TextStyle(color: context.palette.failed)),
                              ),
                            const SizedBox(height: 4),
                            FilledButton(
                              key: const Key('login-submit'),
                              style: FilledButton.styleFrom(
                                backgroundColor: context.palette.replyAccent,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: _busy ? null : _submit,
                              child: _busy
                                  ? SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: context.palette.onAccent),
                                    )
                                  : Text(_register ? 'Create account' : 'Sign in'),
                            ),
                          ],
                        ),
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

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        autocorrect: false,
        validator: validator,
        onFieldSubmitted: (_) => _submit(),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
