import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/auth_controller.dart';
import '../../core/platform/platform.dart' as platform;
import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _types = {
    'ticket-history': 'Ticket history',
    'technician-activity': 'Technician activity',
    'sla-performance': 'SLA performance',
    'client-monthly': 'Client monthly service report',
  };

  String _type = 'ticket-history';
  DateTimeRange _range = DateTimeRange(start: DateTime(DateTime.now().year, DateTime.now().month), end: DateTime.now());
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int? _orgId;
  int? _userId;
  Lookups? _lookups;
  Json? _report;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    context.services.repo
        .lookups()
        .then((l) {
          if (mounted) setState(() => _lookups = l);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  Map<String, Object?> _query(String format) {
    final f = DateFormat('yyyy-MM-dd');
    return {
      'format': format,
      if (_type == 'client-monthly') 'month': DateFormat('yyyy-MM').format(_month) else ...{'from': f.format(_range.start), 'to': f.format(_range.end)},
      'organization_id': _orgId,
      if (_type == 'technician-activity') 'user_id': _userId,
    };
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await context.services.api.get('reports/$_type', query: _query('json')) as Map;
      setState(() => _report = (res['data'] as Map).cast());
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(String format) async {
    setState(() => _busy = true);
    try {
      final file = await context.services.api.download('reports/$_type', query: _query(format));
      final path = await platform.saveDownload(file.bytes, file.filename, file.contentType);
      if (mounted) showInfo(context, kIsWeb ? 'Downloaded ${file.filename}' : 'Saved to $path');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    final types = Map.of(_types);
    if (me.isClient) types.remove('technician-activity');
    final needsOrg = _type == 'client-monthly' && me.isStaff && _orgId == null;

    return Scaffold(
      appBar: shellAppBar(context, 'Reports'),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'Report', isDense: true),
                  items: [for (final e in types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() {
                    _type = v!;
                    _report = null;
                  }),
                ),
              ),
              if (_type == 'client-monthly')
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_month),
                  label: Text(DateFormat('MMMM yyyy').format(_month)),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _month,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                      helpText: 'Pick any day in the month',
                    );
                    if (d != null) setState(() => _month = DateTime(d.year, d.month));
                  },
                )
              else
                OutlinedButton.icon(
                  icon: const Icon(Icons.date_range),
                  label: Text('${fmtDate(_range.start)} – ${fmtDate(_range.end)}'),
                  onPressed: () async {
                    final r = await showDateRangePicker(context: context, initialDateRange: _range, firstDate: DateTime(2020), lastDate: DateTime.now());
                    if (r != null) setState(() => _range = r);
                  },
                ),
              if (me.isStaff && _lookups != null)
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<int?>(
                    initialValue: _orgId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Client', isDense: true),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All clients')),
                      for (final o in _lookups!.organizations) DropdownMenuItem(value: o['id'] as int, child: Text(o['name'].toString())),
                    ],
                    onChanged: (v) => setState(() => _orgId = v),
                  ),
                ),
              if (_type == 'technician-activity' && me.can('manage_clients') && _lookups != null)
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<int?>(
                    initialValue: _userId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Technician', isDense: true),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All technicians')),
                      for (final t in _lookups!.technicians) DropdownMenuItem(value: t['id'] as int, child: Text(t['name'].toString())),
                    ],
                    onChanged: (v) => setState(() => _userId = v),
                  ),
                ),
              FilledButton.icon(onPressed: _busy || needsOrg ? null : _run, icon: const Icon(Icons.play_arrow), label: const Text('Run')),
              OutlinedButton.icon(
                onPressed: _busy || needsOrg ? null : () => _export('csv'),
                icon: const Icon(Icons.table_view),
                label: const Text('Export CSV'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || needsOrg ? null : () => _export('pdf'),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Export PDF'),
              ),
            ],
          ),
          if (needsOrg) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Select a client for the monthly report.')),
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          if (_error != null) ErrorView(_error!),
          if (_report != null) ..._renderReport(_report!),
        ],
      ),
    );
  }

  List<Widget> _renderReport(Json r) => [
    const SizedBox(height: 16),
    Text(r['title'].toString(), style: Theme.of(context).textTheme.titleLarge),
    Text('Period: ${r['period']}'),
    for (final t in (r['tables'] as List).cast<Map>())
      SectionCard(
        title: t['title'].toString(),
        child: (t['rows'] as List).isEmpty
            ? const Text('No data for this period.')
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [for (final c in (t['columns'] as Map).values) DataColumn(label: Text(c.toString()))],
                  rows: [
                    for (final row in (t['rows'] as List).cast<Map>())
                      DataRow(
                        cells: [
                          for (final k in (t['columns'] as Map).keys)
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 320),
                                child: Text(row[k]?.toString() ?? '', overflow: TextOverflow.ellipsis),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
      ),
  ];
}
