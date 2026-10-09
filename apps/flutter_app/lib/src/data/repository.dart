import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/models.dart';
import 'local_store.dart';

/// Result of a read that may have been served from the offline cache.
class Loaded<T> {
  Loaded(this.data, {this.fromCache = false, this.meta = const {}});
  final T data;
  final bool fromCache;
  final Json meta;
}

/// Data access for screens. Reads go to the API and fall back to the
/// account-scoped cache when offline; writes are online-only unless they go
/// through the SyncService outbox.
class Repository {
  Repository(this.api, this.store);

  final ApiClient api;
  final LocalStore store;
  Lookups? _lookups;

  Lookups? get lookupsOrNull => _lookups;

  /// GET [path] and cache the decoded body under [cacheKey]; on a network
  /// error return the cached copy if there is one.
  Future<Loaded<Json>> getCached(String path, {Map<String, Object?>? query, String? cacheKey}) async {
    final key = cacheKey ?? 'get:$path?${query ?? ''}';
    try {
      final res = (await api.get(path, query: query) as Map).cast<String, dynamic>();
      await store.putJson(key, res);
      return Loaded(res);
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      final cached = await store.getJson(key);
      if (cached == null) rethrow;
      return Loaded(cached, fromCache: true);
    }
  }

  Future<Lookups> lookups({bool refresh = false}) async {
    if (_lookups != null && !refresh) return _lookups!;
    final res = await getCached('lookups', cacheKey: 'lookups');
    return _lookups = Lookups((res.data['data'] as Map).cast());
  }

  void clearMemory() => _lookups = null;

  // ---- Tickets ---------------------------------------------------------

  Future<Loaded<List<Ticket>>> tickets(Map<String, Object?> filters, {int page = 1}) async {
    try {
      final res = await api.get('tickets', query: {...filters, 'page': page, 'per_page': 25}) as Map;
      final list = ((res['data'] as List)).map((e) => Ticket((e as Map).cast())).toList();
      for (final t in list) {
        await store.putJson('ticket:${t.id}', t.json);
      }
      return Loaded(list, meta: (res['meta'] as Map).cast());
    } on ApiException catch (e) {
      if (!e.isNetwork || page > 1) rethrow;
      final cached = await store.getJsonByPrefix('ticket:');
      return Loaded(_filterLocally(cached.map(Ticket.new).toList(), filters), fromCache: true, meta: {'last_page': 1});
    }
  }

  /// Best-effort local filtering of cached tickets while offline.
  List<Ticket> _filterLocally(List<Ticket> all, Map<String, Object?> f) {
    final search = (f['search'] as String?)?.toLowerCase();
    final statuses = (f['status'] as String?)?.split(',');
    return all.where((t) {
      if (statuses != null && statuses.first.isNotEmpty && !statuses.contains(t.status)) return false;
      if (f['state'] == 'active' && !t.isActive) return false;
      if (f['state'] == 'inactive' && t.isActive) return false;
      if (f['priority'] != null && f['priority'] != t.priority) return false;
      final assigned = f['assigned_to']?.toString();
      if (assigned == 'none' && t.assignee != null) return false;
      if (assigned != null && int.tryParse(assigned) != null && t.assignee?.id != int.parse(assigned)) return false;
      if (f['organization_id'] != null && '${t.organization?.id}' != '${f['organization_id']}') return false;
      if (f['site_id'] != null && '${t.site?.id}' != '${f['site_id']}') return false;
      if ('${f['overdue']}' == '1' && !t.isOverdue) return false;
      if (search != null && search.isNotEmpty && !('${t.number} ${t.subject}'.toLowerCase().contains(search))) return false;
      return true;
    }).toList()..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
  }

  Future<Loaded<Ticket>> ticket(int id) async {
    try {
      final res = await api.get('tickets/$id') as Map;
      final t = Ticket((res['data'] as Map).cast());
      await store.putJson('ticket:$id', t.json);
      return Loaded(t);
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      final cached = await store.getJson('ticket:$id');
      if (cached == null) rethrow;
      return Loaded(Ticket(cached), fromCache: true);
    }
  }

