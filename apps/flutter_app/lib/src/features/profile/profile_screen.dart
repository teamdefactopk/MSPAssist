import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../sync/sync_service.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import '../../ui/entity_form.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _edit(BuildContext context) async {
    final auth = context.read<AuthController>();
    final me = auth.me!;
    final saved = await showEntityForm(
      context,
      title: 'Edit profile',
      initial: me.json,
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('job_title', 'Job title'),
        FieldSpec('phone', 'Phone'),
        FieldSpec('timezone', 'Timezone (IANA, e.g. Asia/Karachi)', required: true),
      ],
      onSave: (v) async => ((await context.services.api.patch('me', body: v)) as Map)['user'] as Map<String, dynamic>,
    );
    if (saved != null) await auth.refreshProfile();
  }

  Future<void> _changePassword(BuildContext context) async {
    final res = await showEntityForm(
      context,
      title: 'Change password',
      fields: const [
        FieldSpec('current_password', 'Current password', required: true),
        FieldSpec('password', 'New password (min 10, letters and numbers)', required: true),
        FieldSpec('password_confirmation', 'Confirm new password', required: true),
      ],
      onSave: (v) async => ((await context.services.api.put('me/password', body: v)) as Map).cast<String, dynamic>(),
    );
    if (res != null && context.mounted) showInfo(context, 'Password changed. Other devices have been signed out.');
  }

  Future<void> _logout(BuildContext context) async {
    final sync = context.read<SyncService>();
    final waiting = sync.items.length;
    final ok = await confirm(
      context,
      'Sign out?',
      waiting > 0
          ? 'You have $waiting unsynced item(s) on this device. Signing out deletes them and all cached data.'
          : 'Cached tickets and drafts on this device will be removed.',
      action: 'Sign out',
      destructive: waiting > 0,
    );
    if (ok && context.mounted) await context.read<AuthController>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    return Scaffold(
      appBar: shellAppBar(context, 'Profile'),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          SectionCard(
            title: me.name,
            trailing: TextButton.icon(onPressed: () => _edit(context), icon: const Icon(Icons.edit), label: const Text('Edit')),
            child: Column(
              children: [
                InfoRow('Email', me.email),
                InfoRow('Role', me.roleLabel),
                if (me.organizationName != null) InfoRow('Organization', me.organizationName),
                InfoRow('Job title', me.jobTitle),
                InfoRow('Phone', me.phone),
                InfoRow('Timezone', me.timezone),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.all(8),
            child: Column(
              children: [
                ListTile(leading: const Icon(Icons.password), title: const Text('Change password'), onTap: () => _changePassword(context)),
                ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: () => _logout(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
