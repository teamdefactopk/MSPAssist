import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth_controller.dart';
import '../../data/local_store.dart';
import '../../models/models.dart';
import '../../ui/common.dart';
import 'attachments.dart';

/// New ticket form. Submissions always go through the outbox, so a ticket
/// written offline is kept as a draft and sent automatically later.
class TicketFormScreen extends StatefulWidget {
  const TicketFormScreen({super.key, this.organizationId});
  final int? organizationId;

  @override
  State<TicketFormScreen> createState() => _TicketFormScreenState();
}

class _TicketFormScreenState extends State<TicketFormScreen> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _description = TextEditingController();
  final _uuid = const Uuid().v4();
  Lookups? _lookups;
  Object? _error;
  int? _orgId;
  int? _siteId;
  int? _departmentId;
  int? _equipmentId;
  int? _categoryId;
  int? _assigneeId;
  String _priority = 'medium';
  List<Json> _departments = [];
  List<Json> _equipment = [];
  final List<PickedUpload> _files = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = context.read<AuthController>().me!;
    try {
      final lookups = await context.services.repo.lookups();
      setState(() {
        _lookups = lookups;
        _orgId = widget.organizationId ?? (me.isClient ? me.organizationId : null);
        if (_orgId == null && lookups.organizations.length == 1) _orgId = lookups.organizations.first['id'] as int;
        final sites = _sites();
        if (sites.length == 1) _siteId = sites.first['id'] as int;
      });
      await _loadOrgData();
    } catch (e) {
      setState(() => _error = e);
    }
  }

  List<Json> _sites() => (_lookups?.sites ?? []).where((s) => s['organization_id'] == _orgId).toList();

  Future<void> _loadOrgData() async {
    final org = _orgId;
    if (org == null) return;
    final repo = context.services.repo;
    try {
      final d = await repo.getCached('organizations/$org/departments', cacheKey: 'departments:$org');
      final e = await repo.getCached('organizations/$org/equipment', cacheKey: 'equipment:$org');
      if (!mounted || org != _orgId) return;
      setState(() {
        _departments = (d.data['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _equipment = (e.data['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
      });
    } catch (_) {
      // Optional fields; the form still works without them (e.g. offline with no cache).
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final services = context.services;
    final me = context.read<AuthController>().me!;
    try {
      await services.sync.enqueue(
        OutboxItem(
          id: _uuid,
          kind: 'create_ticket',
          ticketUuid: _uuid,
          payload: {
            'uuid': _uuid,
            'organization_id': _orgId,
            'site_id': _siteId,
            'department_id': ?_departmentId,
            'equipment_id': ?_equipmentId,
            'category_id': ?_categoryId,
            'priority': _priority,
            'subject': _subject.text.trim(),
            'description': _description.text.trim(),
            'source': kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS ? 'mobile' : 'desktop'),
            if (_assigneeId != null && me.can('assign_tickets')) 'assigned_to': _assigneeId,
          },
        ),
      );
      if (_files.isNotEmpty) {
        final ids = await queueUploads(services.sync, _files, ticketUuid: _uuid);
        await services.sync.enqueue(
          OutboxItem(
            id: const Uuid().v4(),
            kind: 'send_message',
            ticketUuid: _uuid,
            payload: {'uuid': const Uuid().v4(), 'body': 'Attached ${_files.length} file(s).', 'attachment_uuids': ids, 'depends_on': ids},
          ),
        );
      }
      await services.sync.syncNow(force: true);
      if (!mounted) return;
      final stillQueued = services.sync.items.where((i) => i.id == _uuid).firstOrNull;
      if (stillQueued == null) {
        final mapped = await services.store.getJson('ticketmap:$_uuid');
        if (!mounted) return;
        showInfo(context, 'Ticket created.');
        context.go(mapped == null ? '/tickets' : '/tickets/${mapped['id']}');
      } else if (stillQueued.status == OutboxStatus.pending) {
        showInfo(context, 'You appear to be offline. The ticket is saved as a draft and will be sent automatically.');
        context.go('/tickets');
      } else {
        showError(context, stillQueued.error ?? 'The ticket could not be created.');
        // Keep the user on the form so they can correct it; remove the failed draft.
        await services.sync.discard(stillQueued);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    return Scaffold(
      appBar: AppBar(title: const Text('New ticket')),
      body: _error != null
          ? ErrorView(_error!, onRetry: _load)
          : _lookups == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Form(
                  key: _form,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (me.isStaff)
                        DropdownButtonFormField<int>(
                          initialValue: _orgId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Client *'),
                          items: [for (final o in _lookups!.organizations) DropdownMenuItem(value: o['id'] as int, child: Text(o['name'].toString()))],
                          validator: (v) => v == null ? 'Select a client' : null,
                          onChanged: (v) {
                            setState(() {
                              _orgId = v;
                              _siteId = null;
                              _departmentId = null;
                              _equipmentId = null;
                              _departments = [];
                              _equipment = [];
                            });
                            _loadOrgData();
                          },
                        ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        key: ValueKey('site-$_orgId'),
                        initialValue: _siteId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Site *'),
                        items: [for (final s in _sites()) DropdownMenuItem(value: s['id'] as int, child: Text(s['name'].toString()))],
                        validator: (v) => v == null ? 'Select a site' : null,
                        onChanged: (v) => setState(() {
                          _siteId = v;
                          _equipmentId = null;
                        }),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: 230,
                            child: DropdownButtonFormField<String>(
                              initialValue: _priority,
                              decoration: const InputDecoration(labelText: 'Priority'),
                              items: [for (final p in _lookups!.priorities) DropdownMenuItem(value: p['value'] as String, child: Text(p['label'].toString()))],
                              onChanged: (v) => setState(() => _priority = v ?? 'medium'),
                            ),
                          ),
                          SizedBox(
                            width: 230,
                            child: DropdownButtonFormField<int?>(
                              initialValue: _categoryId,
                              isExpanded: true,
                              decoration: const InputDecoration(labelText: 'Category'),
                              items: [
                                const DropdownMenuItem(value: null, child: Text('—')),
                                for (final c in _lookups!.categories) DropdownMenuItem(value: c['id'] as int, child: Text(c['name'].toString())),
                              ],
                              onChanged: (v) => setState(() => _categoryId = v),
                            ),
                          ),
                          if (_departments.isNotEmpty)
                            SizedBox(
                              width: 230,
                              child: DropdownButtonFormField<int?>(
                                key: ValueKey('dept-$_orgId'),
                                initialValue: _departmentId,
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Department'),
                                items: [
                                  const DropdownMenuItem(value: null, child: Text('—')),
                                  for (final d in _departments) DropdownMenuItem(value: d['id'] as int, child: Text(d['name'].toString())),
                                ],
                                onChanged: (v) => setState(() => _departmentId = v),
                              ),
                            ),
                          if (_equipment.isNotEmpty)
                            SizedBox(
                              width: 300,
                              child: DropdownButtonFormField<int?>(
                                key: ValueKey('eq-$_orgId-$_siteId'),
                                initialValue: _equipmentId,
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Equipment (optional)'),
                                items: [
                                  const DropdownMenuItem(value: null, child: Text('—')),
                                  for (final e in _equipment.where((e) => _siteId == null || e['site_id'] == null || e['site_id'] == _siteId))
                                    DropdownMenuItem(value: e['id'] as int, child: Text('${e['name']}${e['asset_tag'] != null ? ' (${e['asset_tag']})' : ''}')),
                                ],
                                onChanged: (v) => setState(() => _equipmentId = v),
                              ),
                            ),
                          if (me.can('assign_tickets'))
                            SizedBox(
                              width: 230,
                              child: DropdownButtonFormField<int?>(
                                initialValue: _assigneeId,
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Assign to'),
                                items: [
                                  const DropdownMenuItem(value: null, child: Text('Unassigned')),
                                  for (final t in _lookups!.technicians) DropdownMenuItem(value: t['id'] as int, child: Text(t['name'].toString())),
                                ],
                                onChanged: (v) => setState(() => _assigneeId = v),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _subject,
                        maxLength: 200,
                        decoration: const InputDecoration(labelText: 'Subject *'),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                      ),
                      TextFormField(
                        controller: _description,
                        minLines: 5,
                        maxLines: 12,
                        decoration: const InputDecoration(labelText: 'Description *', alignLabelWithHint: true),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Describe the problem' : null,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final f in _files) PendingUploadChip(f, onRemove: () => setState(() => _files.remove(f))),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await pickUploads(context);
                              setState(() => _files.addAll(picked));
                            },
                            icon: const Icon(Icons.attach_file),
                            label: const Text('Attach files'),
                          ),
                          if (cameraAvailable)
                            OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await pickUploads(context, camera: true);
                                setState(() => _files.addAll(picked));
                              },
                              icon: const Icon(Icons.photo_camera),
                              label: const Text('Take photo'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                        label: const Text('Submit ticket'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'If you are offline, the ticket is kept as a draft on this device and sent automatically when the connection returns.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
