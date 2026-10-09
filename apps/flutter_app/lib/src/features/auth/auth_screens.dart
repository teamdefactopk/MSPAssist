import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../ui/common.dart';

/// Centered card layout shared by the unauthenticated screens.
class AuthLayout extends StatelessWidget {
  const AuthLayout({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.support_agent, size: 48, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 8),
                    Text('MSPAssist', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                    Text('CyberCraft IT Support', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 16),
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
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
  );
}

String? _required(String? v) => v == null || v.trim().isEmpty ? 'Required' : null;
String? _validEmail(String? v) => v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim()) ? 'Enter a valid email' : null;
String? _validPassword(String? v) {
  if (v == null || v.length < 10) return 'At least 10 characters';
  if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) return 'Use letters and numbers';
  return null;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.services.auth.login(_email.text.trim(), _password.text, deviceName: 'MSPAssist ${kIsWeb ? 'web' : defaultTargetPlatform.name}');
    } on ApiException catch (e) {
      setState(() => _error = e.firstError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Sign in',
    children: [
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('login-email'),
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              validator: _validEmail,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('login-password'),
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _obscure = !_obscure)),
              ),
              autofillHints: const [AutofillHints.password],
              validator: _required,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))],
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('login-submit'),
              onPressed: _busy ? null : _submit,
              child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Sign in'),
            ),
            TextButton(onPressed: () => context.go('/forgot-password'), child: const Text('Forgot password?')),
            const Text(
              'Accounts are created by invitation from CyberCraft or your organization administrator.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    ],
  );
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _busy = false;
  String? _message;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final res = await context.services.api.post('auth/forgot-password', body: {'email': _email.text.trim()}) as Map;
      setState(() => _message = res['message'].toString());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Reset your password',
    children: [
      if (_message != null)
        Text(_message!)
      else
        Form(
          key: _form,
          child: TextFormField(
            controller: _email,
            decoration: const InputDecoration(labelText: 'Email'),
            validator: _validEmail,
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
      const SizedBox(height: 16),
      if (_message == null) FilledButton(onPressed: _busy ? null : _submit, child: const Text('Send reset link')),
      TextButton(onPressed: () => context.go('/login'), child: const Text('Back to sign in')),
    ],
  );
}

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, required this.token, required this.email});
  final String token;
  final String email;
  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _done = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.services.api.post(
        'auth/reset-password',
        body: {'token': widget.token, 'email': widget.email, 'password': _password.text, 'password_confirmation': _confirm.text},
      );
      setState(() => _done = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Choose a new password',
    children: [
      if (widget.token.isEmpty)
        const Text('This reset link is incomplete. Request a new one.')
      else if (_done)
        const Text('Your password has been reset.')
      else
        Form(
          key: _form,
          child: Column(
            children: [
              InfoRow('Account', widget.email),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
                validator: _validPassword,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirm password'),
                validator: (v) => v != _password.text ? 'Passwords do not match' : null,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _busy ? null : _submit, child: const Text('Reset password')),
              ),
            ],
          ),
        ),
      TextButton(onPressed: () => context.go('/login'), child: const Text('Go to sign in')),
    ],
  );
}

class AcceptInvitationScreen extends StatefulWidget {
  const AcceptInvitationScreen({super.key, required this.token});
  final String token;
  @override
  State<AcceptInvitationScreen> createState() => _AcceptInvitationScreenState();
}

class _AcceptInvitationScreenState extends State<AcceptInvitationScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  Map<String, dynamic>? _invite;
  Object? _error;
  bool _busy = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await context.services.api.get('invitations/${widget.token}') as Map;
      setState(() {
        _invite = (res['data'] as Map).cast();
        _name.text = _invite!['name']?.toString() ?? '';
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.services.api.post(
        'invitations/accept',
        body: {'token': widget.token, 'name': _name.text.trim(), 'password': _password.text, 'password_confirmation': _confirm.text},
      );
      setState(() => _done = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Accept invitation',
    children: [
      if (_error != null)
        Text(errorText(_error!))
      else if (_invite == null)
        const Center(child: CircularProgressIndicator())
      else if (_done)
        const Text('Your account is ready. Sign in with your email and new password.')
      else
        Form(
          key: _form,
          child: Column(
            children: [
              InfoRow('Email', _invite!['email']?.toString()),
              InfoRow('Role', _invite!['role_label']?.toString()),
              if (_invite!['organization'] != null) InfoRow('Organization', _invite!['organization'].toString()),
              const SizedBox(height: 8),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Your name'),
                validator: _required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                validator: _validPassword,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirm password'),
                validator: (v) => v != _password.text ? 'Passwords do not match' : null,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _busy ? null : _submit, child: const Text('Create account')),
              ),
            ],
          ),
        ),
      TextButton(onPressed: () => context.go('/login'), child: const Text('Go to sign in')),
    ],
  );
}
