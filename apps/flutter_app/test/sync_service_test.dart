import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mspassist/src/core/api_client.dart';
import 'package:mspassist/src/core/config.dart';
import 'package:mspassist/src/data/local_store.dart';
import 'package:mspassist/src/sync/sync_service.dart';

/// Fake server: records requests and replies via [handler].
class FakeServer {
  final requests = <http.Request>[];
  http.Response Function(http.Request req) handler = (_) => http.Response('{}', 200);
  bool offline = false;

  MockClient get client => MockClient((req) async {
        if (offline) throw http.ClientException('offline');
        requests.add(req);
        return handler(req);
      });
}

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  late FakeServer server;
  late MemoryLocalStore store;
  late SyncService sync;
  var clock = DateTime(2026, 10, 9, 12);

  setUp(() {
    server = FakeServer();
    store = MemoryLocalStore();
    clock = DateTime(2026, 10, 9, 12);
    final api = ApiClient(AppConfig.forBaseUrl('https://support.example.com/api/v1'), client: server.client);
    sync = SyncService(api, store, interval: const Duration(hours: 1), now: () => clock);
  });

  OutboxItem ticketDraft(String id) => OutboxItem(id: id, kind: 'create_ticket', ticketUuid: id, payload: {'uuid': id, 'subject': 'Printer', 'organization_id': 1, 'site_id': 1, 'description': 'x'});

  test('offline items stay pending with backoff and are never reported as delivered', () async {
    server.offline = true;
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    await sync.enqueue(ticketDraft('t-1'));
    await sync.syncNow();

    final item = (await store.outbox()).single;
    expect(item.status, OutboxStatus.pending);
    expect(item.attempts, 1);
    expect(item.nextAttemptAt, clock.add(const Duration(seconds: 5)));
    expect(sync.online, isFalse);
    expect(events, isEmpty);

    // Not retried before the backoff elapses.
    server.offline = false;
    await sync.syncNow();
    expect(server.requests, isEmpty);
  });

  test('replays in order, resolving the server id of an offline-created ticket', () async {
    server.handler = (req) {
      if (req.url.path.endsWith('/tickets')) return json({'data': {'id': 42, 'uuid': 't-1', 'number': 'CC-1'}}, 201);
      if (req.url.path.endsWith('/tickets/42/messages')) return json({'data': {'id': 7, 'uuid': 'm-1', 'body': 'hi'}}, 201);
      return json({}, 404);
    };
    final events = <SyncEvent>[];
    sync.events.listen(events.add);
    // Message queued before the ticket exists on the server.
    await store.saveOutbox(ticketDraft('t-1'));
    await store.saveOutbox(OutboxItem(id: 'm-1', kind: 'send_message', ticketUuid: 't-1', payload: {'uuid': 'm-1', 'body': 'hi'}, createdAt: DateTime(2027)));
    await sync.syncNow();

    expect(server.requests.map((r) => r.url.path), ['/api/v1/tickets', '/api/v1/tickets/42/messages']);
    expect(jsonDecode(server.requests[1].body)['uuid'], 'm-1');
    expect(await store.outbox(), isEmpty);
    expect(events.map((e) => e.item.id), ['t-1', 'm-1']);
  });

  test('retrying after a lost response reuses the same idempotency uuid', () async {
    var calls = 0;
    server.handler = (req) {
      calls++;
      return calls == 1 ? json({'message': 'Server error'}, 503) : json({'data': {'id': 1}}, 200);
    };
    await sync.enqueue(OutboxItem(id: 'm-9', kind: 'send_message', ticketUuid: 'x', payload: {'uuid': 'm-9', 'ticket_id': 5, 'body': 'hello'}));
    await sync.syncNow();
    expect((await store.outbox()).single.status, OutboxStatus.pending);
    clock = clock.add(const Duration(minutes: 1));
    await sync.syncNow();
    expect(await store.outbox(), isEmpty);
    expect(server.requests.map((r) => jsonDecode(r.body)['uuid']).toSet(), {'m-9'});
  });

  test('validation errors fail, conflicts are flagged, dependents stay blocked', () async {
    server.handler = (req) => req.url.path.endsWith('/tickets')
        ? json({'message': 'The given data was invalid.', 'errors': {'site_id': ['The selected site is not available to you.']}}, 422)
        : json({'message': 'This ticket is closed.', 'code': 'ticket_closed'}, 409);
    await store.saveOutbox(ticketDraft('t-1'));
    await store.saveOutbox(OutboxItem(id: 'm-1', kind: 'send_message', ticketUuid: 't-1', payload: {'uuid': 'm-1', 'body': 'hi'}, createdAt: DateTime(2027)));
    await store.saveOutbox(OutboxItem(id: 'm-2', kind: 'send_message', ticketUuid: 'other', payload: {'uuid': 'm-2', 'ticket_id': 9, 'body': 'late'}, createdAt: DateTime(2028)));
    await sync.syncNow();

    final items = {for (final i in await store.outbox()) i.id: i};
    expect(items['t-1']!.status, OutboxStatus.failed);
    expect(items['t-1']!.error, 'The selected site is not available to you.');
    expect(items['m-1']!.status, OutboxStatus.pending, reason: 'blocked behind the failed ticket');
    expect(items['m-2']!.status, OutboxStatus.conflict);
    expect(server.requests.length, 2);

    // Discarding the ticket discards its dependent message too.
    await sync.discard(items['t-1']!);
    expect((await store.outbox()).map((i) => i.id), ['m-2']);
  });

  test('backoff grows exponentially and is capped', () {
    expect(SyncService.backoff(1), const Duration(seconds: 5));
    expect(SyncService.backoff(3), const Duration(seconds: 20));
    expect(SyncService.backoff(20), const Duration(minutes: 10));
  });
}
