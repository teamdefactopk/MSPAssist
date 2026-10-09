import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth_controller.dart';
import '../../data/local_store.dart';
import '../../models/models.dart';
import '../../sync/sync_service.dart';
import '../../ui/common.dart';
import 'attachments.dart';

/// Work logs, onsite visits, photos and client confirmation for a ticket.
class WorkLogsView extends StatefulWidget {
  const WorkLogsView({super.key, required this.ticket, required this.canLogWork, required this.onChanged});
  final Ticket ticket;
  final bool canLogWork;
  final VoidCallback onChanged;

  @override
  State<WorkLogsView> createState() => _WorkLogsViewState();
}

class _WorkLogsViewState extends State<WorkLogsView> {
  List<WorkLog>? _logs;
  bool _fromCache = false;
  Object? _error;
  StreamSubscription<SyncEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = context.services.sync.events.listen((e) {
      if (e.item.ticketUuid == widget.ticket.uuid && (e.item.kind == 'create_work_log' || e.item.kind == 'upload_attachment')) {
        _load();
        widget.onChanged();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await context.services.repo.workLogs(widget.ticket.id);
      if (mounted) {
        setState(() {
          _logs = res.data;
          _fromCache = res.fromCache;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _confirm(WorkLog log) async {
    final note = await promptText(context, 'Confirm work completed', label: 'Comment (optional)', required: false, action: 'Confirm');
    if (note == null || !mounted) return;
    try {
      await context.services.api.post('work-logs/${log.id}/confirm', body: {'note': note});
      await _load();
      widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(WorkLog log) async {
    if (!await confirm(context, 'Delete work log?', 'This removes ${fmtMinutes(log.minutes)} from the ticket.', action: 'Delete', destructive: true)) return;
    if (!mounted) return;
    try {
      await context.services.api.delete('work-logs/${log.id}');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me!;
    final queued = context.watch<SyncService>().items.where((i) => i.kind == 'create_work_log' && i.ticketUuid == widget.ticket.uuid).toList();
    final logs = _logs;
    final total = (logs ?? []).fold<int>(0, (s, l) => s + l.minutes);

    return Scaffold(
      floatingActionButton: widget.canLogWork && widget.ticket.status != 'closed'
          ? FloatingActionButton.extended(
              heroTag: 'log-work',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => WorkLogForm(ticket: widget.ticket),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Log work'),
            )
          : null,
      body: _error != null && logs == null
          ? ErrorView(_error!, onRetry: _load)
          : logs == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 88), children: [
                    if (_fromCache) const OfflineBanner(),
                    ListTile(title: const Text('Total time logged'), trailing: Text(fmtMinutes(total), style: const TextStyle(fontWeight: FontWeight.bold))),
                    for (final q in queued)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.schedule),
                          title: Text('${q.payload['type']} · ${fmtMinutes((q.payload['minutes'] as int?) ?? 0)}'),
                          subtitle: Text('${q.payload['description']}${q.error != null ? '\n${q.error}' : ''}'),
                          trailing: OutboxBadge(q),
                        ),
                      ),
                    if (logs.isEmpty && queued.isEmpty) const EmptyView('No work logged yet.', icon: Icons.build_outlined),
                    for (final l in logs) _logCard(l, me),
                  ]),
                ),
    );
  }

  Widget _logCard(WorkLog l, Me me) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(switch (l.type) { 'onsite' => Icons.directions_car, 'phone' => Icons.phone, 'workshop' => Icons.handyman, _ => Icons.computer }),
              const SizedBox(width: 8),
              Expanded(child: Text('${l.type[0].toUpperCase()}${l.type.substring(1)} · ${fmtMinutes(l.minutes)} · ${l.userName}', style: const TextStyle(fontWeight: FontWeight.w600))),
              if (!l.isConfirmed && (me.can('manage_clients') || l.userId == me.id))
                IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(l)),
            ]),
            Text('${fmtDateTime(l.startedAt)}${l.endedAt != null ? ' – ${fmtDateTime(l.endedAt)}' : ''}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            SelectableText(l.description),
            if (l.attachments.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [for (final a in l.attachments) AttachmentChip(a)])),
            const SizedBox(height: 6),
            if (l.isConfirmed)
              Pill('Confirmed by ${l.confirmedBy} · ${fmtDate(l.confirmedAt)}${l.confirmationNote?.isNotEmpty == true ? ' — "${l.confirmationNote}"' : ''}',
                  color: Colors.green, icon: Icons.verified)
            else if (l.confirmationName != null)
              Pill('Signed off onsite by ${l.confirmationName}', color: Colors.teal, icon: Icons.how_to_reg)
            else if (me.isClient)
              FilledButton.tonalIcon(onPressed: () => _confirm(l), icon: const Icon(Icons.verified_outlined), label: const Text('Confirm work completed'))
            else
              const Pill('Awaiting client confirmation', color: Colors.grey),
          ]),
        ),
      );
}

