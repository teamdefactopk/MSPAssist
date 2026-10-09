import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import '../tickets/ticket_widgets.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Json? _data;
  bool _fromCache = false;
  Object? _error;
  int? _orgId;
  int? _siteId;
  Lookups? _lookups;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final repo = context.services.repo;
    try {
      _lookups ??= await repo.lookups();
      final res = await repo.getCached('dashboard', query: {'organization_id': _orgId, 'site_id': _siteId}, cacheKey: 'dashboard:$_orgId:$_siteId');
      if (!mounted) return;
      setState(() {
        _data = (res.data['data'] as Map).cast();
        _fromCache = res.fromCache;
        _error = null;
      });
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = e);
    }
  }

  void _openTickets(Map<String, String> filters) {
    final q = {...filters, if (_orgId != null) 'organization_id': '$_orgId', if (_siteId != null) 'site_id': '$_siteId'};
    context.go(Uri(path: '/tickets', queryParameters: q).toString());
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    return Scaffold(
      appBar: shellAppBar(context, 'Dashboard', actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh')]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/tickets/new'),
        icon: const Icon(Icons.add),
        label: const Text('New ticket'),
      ),
      body: _error != null && _data == null
          ? ErrorView(_error!, onRetry: _load)
          : _data == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 88), children: [
                    if (_fromCache) const OfflineBanner(),
                    _filters(me),
                    _kpis(me),
                    _body(me),
                  ]),
                ),
    );
  }

  Widget _filters(Me me) {
    final orgs = _lookups?.organizations ?? [];
    final sites = (_lookups?.sites ?? []).where((s) => _orgId == null || s['organization_id'] == _orgId).toList();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(spacing: 12, runSpacing: 12, children: [
        if (me.isStaff)
          SizedBox(
            width: 260,
            child: DropdownButtonFormField<int?>(
              initialValue: _orgId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Client', isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('All clients')),
                for (final o in orgs) DropdownMenuItem(value: o['id'] as int, child: Text(o['name'].toString(), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) {
                setState(() {
                  _orgId = v;
                  _siteId = null;
                });
                _load();
              },
            ),
          ),
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<int?>(
            key: ValueKey('site-$_orgId'),
            initialValue: _siteId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Site', isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text('All sites')),
              for (final s in sites) DropdownMenuItem(value: s['id'] as int, child: Text(s['name'].toString(), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              setState(() => _siteId = v);
              _load();
            },
          ),
        ),
      ]),
    );
  }

  Widget _kpis(Me me) {
    final c = (_data!['counts'] as Map).cast<String, dynamic>();
    final cards = <Widget>[
      _Kpi('Active', c['active'], Icons.confirmation_number, Colors.indigo, () => _openTickets({'state': 'active'})),
      _Kpi('Unassigned', c['unassigned'], Icons.person_off, Colors.orange, () => _openTickets({'state': 'active', 'assigned_to': 'none'})),
      _Kpi('Overdue', c['overdue'], Icons.alarm, Colors.red, () => _openTickets({'overdue': '1'})),
      _Kpi('Waiting', c['waiting'], Icons.hourglass_bottom, Colors.amber.shade800, () => _openTickets({'status': 'waiting_client,waiting_vendor'})),
      if (me.isStaff) _Kpi('Assigned to me', c['assigned_to_me'], Icons.assignment_ind, Colors.teal, () => _openTickets({'state': 'active', 'assigned_to': 'me'})),
      _Kpi('Resolved (7 days)', c['resolved_last_7_days'], Icons.check_circle, Colors.green, () => _openTickets({'status': 'resolved,closed'})),
    ];
    return Wrap(children: cards);
  }

  Widget _body(Me me) {
    final wide = screenSize(context) == ScreenSize.desktop;
    final left = <Widget>[
      _statusCard(),
      if (me.isStaff) _workloadCard(),
      _breakdownCard('Active tickets by client', _data!['by_client'] as List, (r) => r['name'].toString(), (r) => _openTickets({'state': 'active', 'organization_id': '${r['organization_id']}'})),
      _breakdownCard('Active tickets by site', _data!['by_site'] as List, (r) => '${r['name']} · ${r['organization']}', (r) => _openTickets({'state': 'active', 'site_id': '${r['site_id']}'})),
    ];
    final right = [_activityCard()];
    if (!wide) return Column(children: [...left, ...right]);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(flex: 3, child: Column(children: left)),
      Expanded(flex: 2, child: Column(children: right)),
    ]);
  }

  Widget _statusCard() {
    final rows = (_data!['by_status'] as List).cast<Map>();
    final prio = (_data!['by_priority'] as List).cast<Map>();
    final max = rows.fold<int>(1, (m, r) => (r['count'] as int) > m ? r['count'] as int : m);
    return SectionCard(
      title: 'Tickets by status',
      child: Column(children: [
        for (final r in rows)
          InkWell(
            onTap: () => _openTickets({'status': r['status'].toString()}),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(width: 150, child: Text(r['label'].toString())),
                Expanded(
                  child: LinearProgressIndicator(
                    value: (r['count'] as int) / max,
                    minHeight: 10,
                    color: statusColor(r['status'].toString()),
                    backgroundColor: Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                SizedBox(width: 48, child: Text('${r['count']}', textAlign: TextAlign.right)),
              ]),
            ),
          ),
        const Divider(),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in prio)
            ActionChip(
              avatar: Icon(Icons.flag, color: priorityColor(p['priority'].toString()), size: 18),
              label: Text('${p['priority']}: ${p['count']}'),
              onPressed: () => _openTickets({'state': 'active', 'priority': p['priority'].toString()}),
            ),
        ]),
      ]),
    );
  }

  Widget _workloadCard() {
    final rows = (_data!['technician_workload'] as List).cast<Map>();
    return SectionCard(
      title: 'Technician workload',
      child: rows.isEmpty
          ? const Text('No technicians yet.')
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 24,
                showCheckboxColumn: false,
                columns: const [
                  DataColumn(label: Text('Technician')),
                  DataColumn(label: Text('Active'), numeric: true),
                  DataColumn(label: Text('In progress'), numeric: true),
                  DataColumn(label: Text('Overdue'), numeric: true),
                  DataColumn(label: Text('Logged (7d)'), numeric: true),
                ],
                rows: [
                  for (final r in rows)
                    DataRow(
                      onSelectChanged: (_) => _openTickets({'state': 'active', 'assigned_to': '${r['user_id']}'}),
                      cells: [
                        DataCell(Text(r['name'].toString())),
                        DataCell(Text('${r['active']}')),
                        DataCell(Text('${r['in_progress']}')),
                        DataCell(Text('${r['overdue']}', style: TextStyle(color: (r['overdue'] as int) > 0 ? Colors.red : null))),
                        DataCell(Text(fmtMinutes(r['minutes_last_7_days'] as int))),
                      ],
                    ),
                ],
              ),
            ),
    );
  }

  Widget _breakdownCard(String title, List rows, String Function(Map) label, void Function(Map) onTap) => SectionCard(
        title: title,
        child: rows.isEmpty
            ? const Text('No active tickets.')
            : Column(children: [
                for (final r in rows.cast<Map>())
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(label(r)),
                    trailing: Text('${r['active']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    onTap: () => onTap(r),
                  ),
              ]),
      );

  Widget _activityCard() {
    final events = (_data!['recent_activity'] as List).map((e) => TicketEvent((e as Map).cast())).toList();
    return SectionCard(
      title: 'Recent activity',
      child: events.isEmpty
          ? const Text('Nothing yet.')
          : Column(children: [
              for (final e in events)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(eventIcon(e.type), size: 20),
                  title: Text('${e.ticket?.name ?? ''} · ${describeEvent(e)}'),
                  subtitle: Text('${e.userName ?? 'System'} · ${fmtRelative(e.createdAt)}'),
                  onTap: e.ticket == null ? null : () => context.go('/tickets/${e.ticket!.id}'),
                ),
            ]),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.icon, this.color, this.onTap);
  final String label;
  final Object? value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: screenSize(context) == ScreenSize.phone ? (MediaQuery.sizeOf(context).width - 16) / 2 : 190,
        child: Card(
          margin: const EdgeInsets.all(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, color: color),
                const SizedBox(height: 8),
                Text('${value ?? 0}', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color, fontWeight: FontWeight.bold)),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ),
        ),
      );
}
