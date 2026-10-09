import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/services.dart';
import '../data/local_store.dart';

extension ServicesX on BuildContext {
  AppServices get services => read<AppServices>();
}

final _dateTime = DateFormat('d MMM yyyy, HH:mm');
final _date = DateFormat('d MMM yyyy');

String fmtDateTime(DateTime? d) => d == null ? '—' : _dateTime.format(d);
String fmtDate(DateTime? d) => d == null ? '—' : _date.format(d);

String fmtRelative(DateTime? d) {
  if (d == null) return '—';
  final diff = DateTime.now().difference(d);
  final future = diff.isNegative;
  final a = diff.abs();
  final text = a.inMinutes < 1
      ? 'just now'
      : a.inHours < 1
          ? '${a.inMinutes}m'
          : a.inDays < 1
              ? '${a.inHours}h'
              : a.inDays < 30
                  ? '${a.inDays}d'
                  : fmtDate(d);
  if (text == 'just now' || a.inDays >= 30) return text;
  return future ? 'in $text' : '$text ago';
}

String fmtMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String errorText(Object e) => e is ApiException ? e.firstError : e.toString();

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(errorText(e)),
    backgroundColor: Theme.of(context).colorScheme.error,
  ));
}

void showInfo(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

Color priorityColor(String p) => switch (p) {
      'critical' => Colors.red.shade700,
      'high' => Colors.orange.shade800,
      'medium' => Colors.blue.shade700,
      _ => Colors.blueGrey,
    };

Color statusColor(String s) => switch (s) {
      'open' => Colors.indigo,
      'assigned' => Colors.blue,
      'in_progress' => Colors.teal,
      'waiting_client' || 'waiting_vendor' => Colors.amber.shade800,
      'resolved' => Colors.green.shade700,
      _ => Colors.grey.shade600,
    };

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, this.label, {super.key});
  final String status;
  final String label;
  @override
  Widget build(BuildContext context) => Pill(label, color: statusColor(status));
}

class PriorityPill extends StatelessWidget {
  const PriorityPill(this.priority, {super.key});
  final String priority;
  @override
  Widget build(BuildContext context) =>
      Pill(priority[0].toUpperCase() + priority.substring(1), color: priorityColor(priority), icon: Icons.flag);
}

/// Shows the delivery state of a locally queued action. Queued items are
/// never presented as delivered.
class OutboxBadge extends StatelessWidget {
  const OutboxBadge(this.item, {super.key});
  final OutboxItem item;

  @override
  Widget build(BuildContext context) => switch (item.status) {
        OutboxStatus.pending => const Pill('Pending sync', color: Colors.orange, icon: Icons.schedule),
        OutboxStatus.syncing => const Pill('Sending…', color: Colors.blue, icon: Icons.sync),
        OutboxStatus.failed => const Pill('Failed', color: Colors.red, icon: Icons.error_outline),
        OutboxStatus.conflict => const Pill('Conflict', color: Colors.deepPurple, icon: Icons.warning_amber),
      };
}

class SyncedBadge extends StatelessWidget {
  const SyncedBadge({super.key});
  @override
  Widget build(BuildContext context) => const Pill('Synced', color: Colors.green, icon: Icons.cloud_done);
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(error is ApiException && (error as ApiException).isNetwork ? Icons.cloud_off : Icons.error_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(errorText(error), textAlign: TextAlign.center),
            if (onRetry != null) ...[const SizedBox(height: 12), FilledButton.tonal(onPressed: onRetry, child: const Text('Retry'))],
          ]),
        ),
      );
}

class EmptyView extends StatelessWidget {
  const EmptyView(this.message, {super.key, this.icon = Icons.inbox_outlined});
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          ]),
        ),
      );
}

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.message = 'Offline — showing saved data. Changes will sync when you reconnect.'});
  final String message;
  @override
  Widget build(BuildContext context) => MaterialBanner(
        backgroundColor: Colors.amber.shade100,
        leading: const Icon(Icons.cloud_off),
        content: Text(message),
        actions: const [SizedBox.shrink()],
      );
}

/// Simple labelled value used on detail pages.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String? value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 140, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: SelectableText(value == null || value!.isEmpty ? '—' : value!)),
        ]),
      );
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.all(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?trailing,
            ]),
            const SizedBox(height: 8),
            child,
          ]),
        ),
      );
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Confirm', bool destructive = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Prompts for a line of text (e.g. a reopen reason). Returns null on cancel.
Future<String?> promptText(BuildContext context, String title, {String label = '', bool required = true, int maxLines = 3, String action = 'Save'}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: maxLines,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: required && ctrl.text.trim().isEmpty ? null : () => Navigator.pop(c, ctrl.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

/// Breakpoints for responsive layouts.
enum ScreenSize { phone, tablet, desktop }

ScreenSize screenSize(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w >= 1100) return ScreenSize.desktop;
  if (w >= 700) return ScreenSize.tablet;
  return ScreenSize.phone;
}
