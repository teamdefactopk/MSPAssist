import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import '../../ui/entity_form.dart';

/// Users and invitations (no public registration: accounts start as invitations).
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<Json>? _users;
  List<Json>? _invitations;
  Lookups? _lookups;
  Object? _error;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Json> _list(Object res) => ((res as Map)['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _load() async {
    final api = context.services.api;
    try {
      _lookups ??= await context.services.repo.lookups();
      final users = await api.get('users', query: {'search': _search, 'per_page': 200});
      final invitations = await api.get('invitations', query: {'per_page': 100});
      if (!mounted) return;
      setState(() {
        _users = _list(users);
        _invitations = _list(invitations);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<Object?, String> _roleOptions(Me me, {bool? staff}) => {
        for (final r in me.inviteRoles)
          if (staff == null || (_lookups!.roles.firstWhere((x) => x['value'] == r)['is_staff'] == staff)) r: _lookups!.roleLabel(r),
      };

  Future<void> _invite(Me me) async {
    final orgs = _lookups!.organizations;
    final res = await showEntityForm(
      context,
      title: 'Invite user',
      initial: {'organization_id': me.organizationId},
      fields: [
        const FieldSpec('name', 'Full name', required: true),
        const FieldSpec('email', 'Email', type: FieldType.email, required: true),
        FieldSpec('role', 'Role', type: FieldType.select, required: true, options: _roleOptions(me)),
        if (me.isStaff) FieldSpec('organization_id', 'Client organization (client roles only)', type: FieldType.select, options: {null: '— CyberCraft staff —', for (final o in orgs) o['id']: o['name'].toString()}),
      ],
      onSave: (v) async => ((await context.services.api.post('invitations', body: v) as Map)['data'] as Map).cast<String, dynamic>(),
    );
    if (res != null && mounted) {
      showInfo(context, 'Invitation sent to ${res['email']}.');
      _load();
    }
  }

  Future<void> _edit(Me me, Json user) async {
    final sites = _lookups!.sites.where((s) => s['organization_id'] == user['organization_id']).toList();
    final isClientUser = user['role'] == 'client_user';
    final selectedSites = <int>{...((user['site_ids'] as List?) ?? []).cast<int>()};
    final res = await showEntityForm(
      context,
      title: 'Edit ${user['name']}',
      initial: user,
      fields: [
        const FieldSpec('name', 'Name', required: true),
        FieldSpec('role', 'Role', type: FieldType.select, options: _roleOptions(me, staff: user['is_staff'] == true)..putIfAbsent(user['role'], () => user['role_label'].toString())),
        const FieldSpec('job_title', 'Job title'),
        const FieldSpec('phone', 'Phone'),
        const FieldSpec('is_active', 'Active (deactivating signs the user out everywhere)', type: FieldType.boolean),
      ],
      onSave: (v) async {
        if (!me.inviteRoles.contains(v['role'])) v.remove('role');
        return ((await context.services.api.patch('users/${user['id']}', body: v) as Map)['data'] as Map).cast<String, dynamic>();
      },
    );
    if (!mounted) return;
    if (isClientUser && sites.isNotEmpty && res != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, setState) => AlertDialog(
            title: const Text('Site access'),
            content: SizedBox(
              width: 400,
              child: ListView(shrinkWrap: true, children: [
                const Text('Client users only see tickets for these sites (plus tickets they raised).'),
                for (final s in sites)
                  CheckboxListTile(
                    title: Text(s['name'].toString()),
                    value: selectedSites.contains(s['id']),
                    onChanged: (v) => setState(() => v == true ? selectedSites.add(s['id'] as int) : selectedSites.remove(s['id'])),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Skip')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save sites')),
            ],
          ),
        ),
      );
      if (ok == true && mounted) {
        try {
          await context.services.api.patch('users/${user['id']}', body: {'site_ids': selectedSites.toList()});
        } catch (e) {
          if (mounted) showError(context, e);
        }
      }
    }
    if (res != null) _load();
  }

  Future<void> _revoke(Json inv) async {
    if (!await confirm(context, 'Revoke invitation?', 'The link sent to ${inv['email']} will stop working.', action: 'Revoke', destructive: true)) return;
    if (!mounted) return;
    try {
      await context.services.api.delete('invitations/${inv['id']}');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: shellAppBar(context, 'Users', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))], bottom: const TabBar(tabs: [Tab(text: 'Users'), Tab(text: 'Invitations')])),
        floatingActionButton: me.inviteRoles.isNotEmpty && _lookups != null
            ? FloatingActionButton.extended(onPressed: () => _invite(me), icon: const Icon(Icons.person_add), label: const Text('Invite'))
            : null,
        body: _error != null
            ? ErrorView(_error!, onRetry: _load)
            : _users == null
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(children: [
                    Column(children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or email', isDense: true),
                          onSubmitted: (v) {
                            _search = v.trim();
                            _load();
                          },
                        ),
                      ),
                      Expanded(
                        child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                          for (final u in _users!)
                            ListTile(
                              leading: CircleAvatar(child: Icon(u['is_staff'] == true ? Icons.support_agent : Icons.person)),
                              title: Text(u['name'].toString() + (u['is_active'] == true ? '' : ' (deactivated)')),
                              subtitle: Text([u['role_label'], u['email'], (u['organization'] as Map?)?['name']].whereType<Object>().join(' · ')),
                              trailing: u['id'] == me.id ? const Text('You') : const Icon(Icons.edit_outlined),
                              onTap: u['id'] == me.id ? null : () => _edit(me, u),
                            ),
                        ]),
                      ),
                    ]),
                    _invitations!.isEmpty
                        ? const EmptyView('No invitations sent yet.')
                        : ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                            for (final i in _invitations!)
                              ListTile(
                                leading: Icon(switch (i['status']) { 'accepted' => Icons.check_circle, 'pending' => Icons.mark_email_unread, _ => Icons.block }),
                                title: Text('${i['name']} <${i['email']}>'),
                                subtitle: Text([i['role_label'], (i['organization'] as Map?)?['name'], i['status'], 'expires ${fmtDate(parseDate(i['expires_at']))}'].whereType<Object>().join(' · ')),
                                trailing: i['status'] == 'pending' ? TextButton(onPressed: () => _revoke(i), child: const Text('Revoke')) : null,
                              ),
                          ]),
                  ]),
      ),
    );
  }
}
