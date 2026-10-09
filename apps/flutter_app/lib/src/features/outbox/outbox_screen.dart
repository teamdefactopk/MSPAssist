import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_store.dart';
import '../../sync/sync_service.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';

/// Everything waiting to reach the server, with its state and actions.
class OutboxScreen extends StatelessWidget {
  const OutboxScreen({super.key});

  static String describe(OutboxItem i) => switch (i.kind) {
    'create_ticket' => 'New ticket: ${i.payload['subject']}',
    'send_message' => '${i.payload['is_internal'] == true ? 'Internal note' : 'Message'}: ${i.payload['body']}',
    'create_work_log' => 'Work log (${i.payload['type']}, ${i.payload['minutes']} min): ${i.payload['description']}',
    'upload_attachment' => 'File: ${i.payload['filename']}',
    _ => i.kind,
  };

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    return Scaffold(
      appBar: shellAppBar(
        context,
        'Sync queue',
        actions: [
          TextButton.icon(onPressed: sync.isSyncing ? null : () => sync.syncNow(force: true), icon: const Icon(Icons.sync), label: const Text('Sync now')),
        ],
      ),
      body: sync.items.isEmpty
          ? const EmptyView('Everything is synced. Items you create offline appear here until the server confirms them.', icon: Icons.cloud_done_outlined)
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final i in sync.items)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(describe(i), maxLines: 3, overflow: TextOverflow.ellipsis)),
                              OutboxBadge(i),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Created ${fmtRelative(i.createdAt)} · attempts: ${i.attempts}'
                            '${i.nextAttemptAt != null && i.status == OutboxStatus.pending ? ' · next try ${fmtRelative(i.nextAttemptAt)}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (i.error != null) Text(i.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          if (i.status == OutboxStatus.conflict)
                            const Text('The server state changed (for example the ticket was closed). Review the ticket, then retry or discard.'),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (i.status != OutboxStatus.syncing) TextButton(onPressed: () => sync.retry(i), child: const Text('Retry')),
                              TextButton(
                                onPressed: () async {
                                  if (await confirm(
                                    context,
                                    'Discard this item?',
                                    'It will not be sent. Anything that depends on it is discarded too.',
                                    action: 'Discard',
                                    destructive: true,
                                  )) {
                                    await sync.discard(i);
                                  }
                                },
                                child: const Text('Discard'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
