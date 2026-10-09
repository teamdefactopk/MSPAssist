import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../core/platform/platform.dart' as platform;
import '../data/local_store.dart';
import '../models/models.dart';

/// Emitted when a queued action reaches the server.
class SyncEvent {
  SyncEvent(this.item, this.result);
  final OutboxItem item;
  final Json result;
}

/// Replays queued (offline-capable) actions to the API in creation order.
///
/// * Every action carries a client-generated UUID, so retries after a lost
///   response are de-duplicated by the server.
/// * Transient failures (offline, 5xx, 429) stay `pending` and are retried
///   with exponential backoff.
/// * Permanent failures become `failed` (validation/permission) or
///   `conflict` (server state changed, e.g. ticket closed) and wait for the
///   user to retry, edit or discard — nothing is silently dropped.
/// * The server stays authoritative: queued actions never change local
///   ticket status or assignment.
class SyncService extends ChangeNotifier {
  SyncService(this.api, this.store, {this.interval = const Duration(seconds: 30), this.now = DateTime.now});

  final ApiClient api;
  final LocalStore store;
  final DateTime Function() now;
  final Duration interval;
  Timer? _timer;
  bool _running = false;
  bool _rerun = false;
  bool _rerunForce = false;
  Future<void>? _inflight;
  bool? online;
  List<OutboxItem> items = const [];
  final _events = StreamController<SyncEvent>.broadcast();

  Stream<SyncEvent> get events => _events.stream;
  bool get isSyncing => _running;
  int get pendingCount => items.where((i) => i.status == OutboxStatus.pending || i.status == OutboxStatus.syncing).length;
  int get problemCount => items.where((i) => i.status == OutboxStatus.failed || i.status == OutboxStatus.conflict).length;

  List<OutboxItem> forTicket(String ticketUuid) => items.where((i) => i.ticketUuid == ticketUuid).toList();

  Future<void> start() async {
    await reload();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => syncNow());
    unawaited(syncNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    items = const [];
    notifyListeners();
  }

  Future<void> reload() async {
    items = await store.outbox();
    notifyListeners();
  }

  Future<void> enqueue(OutboxItem item) async {
    await store.saveOutbox(item);
    await reload();
    unawaited(syncNow());
  }

  Future<void> retry(OutboxItem item) async {
    item
      ..status = OutboxStatus.pending
      ..nextAttemptAt = null
      ..error = null;
    await store.saveOutbox(item);
    await reload();
    await syncNow(force: true);
  }

  Future<void> updatePayload(OutboxItem item, Json payload) async {
    item
      ..payload = payload
      ..status = OutboxStatus.pending
      ..nextAttemptAt = null
      ..error = null;
    await store.saveOutbox(item);
    await reload();
    unawaited(syncNow(force: true));
  }

  /// Discards an item and anything that depends on it.
  Future<void> discard(OutboxItem item) async {
    final dependents = items.where((i) => i.id != item.id && dependenciesOf(i).contains(item.id));
    for (final d in [item, ...dependents]) {
      await _deleteFile(d);
      await store.deleteOutbox(d.id);
    }
    await reload();
  }

  /// Processes the queue. A call made while a run is in flight requests one
  /// more pass and completes together with that run.
  Future<void> syncNow({bool force = false}) {
    final inflight = _inflight;
    if (inflight != null) {
      _rerun = true;
      _rerunForce |= force;
      return inflight;
    }
    return _inflight = _run(force).whenComplete(() => _inflight = null);
  }

  Future<void> _run(bool force) async {
    _running = true;
    notifyListeners();
    try {
      var passes = 0;
      bool again;
      do {
        _rerun = false;
        // Another pass is needed when an item unblocked its dependents.
        again = await _pass(force) && passes++ < 10;
        force = _rerunForce;
        _rerunForce = false;
      } while (_rerun || again);
    } finally {
      _running = false;
      await reload();
    }
  }

