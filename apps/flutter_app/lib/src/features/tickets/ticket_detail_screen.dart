import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../core/auth_controller.dart';
import '../../models/models.dart';
import '../../ui/common.dart';
import 'conversation_view.dart';
import 'ticket_widgets.dart';
import 'work_logs_view.dart';

class TicketDetailScreen extends StatefulWidget {
  const TicketDetailScreen({super.key, required this.ticketId});
  final int ticketId;

  @override
  State<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends State<TicketDetailScreen> {
  Ticket? _ticket;
  bool _fromCache = false;
  Object? _error;
  Lookups? _lookups;
  bool _busy = false;
  int _historyKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = context.services.repo;
    try {
      _lookups ??= await repo.lookups();
      final res = await repo.ticket(widget.ticketId);
      if (!mounted) return;
      setState(() {
        _ticket = res.data;
        _fromCache = res.fromCache;
        _error = null;
        _historyKey++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Runs a server-authoritative ticket change. On a version conflict the
  /// user sees what changed and decides whether to re-apply or discard.
  Future<void> _mutate(String description, Future<Ticket> Function(int version) action) async {
    final current = _ticket!;
    setState(() => _busy = true);
    try {
      final updated = await action(current.version);
      if (!mounted) return;
      setState(() {
        _ticket = updated;
        _historyKey++;
      });
    } on ApiException catch (e) {
      if (e.code == 'version_conflict' && e.body?['current'] is Map) {
        final server = Ticket((e.body!['current'] as Map).cast());
        if (!mounted) return;
        setState(() => _ticket = server);
        final reapply = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Ticket changed by someone else'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your change was not saved because the ticket was updated in the meantime.'),
                const SizedBox(height: 12),
                InfoRow('Status', '${current.statusLabel} → ${server.statusLabel}'),
                InfoRow('Assignee', '${current.assignee?.name ?? 'Unassigned'} → ${server.assignee?.name ?? 'Unassigned'}'),
                InfoRow('Priority', '${current.priority} → ${server.priority}'),
                const SizedBox(height: 12),
                Text('Your change: $description'),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Discard my change')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply my change')),
            ],
          ),
        );
        if (reapply == true) {
          try {
            final updated = await action(server.version);
            if (mounted) setState(() => _ticket = updated);
          } catch (e2) {
            if (mounted) showError(context, e2);
          }
        }
      } else if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticket;
    if (t == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ticket')),
        body: _error != null ? ErrorView(_error!, onRetry: _load) : const Center(child: CircularProgressIndicator()),
      );
    }
    final me = context.watch<AuthController>().me!;
    final canWork = me.can('manage_clients') || (me.role == 'technician' && t.assignee?.id == me.id);
    final wide = screenSize(context) == ScreenSize.desktop;

    final details = _DetailsPane(
      ticket: t,
      me: me,
      lookups: _lookups!,
      canWork: canWork,
      busy: _busy || _fromCache,
      historyKey: _historyKey,
      onMutate: _mutate,
    );
    final chat = ConversationView(key: ValueKey('chat-${t.id}'), ticket: t, onTicketChanged: _load);
    final work = WorkLogsView(key: ValueKey('work-${t.id}'), ticket: t, canLogWork: canWork, onChanged: _load);

    final title = Text('${t.number} · ${t.subject}', overflow: TextOverflow.ellipsis);
    final refresh = IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh');

    if (wide) {
      return DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(title: title, actions: [refresh]),
          body: Column(
            children: [
              if (_fromCache) const OfflineBanner(message: 'Offline — ticket actions are disabled until you reconnect.'),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        children: [
                          const TabBar(
                            tabs: [
                              Tab(text: 'Details'),
                              Tab(text: 'Work'),
                              Tab(text: 'History'),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                details,
                                work,
                                _HistoryView(key: ValueKey('h$_historyKey'), ticketId: t.id),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 4, child: chat),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: title,
          actions: [refresh],
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(
                child: Badge(isLabelVisible: t.unreadCount > 0, label: Text('${t.unreadCount}'), child: const Text('Conversation')),
              ),
              const Tab(text: 'Details'),
              const Tab(text: 'Work'),
              const Tab(text: 'History'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (_fromCache) const OfflineBanner(message: 'Offline — ticket actions are disabled until you reconnect.'),
            Expanded(
              child: TabBarView(
                children: [
                  chat,
                  details,
                  work,
                  _HistoryView(key: ValueKey('h$_historyKey'), ticketId: t.id),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailsPane extends StatelessWidget {
  const _DetailsPane({
    required this.ticket,
    required this.me,
    required this.lookups,
    required this.canWork,
    required this.busy,
    required this.historyKey,
    required this.onMutate,
  });
  final Ticket ticket;
  final Me me;
  final Lookups lookups;
  final bool canWork;
  final bool busy;
  final int historyKey;
  final Future<void> Function(String description, Future<Ticket> Function(int version) action) onMutate;

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final repo = context.services.repo;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        SectionCard(
          title: t.subject,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  StatusPill(t.status, t.statusLabel),
                  PriorityPill(t.priority),
                  if (t.isOverdue) const Pill('Overdue', color: Colors.red, icon: Icons.alarm),
                  if (t.reopenCount > 0) Pill('Reopened ×${t.reopenCount}', color: Colors.deepOrange, icon: Icons.replay),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(t.description),
            ],
          ),
        ),
        SectionCard(title: 'Actions', child: _actions(context, repo)),
        if (t.resolutionNotes != null && t.resolutionNotes!.isNotEmpty) SectionCard(title: 'Resolution', child: SelectableText(t.resolutionNotes!)),
        SectionCard(
          title: 'Details',
          child: Column(
            children: [
              InfoRow('Ticket', t.number),
              InfoRow('Client', t.organization?.name),
              InfoRow('Site', t.site?.name),
              InfoRow('Department', t.department?.name),
              InfoRow('Equipment', t.equipment?.name),
              InfoRow('Category', t.category?.name),
              InfoRow('Requester', t.requester?.name),
              InfoRow('Technician', t.assignee?.name ?? 'Unassigned'),
              InfoRow('Created', fmtDateTime(t.createdAt)),
              InfoRow('Resolved', fmtDateTime(t.resolvedAt)),
              InfoRow('Closed', fmtDateTime(t.closedAt)),
            ],
          ),
        ),
        SectionCard(title: 'SLA', child: SlaPanel(t)),
      ],
    );
  }

  Widget _actions(BuildContext context, repo) {
    final t = ticket;
    final buttons = <Widget>[];
    final transitions = lookups.transitionsFor(t.status);

    if (me.isStaff && t.isActive && (me.can('assign_tickets') || (me.can('self_assign') && (t.assignee == null || t.assignee!.id == me.id)))) {
      buttons.add(
        OutlinedButton.icon(
          onPressed: busy ? null : () => _assign(context),
          icon: const Icon(Icons.person_add_alt),
          label: Text(t.assignee == null ? 'Assign' : 'Reassign'),
        ),
      );
    }
    if (canWork) {
      for (final s in transitions) {
        if (s == 'resolved') {
          buttons.add(FilledButton.icon(onPressed: busy ? null : () => _resolve(context), icon: const Icon(Icons.check_circle), label: const Text('Resolve')));
        } else {
          buttons.add(
            OutlinedButton(
              onPressed: busy ? null : () => onMutate('Set status to ${lookups.statusLabel(s)}', (v) => context.services.repo.changeStatus(t, s, version: v)),
              child: Text(_actionLabel(s)),
            ),
          );
        }
      }
      if (t.isActive) {
        buttons.add(
          OutlinedButton.icon(onPressed: busy ? null : () => _priority(context), icon: const Icon(Icons.flag_outlined), label: const Text('Priority')),
        );
      }
    }
    final isOwner = me.isClient && (t.requester?.id == me.id || me.role == 'client_admin');
    if (isOwner && t.status == 'resolved') {
      buttons.add(
        FilledButton.icon(
          onPressed: busy ? null : () => onMutate('Accept resolution and close', (v) => context.services.repo.changeStatus(t, 'closed', version: v)),
          icon: const Icon(Icons.done_all),
          label: const Text('Accept & close'),
        ),
      );
    }
    if (!t.isActive && (canWork || isOwner)) {
      buttons.add(OutlinedButton.icon(onPressed: busy ? null : () => _reopen(context), icon: const Icon(Icons.replay), label: const Text('Reopen')));
    }
    if (buttons.isEmpty) {
      return Text(
        me.isClient
            ? 'CyberCraft support is handling this ticket. Use the conversation to add information.'
            : 'This ticket is assigned to another technician. Ask a support manager to reassign it.',
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  String _actionLabel(String status) => switch (status) {
    'in_progress' => 'Start work',
    'waiting_client' => 'Wait for client',
    'waiting_vendor' => 'Wait for vendor',
    'closed' => 'Close',
    _ => lookups.statusLabel(status),
  };

  Future<void> _assign(BuildContext context) async {
    final options = me.can('assign_tickets') ? lookups.technicians : lookups.technicians.where((u) => u['id'] == me.id).toList();
    final selected = await showDialog<int?>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Assign technician'),
        children: [
          if (me.can('assign_tickets') && ticket.assignee != null) SimpleDialogOption(onPressed: () => Navigator.pop(c, -1), child: const Text('Unassign')),
          for (final u in options)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, u['id'] as int), child: Text('${u['name']}${u['id'] == me.id ? ' (me)' : ''}')),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    final userId = selected == -1 ? null : selected;
    await onMutate(userId == null ? 'Unassign' : 'Assign technician', (v) => context.services.repo.assign(_withVersion(v), userId));
  }

  Ticket _withVersion(int v) => Ticket({...ticket.json, 'version': v});

  Future<void> _resolve(BuildContext context) async {
    final notes = await promptText(context, 'Resolve ticket', label: 'Resolution notes (visible to client)', maxLines: 5, action: 'Resolve');
    if (notes == null || !context.mounted) return;
    await onMutate('Resolve', (v) => context.services.repo.changeStatus(ticket, 'resolved', resolutionNotes: notes, version: v));
  }

  Future<void> _reopen(BuildContext context) async {
    final reason = await promptText(context, 'Reopen ticket', label: 'Why is it being reopened?', action: 'Reopen');
    if (reason == null || !context.mounted) return;
    await onMutate('Reopen', (v) => context.services.repo.reopen(ticket, reason, version: v));
  }

  Future<void> _priority(BuildContext context) async {
    final p = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Change priority'),
        children: [
          for (final p in lookups.priorities) SimpleDialogOption(onPressed: () => Navigator.pop(c, p['value'] as String), child: Text(p['label'].toString())),
        ],
      ),
    );
    if (p == null || p == ticket.priority || !context.mounted) return;
    await onMutate('Change priority to $p', (v) => context.services.repo.updateTicket(ticket, {'priority': p}, version: v));
  }
}

class _HistoryView extends StatefulWidget {
  const _HistoryView({super.key, required this.ticketId});
  final int ticketId;
  @override
  State<_HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<_HistoryView> {
  List<TicketEvent>? _events;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await context.services.repo.history(widget.ticketId);
      if (mounted) setState(() => _events = res.data.reversed.toList());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return ErrorView(_error!, onRetry: _load);
    final events = _events;
    if (events == null) return const Center(child: CircularProgressIndicator());
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: events.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = events[i];
        return ListTile(
          leading: Icon(eventIcon(e.type)),
          title: Text(describeEvent(e)),
          subtitle: Text([e.userName ?? 'System', fmtDateTime(e.createdAt), if (e.note != null && e.note!.isNotEmpty) '“${e.note}”'].join(' · ')),
          trailing: e.isInternal ? const Icon(Icons.lock_outline, size: 16) : null,
        );
      },
    );
  }
}
