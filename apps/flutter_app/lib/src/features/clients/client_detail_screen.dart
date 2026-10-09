import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import 'client_forms.dart';

class ClientDetailScreen extends StatefulWidget {
  const ClientDetailScreen({super.key, required this.organizationId});
  final int organizationId;

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  Json? _org;
  List<Json> _sites = [];
  List<Json> _departments = [];
  List<Json> _contacts = [];
  List<Json> _equipment = [];
  List<Json> _users = [];
  List<Json> _slaPolicies = [];
  bool _fromCache = false;
  Object? _error;

  int get _id => widget.organizationId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Json> _list(Json res) => (res['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _load() async {
    final repo = context.services.repo;
    final me = context.read<AuthController>().me!;
    try {
      final org = await repo.getCached('organizations/$_id', cacheKey: 'org:$_id');
      final sites = await repo.getCached('organizations/$_id/sites', cacheKey: 'sites:$_id');
      final depts = await repo.getCached('organizations/$_id/departments', cacheKey: 'departments:$_id');
      final contacts = await repo.getCached('organizations/$_id/contacts', cacheKey: 'contacts:$_id');
      final equipment = await repo.getCached('organizations/$_id/equipment', cacheKey: 'equipment:$_id');
      List<Json> users = [];
      List<Json> policies = [];
      if (me.can('manage_users') || me.isStaff) {
        try {
          users = _list((await repo.getCached('users', query: {'organization_id': _id, 'per_page': 200}, cacheKey: 'users:$_id')).data);
        } catch (_) {}
      }
      if (me.can('manage_clients')) {
        try {
          policies = _list((await repo.getCached('sla-policies', cacheKey: 'sla-policies')).data);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _org = (org.data['data'] as Map).cast();
        _sites = _list(sites.data);
        _departments = _list(depts.data);
        _contacts = _list(contacts.data);
        _equipment = _list(equipment.data);
        _users = users;
        _slaPolicies = policies;
        _fromCache = org.fromCache;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _delete(String path, String what) async {
    if (!await confirm(context, 'Delete $what?', 'This cannot be undone.', action: 'Delete', destructive: true)) return;
    if (!mounted) return;
    try {
      await context.services.api.delete(path);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _name(List<Json> list, Object? id) => list.firstWhere((e) => e['id'] == id, orElse: () => {'name': '—'})['name'].toString();

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    final org = _org;
    if (org == null) {
      return Scaffold(
        appBar: shellAppBar(context, 'Client'),
        body: _error != null ? ErrorView(_error!, onRetry: _load) : const Center(child: CircularProgressIndicator()),
      );
    }
    final canSites = me.can('manage_clients') && !_fromCache;
    final canDirectory = me.can('manage_directory') && !_fromCache;
    final canEquipment = (me.isStaff || me.can('manage_directory')) && !_fromCache;
    final showUsers = me.can('manage_users') || me.isStaff;

    final tabs = <(String, Widget)>[
      ('Overview', _overview(me, org)),
      ('Sites (${_sites.length})', _section(
          items: _sites,
          empty: 'No sites yet.',
          onAdd: canSites ? () async => (await editSite(context, _id)) != null ? _load() : null : null,
          tile: (s) => ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(s['name'].toString()),
                subtitle: Text([s['code'], s['address'], s['city'], if (s['is_active'] == false) 'inactive'].whereType<Object>().join(' · ')),
                trailing: canSites
                    ? _menu(onEdit: () async => (await editSite(context, _id, site: s)) != null ? _load() : null, onDelete: () => _delete('sites/${s['id']}', 'site'))
                    : null,
              ))),
      ('Departments', _section(
          items: _departments,
          empty: 'No departments yet.',
          onAdd: canDirectory ? () async => (await editDepartment(context, _id, _sites)) != null ? _load() : null : null,
          tile: (d) => ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(d['name'].toString()),
                subtitle: Text(d['site_id'] == null ? 'All sites' : _name(_sites, d['site_id'])),
                trailing: canDirectory
                    ? _menu(
                        onEdit: () async => (await editDepartment(context, _id, _sites, department: d)) != null ? _load() : null,
                        onDelete: () => _delete('departments/${d['id']}', 'department'))
                    : null,
              ))),
      ('Contacts', _section(
          items: _contacts,
          empty: 'No contacts yet.',
          onAdd: canDirectory ? () async => (await editContact(context, _id, _sites, _departments)) != null ? _load() : null : null,
          tile: (c) => ListTile(
                leading: Icon(c['is_primary'] == true ? Icons.star : Icons.person_outline),
                title: Text(c['name'].toString()),
                subtitle: Text([c['job_title'], c['email'], c['phone'], if (c['site_id'] != null) _name(_sites, c['site_id'])].whereType<Object>().join(' · ')),
                trailing: canDirectory
                    ? _menu(
                        onEdit: () async => (await editContact(context, _id, _sites, _departments, contact: c)) != null ? _load() : null,
                        onDelete: () => _delete('contacts/${c['id']}', 'contact'))
                    : null,
              ))),
      ('Equipment (${_equipment.length})', _section(
          items: _equipment,
          empty: 'No equipment recorded.',
          onAdd: canEquipment ? () async => (await editEquipment(context, _id, _sites, _departments)) != null ? _load() : null : null,
          tile: (e) => ListTile(
                leading: const Icon(Icons.devices_other),
                title: Text('${e['name']}${e['asset_tag'] != null ? ' (${e['asset_tag']})' : ''}'),
                subtitle: Text([e['type'], e['manufacturer'], e['model'], if (e['serial_number'] != null) 'S/N ${e['serial_number']}', if (e['site_id'] != null) _name(_sites, e['site_id']), e['status']]
                    .whereType<Object>()
                    .join(' · ')),
                trailing: canEquipment
                    ? _menu(
                        onEdit: () async => (await editEquipment(context, _id, _sites, _departments, equipment: e)) != null ? _load() : null,
                        onDelete: () => _delete('equipment/${e['id']}', 'equipment'))
                    : null,
              ))),
      if (showUsers)
        ('Users', _section(
            items: _users,
            empty: 'No users yet. Invite them from the Users page.',
            tile: (u) => ListTile(
                  leading: Icon(u['is_active'] == true ? Icons.person : Icons.person_off),
                  title: Text(u['name'].toString()),
                  subtitle: Text('${u['role_label']} · ${u['email'] ?? ''}${u['is_active'] == true ? '' : ' · deactivated'}'),
                ))),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: shellAppBar(
          context,
          org['name'].toString(),
          actions: [
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          ],
          bottom: TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(text: t.$1)]),
        ),
        body: Column(children: [
          if (_fromCache) const OfflineBanner(),
          Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
        ]),
      ),
    );
  }

  Widget _overview(Me me, Json org) => ListView(padding: const EdgeInsets.all(8), children: [
        SectionCard(
          title: 'Client details',
          trailing: me.can('manage_clients') && !_fromCache
              ? TextButton.icon(
                  onPressed: () async => (await editOrganization(context, org: org, slaPolicies: _slaPolicies)) != null ? _load() : null,
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                )
              : null,
          child: Column(children: [
            InfoRow('Name', org['name']?.toString()),
            InfoRow('Code', org['code']?.toString()),
            InfoRow('Email', org['email']?.toString()),
            InfoRow('Phone', org['phone']?.toString()),
            InfoRow('Address', org['address']?.toString()),
            InfoRow('Timezone', org['timezone']?.toString()),
            if (me.isStaff) InfoRow('SLA policy', org['sla_policy_id'] == null ? 'Default' : _name(_slaPolicies, org['sla_policy_id'])),
            InfoRow('Status', org['is_active'] == false ? 'Inactive' : 'Active'),
            if (me.isStaff) InfoRow('Notes', org['notes']?.toString()),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: () => context.go('/tickets/new?organization_id=$_id'),
              icon: const Icon(Icons.add),
              label: const Text('New ticket'),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/tickets?organization_id=$_id&state=active'),
              icon: const Icon(Icons.confirmation_number_outlined),
              label: Text('Active tickets (${org['open_tickets_count'] ?? 0})'),
            ),
          ]),
        ),
      ]);

  Widget _section({required List<Json> items, required String empty, required Widget Function(Json) tile, VoidCallback? onAdd}) => Scaffold(
        floatingActionButton: onAdd == null ? null : FloatingActionButton(heroTag: null, onPressed: onAdd, tooltip: 'Add', child: const Icon(Icons.add)),
        body: items.isEmpty
            ? EmptyView(empty)
            : ListView(padding: const EdgeInsets.only(bottom: 88), children: [for (final i in items) Card(margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), child: tile(i))]),
      );

  Widget _menu({required VoidCallback onEdit, required VoidCallback onDelete}) => PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );
}