  /// Returns true if an item succeeded while others were waiting on it.
  Future<bool> _pass(bool force) async {
    final queue = await store.outbox();
    final done = <String>{};
    var waitedOnDone = false;
    for (final item in queue) {
      final dependsOn = dependenciesOf(item);
      final waitingOn = dependsOn.where((id) => id != item.id && queue.any((q) => q.id == id));
      if (waitingOn.isNotEmpty) {
        if (waitingOn.every(done.contains)) waitedOnDone = true;
        continue;
      }
      if (item.status == OutboxStatus.failed || item.status == OutboxStatus.conflict) continue;
      if (!force && item.nextAttemptAt != null && item.nextAttemptAt!.isAfter(now())) continue;

      item.status = OutboxStatus.syncing;
      await store.saveOutbox(item);
      notifyListeners();
      try {
        final result = await _execute(item);
        online = true;
        await _deleteFile(item);
        await store.deleteOutbox(item.id);
        done.add(item.id);
        _events.add(SyncEvent(item, result));
      } on ApiException catch (e) {
        item.attempts++;
        item.error = e.firstError;
        if (e.isTransient) {
          online = !e.isNetwork;
          item.status = OutboxStatus.pending;
          item.nextAttemptAt = now().add(backoff(item.attempts));
          await store.saveOutbox(item);
          if (e.isNetwork) return false; // still offline: stop this pass
        } else {
          online = true;
          item.status = e.isConflict ? OutboxStatus.conflict : OutboxStatus.failed;
          await store.saveOutbox(item);
        }
      } catch (e) {
        item.attempts++;
        item.error = e.toString();
        item.status = OutboxStatus.failed;
        await store.saveOutbox(item);
      }
    }
    return waitedOnDone;
  }

  /// Items that must reach the server before [item] can be sent.
  static Iterable<String> dependenciesOf(OutboxItem item) =>
      [item.ticketUuid, item.payload['work_log_uuid'] as String?, ...((item.payload['depends_on'] as List?) ?? const []).cast<String>()].whereType<String>();

  static Duration backoff(int attempts) => Duration(seconds: min(600, 5 * pow(2, max(0, attempts - 1)).toInt()));

  Future<int> _ticketId(OutboxItem item) async {
    final direct = asInt(item.payload['ticket_id']);
    if (direct != null) return direct;
    final mapped = await store.getJson('ticketmap:${item.ticketUuid}');
    final id = asInt(mapped?['id']);
    if (id == null) throw StateError('The ticket for this item has not been created on the server.');
    return id;
  }

  Future<Json> _execute(OutboxItem item) async {
    switch (item.kind) {
      case 'create_ticket':
        final res = (await api.post('tickets', body: item.payload)) as Map;
        final ticket = (res['data'] as Map).cast<String, dynamic>();
        await store.putJson('ticketmap:${item.id}', {'id': ticket['id']});
        await store.putJson('ticket:${ticket['id']}', ticket);
        return ticket;
      case 'send_message':
        final id = await _ticketId(item);
        final body = Map<String, dynamic>.from(item.payload)
          ..remove('ticket_id')
          ..remove('depends_on');
        final res = (await api.post('tickets/$id/messages', body: body)) as Map;
        return (res['data'] as Map).cast<String, dynamic>();
      case 'create_work_log':
        final id = await _ticketId(item);
        final body = Map<String, dynamic>.from(item.payload)..remove('ticket_id');
        final res = (await api.post('tickets/$id/work-logs', body: body)) as Map;
        return (res['data'] as Map).cast<String, dynamic>();
      case 'upload_attachment':
        final id = await _ticketId(item);
        final bytes = await platform.readOutboxFile(item.payload['file_ref'] as String);
        final res = (await api.upload(
          'tickets/$id/attachments',
          bytes: bytes,
          filename: item.payload['filename'] as String,
          fields: {
            'uuid': item.id,
            if (item.payload['work_log_uuid'] != null) 'work_log_uuid': item.payload['work_log_uuid'] as String,
            if (item.payload['is_internal'] == true) 'is_internal': '1',
          },
        )) as Map;
        return (res['data'] as Map).cast<String, dynamic>();
      default:
        throw StateError('Unknown outbox action ${item.kind}');
    }
  }

  Future<void> _deleteFile(OutboxItem item) async {
    final ref = item.payload['file_ref'];
    if (ref is String) await platform.deleteOutboxFile(ref);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _events.close();
    super.dispose();
  }
}
