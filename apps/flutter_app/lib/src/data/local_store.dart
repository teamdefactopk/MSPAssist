import 'dart:convert';

import '../models/models.dart';

/// Lifecycle of a locally queued action.
enum OutboxStatus { pending, syncing, failed, conflict }

/// A user action captured locally (possibly offline) and replayed to the API.
/// [id] is the client-generated UUID that the server uses for idempotency.
class OutboxItem {
  OutboxItem({
    required this.id,
    required this.kind,
    required this.payload,
    this.status = OutboxStatus.pending,
    this.attempts = 0,
    this.error,
    DateTime? createdAt,
    this.nextAttemptAt,
    this.ticketUuid,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;

  /// create_ticket | send_message | create_work_log | upload_attachment
  final String kind;
  Json payload;
  OutboxStatus status;
  int attempts;
  String? error;
  final DateTime createdAt;
  DateTime? nextAttemptAt;

  /// UUID of the ticket this action belongs to (may not be synced yet).
  final String? ticketUuid;

  Map<String, Object?> toRow() => {
        'id': id,
        'kind': kind,
        'payload': jsonEncode(payload),
        'status': status.name,
        'attempts': attempts,
        'error': error,
        'created_at': createdAt.toUtc().toIso8601String(),
        'next_attempt_at': nextAttemptAt?.toUtc().toIso8601String(),
        'ticket_uuid': ticketUuid,
      };

  static OutboxItem fromRow(Map<String, Object?> r) => OutboxItem(
        id: r['id'] as String,
        kind: r['kind'] as String,
        payload: (jsonDecode(r['payload'] as String) as Map).cast<String, dynamic>(),
        status: OutboxStatus.values.byName(r['status'] as String),
        attempts: (r['attempts'] as int?) ?? 0,
        error: r['error'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
        nextAttemptAt: r['next_attempt_at'] == null ? null : DateTime.parse(r['next_attempt_at'] as String).toLocal(),
        ticketUuid: r['ticket_uuid'] as String?,
      );
}

/// Account-scoped local storage: a JSON cache of server records plus the
/// outbox of queued actions. Native platforms use SQLite; the browser uses
/// an in-memory implementation (see local_store_factory.dart).
abstract class LocalStore {
  bool get isPersistent;

  /// Opens (creating if needed) the store for [account]. Must be called
  /// before any other method; switching accounts closes the previous one.
  Future<void> open(String account);

  Future<Json?> getJson(String key);
  Future<void> putJson(String key, Json value);
  Future<List<Json>> getJsonByPrefix(String prefix);
  Future<void> delete(String key);

  Future<List<OutboxItem>> outbox();
  Future<void> saveOutbox(OutboxItem item);
  Future<void> deleteOutbox(String id);

  /// Removes every record for the current account (used on logout).
  Future<void> wipe();
}

/// Non-persistent store used on the web and in tests.
class MemoryLocalStore implements LocalStore {
  final _cache = <String, String>{};
  final _outbox = <String, OutboxItem>{};

  @override
  bool get isPersistent => false;

  @override
  Future<void> open(String account) async {}

  @override
  Future<Json?> getJson(String key) async {
    final v = _cache[key];
    return v == null ? null : (jsonDecode(v) as Map).cast<String, dynamic>();
  }

  @override
  Future<void> putJson(String key, Json value) async => _cache[key] = jsonEncode(value);

  @override
  Future<List<Json>> getJsonByPrefix(String prefix) async => _cache.entries
      .where((e) => e.key.startsWith(prefix))
      .map((e) => (jsonDecode(e.value) as Map).cast<String, dynamic>())
      .toList();

  @override
  Future<void> delete(String key) async => _cache.remove(key);

  @override
  Future<List<OutboxItem>> outbox() async => _outbox.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> saveOutbox(OutboxItem item) async => _outbox[item.id] = OutboxItem.fromRow(item.toRow());

  @override
  Future<void> deleteOutbox(String id) async => _outbox.remove(id);

  @override
  Future<void> wipe() async {
    _cache.clear();
    _outbox.clear();
  }
}
