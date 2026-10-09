import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';
import '../../ui/entity_form.dart';

/// SLA policies and ticket categories (managers/administrators).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Json>? _policies;
  List<Json>? _categories;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Json> _list(Object res) => ((res as Map)['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _load() async {
    final services = context.services;
    try {
      final p = await services.api.get('sla-policies');
      final c = await services.api.get('categories');
      if (!mounted) return;
      setState(() {
        _policies = _list(p);
        _categories = _list(c);
        _error = null;
      });
      services.repo.lookups(refresh: true).ignore();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _editPolicy([Json? policy]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SlaPolicyDialog(policy: policy),
    );
    if (saved == true) _load();
  }

  Future<void> _editCategory([Json? category]) async {
    final api = context.services.api;
    final res = await showEntityForm(
      context,
      title: category == null ? 'New category' : 'Edit category',
      initial: category ?? {'is_active': true},
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('is_active', 'Active', type: FieldType.boolean),
      ],
      onSave: (v) async =>
          ((category == null ? await api.post('categories', body: v) : await api.patch('categories/${category['id']}', body: v)) as Map)['data'] as Json,
    );
    if (res != null) _load();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: shellAppBar(
        context,
        'Settings',
        bottom: const TabBar(
          tabs: [
            Tab(text: 'SLA policies'),
            Tab(text: 'Categories'),
          ],
        ),
      ),
      body: _error != null
          ? ErrorView(_error!, onRetry: _load)
          : _policies == null
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              children: [
                Scaffold(
                  floatingActionButton: FloatingActionButton.extended(
                    heroTag: 'sla',
                    onPressed: () => _editPolicy(),
                    icon: const Icon(Icons.add),
                    label: const Text('New policy'),
                  ),
                  body: ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      for (final p in _policies!)
                        SectionCard(
                          title: '${p['name']}${p['is_default'] == true ? ' (default)' : ''}',
                          trailing: TextButton.icon(onPressed: () => _editPolicy(p), icon: const Icon(Icons.edit), label: const Text('Edit')),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              InfoRow('Timezone', p['timezone']?.toString()),
                              InfoRow('Business hours', p['business_hours'] == null ? '24x7' : _hoursSummary((p['business_hours'] as Map).cast())),
                              InfoRow('Pauses on', ((p['pause_statuses'] as List?) ?? []).join(', ')),
                              InfoRow('Warning at', '${p['warning_percent']}% of resolution time'),
                              const SizedBox(height: 8),
                              Table(
                                columnWidths: const {0: FixedColumnWidth(110)},
                                children: [
                                  const TableRow(
                                    children: [
                                      Text('Priority', style: TextStyle(fontWeight: FontWeight.bold)),
                                      Text('Response', style: TextStyle(fontWeight: FontWeight.bold)),
                                      Text('Resolution', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  for (final t in (p['targets'] as List).cast<Map>())
                                    TableRow(
                                      children: [
                                        Text(t['priority'].toString()),
                                        Text(fmtMinutes(t['response_minutes'] as int)),
                                        Text(fmtMinutes(t['resolution_minutes'] as int)),
                                      ],
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Scaffold(
                  floatingActionButton: FloatingActionButton.extended(
                    heroTag: 'cat',
                    onPressed: () => _editCategory(),
                    icon: const Icon(Icons.add),
                    label: const Text('New category'),
                  ),
                  body: ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      for (final c in _categories!)
                        ListTile(
                          leading: Icon(c['is_active'] == true ? Icons.label_outline : Icons.label_off_outlined),
                          title: Text(c['name'].toString()),
                          subtitle: c['is_active'] == true ? null : const Text('Inactive'),
                          trailing: const Icon(Icons.edit_outlined),
                          onTap: () => _editCategory(c),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );

  static String _hoursSummary(Json hours) =>
      hours.entries.where((e) => (e.value as List).isNotEmpty).map((e) => '${e.key} ${(e.value as List).map((i) => '${i[0]}-${i[1]}').join(',')}').join('; ');
}

const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _priorities = ['critical', 'high', 'medium', 'low'];

class _SlaPolicyDialog extends StatefulWidget {
  const _SlaPolicyDialog({this.policy});
  final Json? policy;
  @override
  State<_SlaPolicyDialog> createState() => _SlaPolicyDialogState();
}

class _SlaPolicyDialogState extends State<_SlaPolicyDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _tz;
  late final TextEditingController _warning;
  late final TextEditingController _holidays;
  late bool _isDefault;
  late bool _twentyFourSeven;
  late Set<String> _pause;
  final _open = <String, TextEditingController>{};
  final _close = <String, TextEditingController>{};
  final _enabled = <String, bool>{};
  final _response = <String, TextEditingController>{};
  final _resolution = <String, TextEditingController>{};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = widget.policy ?? {};
    _name = TextEditingController(text: p['name']?.toString() ?? '');
    _tz = TextEditingController(text: p['timezone']?.toString() ?? 'UTC');
    _warning = TextEditingController(text: '${p['warning_percent'] ?? 80}');
    _holidays = TextEditingController(text: ((p['holidays'] as List?) ?? []).join(', '));
    _isDefault = p['is_default'] == true;
    final hours = (p['business_hours'] as Map?)?.cast<String, dynamic>();
    _twentyFourSeven = widget.policy != null && hours == null;
    _pause = {
      ...((p['pause_statuses'] as List?) ?? ['waiting_client']).cast<String>(),
    };
    for (final d in _days) {
      final intervals =
          (hours?[d] as List?) ??
          (widget.policy == null && !['sat', 'sun'].contains(d)
              ? [
                  ['09:00', '18:00'],
                ]
              : []);
      _enabled[d] = intervals.isNotEmpty;
      _open[d] = TextEditingController(text: intervals.isNotEmpty ? intervals.first[0].toString() : '09:00');
      _close[d] = TextEditingController(text: intervals.isNotEmpty ? intervals.first[1].toString() : '18:00');
    }
    final targets = {for (final t in ((p['targets'] as List?) ?? []).cast<Map>()) t['priority']: t};
    const defaults = {
      'critical': [30, 240],
      'high': [60, 480],
      'medium': [240, 1440],
      'low': [480, 2880],
    };
    for (final pr in _priorities) {
      _response[pr] = TextEditingController(text: '${targets[pr]?['response_minutes'] ?? defaults[pr]![0]}');
      _resolution[pr] = TextEditingController(text: '${targets[pr]?['resolution_minutes'] ?? defaults[pr]![1]}');
    }
  }

  String? _time(String? v) => v != null && RegExp(r'^([01]\d|2[0-3]):[0-5]\d$|^24:00$').hasMatch(v) ? null : 'HH:MM';
  String? _int(String? v) => (int.tryParse(v ?? '') ?? 0) > 0 ? null : '> 0';

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final body = {
      'name': _name.text.trim(),
      'timezone': _tz.text.trim(),
      'is_default': _isDefault,
      'warning_percent': int.parse(_warning.text),
      'pause_statuses': _pause.toList(),
      'holidays': _holidays.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      'business_hours': _twentyFourSeven
          ? null
          : {
              for (final d in _days)
                d: _enabled[d]!
                    ? [
                        [_open[d]!.text, _close[d]!.text],
                      ]
                    : [],
            },
      'targets': [
        for (final p in _priorities) {'priority': p, 'response_minutes': int.parse(_response[p]!.text), 'resolution_minutes': int.parse(_resolution[p]!.text)},
      ],
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = context.services.api;
      if (widget.policy == null) {
        await api.post('sla-policies', body: body);
      } else {
        await api.patch('sla-policies/${widget.policy!['id']}', body: body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.policy == null ? 'New SLA policy' : 'Edit SLA policy'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => v!.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _tz,
                decoration: const InputDecoration(labelText: 'Timezone (IANA, e.g. Asia/Karachi)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Default policy'),
                value: _isDefault,
                onChanged: (v) => setState(() => _isDefault = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('24x7 (ignore business hours)'),
                value: _twentyFourSeven,
                onChanged: (v) => setState(() => _twentyFourSeven = v),
              ),
              if (!_twentyFourSeven)
                for (final d in _days)
                  Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(d),
                          value: _enabled[d],
                          onChanged: (v) => setState(() => _enabled[d] = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 90,
                        child: TextFormField(
                          controller: _open[d],
                          enabled: _enabled[d],
                          decoration: const InputDecoration(isDense: true, labelText: 'Open'),
                          validator: _enabled[d]! ? _time : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 90,
                        child: TextFormField(
                          controller: _close[d],
                          enabled: _enabled[d],
                          decoration: const InputDecoration(isDense: true, labelText: 'Close'),
                          validator: _enabled[d]! ? _time : null,
                        ),
                      ),
                    ],
                  ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _holidays,
                decoration: const InputDecoration(labelText: 'Holidays (YYYY-MM-DD, comma separated)'),
              ),
              const SizedBox(height: 8),
              const Text('Pause the SLA clock while:'),
              CheckboxListTile(
                dense: true,
                title: const Text('Waiting for Client'),
                value: _pause.contains('waiting_client'),
                onChanged: (v) => setState(() => v! ? _pause.add('waiting_client') : _pause.remove('waiting_client')),
              ),
              CheckboxListTile(
                dense: true,
                title: const Text('Waiting for Vendor'),
                value: _pause.contains('waiting_vendor'),
                onChanged: (v) => setState(() => v! ? _pause.add('waiting_vendor') : _pause.remove('waiting_vendor')),
              ),
              TextFormField(
                controller: _warning,
                decoration: const InputDecoration(labelText: 'Warn when this % of resolution time has elapsed'),
                validator: _int,
              ),
              const SizedBox(height: 12),
              const Text('Targets (business minutes)', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final p in _priorities)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(width: 90, child: Text(p)),
                      Expanded(
                        child: TextFormField(
                          controller: _response[p],
                          decoration: const InputDecoration(isDense: true, labelText: 'Response'),
                          validator: _int,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          controller: _resolution[p],
                          decoration: const InputDecoration(isDense: true, labelText: 'Resolution'),
                          validator: _int,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
    ],
  );
}