  Future<Ticket> _ticketMutation(Future<dynamic> call) async {
    final res = await call as Map;
    final t = Ticket((res['data'] as Map).cast());
    await store.putJson('ticket:${t.id}', t.json);
    return t;
  }

  Future<Ticket> assign(Ticket t, int? userId) => _ticketMutation(api.post('tickets/${t.id}/assign', body: {'assigned_to': userId, 'version': t.version}));

  Future<Ticket> changeStatus(Ticket t, String status, {String? note, String? resolutionNotes, int? version}) => _ticketMutation(
    api.post('tickets/${t.id}/status', body: {'status': status, 'version': version ?? t.version, 'note': ?note, 'resolution_notes': ?resolutionNotes}),
  );

  Future<Ticket> reopen(Ticket t, String reason, {int? version}) =>
      _ticketMutation(api.post('tickets/${t.id}/reopen', body: {'reason': reason, 'version': version ?? t.version}));

  Future<Ticket> updateTicket(Ticket t, Json changes, {int? version}) =>
      _ticketMutation(api.patch('tickets/${t.id}', body: {...changes, 'version': version ?? t.version}));

  // ---- Conversation ----------------------------------------------------

  Future<Loaded<List<Message>>> messages(int ticketId, {int? afterId, int? beforeId, int limit = 30}) async {
    final query = {'after_id': afterId, 'before_id': beforeId, 'limit': limit};
    final isLatestPage = afterId == null && beforeId == null;
    try {
      final res = (await api.get('tickets/$ticketId/messages', query: query) as Map).cast<String, dynamic>();
      if (isLatestPage) await store.putJson('messages:$ticketId', res);
      return Loaded(_messages(res), meta: (res['meta'] as Map).cast());
    } on ApiException catch (e) {
      if (!e.isNetwork || !isLatestPage) rethrow;
      final cached = await store.getJson('messages:$ticketId');
      if (cached == null) rethrow;
      return Loaded(_messages(cached), fromCache: true, meta: (cached['meta'] as Map).cast());
    }
  }

  List<Message> _messages(Json res) => (res['data'] as List).map((e) => Message((e as Map).cast())).toList();

  /// Appends polled messages to the cached latest page so they survive offline.
  Future<void> cacheMessages(int ticketId, List<Message> all, Json meta) =>
      store.putJson('messages:$ticketId', {'data': all.map((m) => m.json).toList(), 'meta': meta});

  Future<void> markRead(int ticketId, int lastMessageId) async {
    try {
      await api.post('tickets/$ticketId/read', body: {'last_message_id': lastMessageId});
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
    }
  }

  Future<String?> messageDraft(int ticketId) async => (await store.getJson('draft:msg:$ticketId'))?['body'] as String?;

  Future<void> saveMessageDraft(int ticketId, String body) =>
      body.trim().isEmpty ? store.delete('draft:msg:$ticketId') : store.putJson('draft:msg:$ticketId', {'body': body});

  Future<Loaded<List<WorkLog>>> workLogs(int ticketId) async {
    final res = await getCached('tickets/$ticketId/work-logs', cacheKey: 'worklogs:$ticketId');
    return Loaded((res.data['data'] as List).map((e) => WorkLog((e as Map).cast())).toList(), fromCache: res.fromCache);
  }

  Future<Loaded<List<TicketEvent>>> history(int ticketId) async {
    final res = await getCached('tickets/$ticketId/history', cacheKey: 'history:$ticketId');
    return Loaded((res.data['data'] as List).map((e) => TicketEvent((e as Map).cast())).toList(), fromCache: res.fromCache);
  }

  Future<List<Attachment>> attachments(int ticketId) async {
    final res = await api.get('tickets/$ticketId/attachments') as Map;
    return (res['data'] as List).map((e) => Attachment((e as Map).cast())).toList();
  }
}
