import 'package:flutter/material.dart';

import '../../data/local_store.dart';
import '../../models/models.dart';
import '../../ui/common.dart';

IconData eventIcon(String type) => switch (type) {
  'created' => Icons.add_circle_outline,
  'assigned' || 'unassigned' => Icons.person_add_alt,
  'status_changed' => Icons.swap_horiz,
  'reopened' => Icons.replay,
  'priority_changed' => Icons.flag,
  'work_logged' => Icons.build_circle_outlined,
  'work_confirmed' => Icons.verified,
  _ when type.startsWith('sla_') => Icons.alarm,
  _ => Icons.edit_note,
};

String _label(String? v) => v == null ? '—' : v.replaceAll('_', ' ');

String describeEvent(TicketEvent e) => switch (e.type) {
  'created' => 'Ticket created',
  'assigned' => 'Assigned to ${e.to}',
  'unassigned' => 'Unassigned from ${e.from}',
  'status_changed' => 'Status: ${_label(e.from)} → ${_label(e.to)}',
  'reopened' => 'Reopened (${_label(e.from)} → ${_label(e.to)})',
  'priority_changed' => 'Priority: ${e.from} → ${e.to}',
  'updated' => 'Updated ${_label(e.field)}${e.to != null ? ' → ${e.to}' : ''}',
  'work_logged' => 'Work logged (${e.to})',
  'work_confirmed' => 'Client confirmed work',
  'sla_response_breached' => 'First-response SLA breached',
  'sla_resolution_warning' => 'Resolution SLA due soon',
  'sla_resolution_breached' => 'Resolution SLA breached',
  'sla_escalated' => 'Escalated to administrators',
  _ => _label(e.type),
};

class TicketTile extends StatelessWidget {
  const TicketTile(this.ticket, {super.key, this.onTap});
  final Ticket ticket;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(t.number, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${t.organization?.name ?? ''} · ${t.site?.name ?? ''}', style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                  ),
                  if (t.unreadCount > 0) Badge(label: Text('${t.unreadCount}'), child: const Icon(Icons.chat_bubble_outline, size: 20)),
                ],
              ),
              const SizedBox(height: 4),
              Text(t.subject, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusPill(t.status, t.statusLabel),
                  PriorityPill(t.priority),
                  if (t.isOverdue) const Pill('Overdue', color: Colors.red, icon: Icons.alarm),
                  if (t.sla.paused && t.isActive) const Pill('SLA paused', color: Colors.grey, icon: Icons.pause_circle_outline),
                  Text(t.assignee?.name ?? 'Unassigned', style: theme.textTheme.bodySmall),
                  Text('· updated ${fmtRelative(t.updatedAt)}', style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A ticket created offline that has not reached the server yet.
class DraftTicketTile extends StatelessWidget {
  const DraftTicketTile(this.item, {super.key, this.onTap});
  final OutboxItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: ListTile(
      onTap: onTap,
      leading: const Icon(Icons.edit_note),
      title: Text(item.payload['subject']?.toString() ?? '(no subject)'),
      subtitle: Text(item.error ?? 'Draft ticket — not yet sent to CyberCraft. Created ${fmtRelative(item.createdAt)}.'),
      trailing: OutboxBadge(item),
    ),
  );
}

class SlaPanel extends StatelessWidget {
  const SlaPanel(this.ticket, {super.key});
  final Ticket ticket;

  @override
  Widget build(BuildContext context) {
    final s = ticket.sla;
    Widget row(String label, DateTime? due, DateTime? done, bool breached) {
      final String state;
      final Color color;
      if (done != null) {
        state = due != null && done.isAfter(due) ? 'Met late' : 'Met';
        color = due != null && done.isAfter(due) ? Colors.red : Colors.green;
      } else if (breached) {
        state = 'Breached';
        color = Colors.red;
      } else if (s.paused) {
        state = 'Paused';
        color = Colors.grey;
      } else {
        state = due == null ? 'No target' : 'Due ${fmtRelative(due)}';
        color = Colors.blueGrey;
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 140, child: Text(label)),
            Expanded(child: Text(fmtDateTime(due))),
            Pill(state, color: color),
          ],
        ),
      );
    }

    return Column(
      children: [
        row('First response', s.responseDue, s.respondedAt, s.responseBreached),
        row('Resolution', s.resolutionDue, ticket.resolvedAt, s.resolutionBreached),
        if (s.escalationLevel > 0) InfoRow('Escalation level', '${s.escalationLevel}'),
      ],
    );
  }
}
