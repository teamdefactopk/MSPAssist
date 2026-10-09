import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/models.dart';
import '../../ui/app_shell.dart';
import '../../ui/common.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Json>? _items;
  int _unread = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await context.services.api.get('notifications', query: {'per_page': 100}) as Map;
      if (!mounted) return;
      setState(() {
        _items = (res['data'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _unread = (res['meta'] as Map)['unread_count'] as int;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Json n) async {
    if (n['read_at'] == null) {
      try {
        await context.services.api.post('notifications/${n['id']}/read');
      } catch (_) {}
    }
    final ticketId = (n['data'] as Map)['ticket_id'];
    if (!mounted) return;
    if (ticketId != null) {
      await context.push('/tickets/$ticketId');
    }
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: shellAppBar(context, 'Notifications', actions: [
          if (_unread > 0)
            TextButton(
              onPressed: () async {
                await context.services.api.post('notifications/read-all');
                _load();
              },
              child: const Text('Mark all read'),
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
        body: _error != null
            ? ErrorView(_error!, onRetry: _load)
            : _items == null
                ? const Center(child: CircularProgressIndicator())
                : _items!.isEmpty
                    ? const EmptyView('No notifications.', icon: Icons.notifications_none)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: _items!.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final n = _items![i];
                            final data = (n['data'] as Map).cast<String, dynamic>();
                            final unread = n['read_at'] == null;
                            return ListTile(
                              leading: Icon(n['type'] == 'SlaAlert' ? Icons.alarm : Icons.notifications, color: unread ? Theme.of(context).colorScheme.primary : null),
                              title: Text(data['title']?.toString() ?? '', style: TextStyle(fontWeight: unread ? FontWeight.bold : null)),
                              subtitle: Text('${data['body'] ?? ''}\n${fmtRelative(parseDate(n['created_at']))}'),
                              isThreeLine: true,
                              onTap: () => _open(n),
                            );
                          },
                        ),
                      ),
      );
}