/// Bottom-sheet form; saves through the outbox so it works offline.
class WorkLogForm extends StatefulWidget {
  const WorkLogForm({super.key, required this.ticket});
  final Ticket ticket;
  @override
  State<WorkLogForm> createState() => _WorkLogFormState();
}

class _WorkLogFormState extends State<WorkLogForm> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _minutes = TextEditingController(text: '30');
  final _confirmName = TextEditingController();
  String _type = 'remote';
  DateTime _start = DateTime.now().subtract(const Duration(minutes: 30));
  DateTime? _end;
  final List<PickedUpload> _photos = [];
  bool _busy = false;

  Future<void> _pickStart() async {
    final d = await showDatePicker(context: context, initialDate: _start, firstDate: DateTime.now().subtract(const Duration(days: 60)), lastDate: DateTime.now());
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (t == null) return;
    setState(() => _start = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _pickEnd() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_end ?? DateTime.now()));
    if (t == null) return;
    setState(() {
      _end = DateTime(_start.year, _start.month, _start.day, t.hour, t.minute);
      if (_end!.isAfter(_start)) _minutes.text = '${_end!.difference(_start).inMinutes}';
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final sync = context.services.sync;
    final t = widget.ticket;
    final id = const Uuid().v4();
    try {
      await sync.enqueue(OutboxItem(
        id: id,
        kind: 'create_work_log',
        ticketUuid: t.uuid,
        payload: {
          'uuid': id,
          'ticket_id': t.id,
          'type': _type,
          'started_at': _start.toUtc().toIso8601String(),
          if (_end != null) 'ended_at': _end!.toUtc().toIso8601String(),
          'minutes': int.parse(_minutes.text),
          'description': _description.text.trim(),
          if (_confirmName.text.trim().isNotEmpty) 'client_confirmation_name': _confirmName.text.trim(),
        },
      ));
      if (_photos.isNotEmpty) await queueUploads(sync, _photos, ticketUuid: t.uuid, ticketId: t.id, workLogUuid: id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text('Log work · ${widget.ticket.number}', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'remote', label: Text('Remote'), icon: Icon(Icons.computer)),
                  ButtonSegment(value: 'onsite', label: Text('Onsite'), icon: Icon(Icons.directions_car)),
                  ButtonSegment(value: 'phone', label: Text('Phone'), icon: Icon(Icons.phone)),
                  ButtonSegment(value: 'workshop', label: Text('Workshop'), icon: Icon(Icons.handyman)),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                OutlinedButton.icon(onPressed: _pickStart, icon: const Icon(Icons.schedule), label: Text('Start: ${fmtDateTime(_start)}')),
                OutlinedButton.icon(onPressed: _pickEnd, icon: const Icon(Icons.schedule_send), label: Text('End: ${_end == null ? 'not set' : fmtDateTime(_end)}')),
                SizedBox(
                  width: 140,
                  child: TextFormField(
                    controller: _minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Minutes', isDense: true),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 1440 ? '1–1440' : null;
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'Work performed *', alignLabelWithHint: true),
                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              if (_type == 'onsite') ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirmName,
                  decoration: const InputDecoration(labelText: 'Client representative who signed off (optional)'),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in _photos) PendingUploadChip(p, onRemove: () => setState(() => _photos.remove(p))),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await pickUploads(context, imagesOnly: true);
                    setState(() => _photos.addAll(picked));
                  },
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Add photos'),
                ),
                if (cameraAvailable)
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await pickUploads(context, camera: true);
                      setState(() => _photos.addAll(picked));
                    },
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('Take photo'),
                  ),
              ]),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : _save, child: const Text('Save work log')),
              const SizedBox(height: 4),
              const Text('Saved on this device first and synced automatically — works offline.', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ),
      );
}
