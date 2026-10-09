import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mspassist/src/core/api_client.dart';
import 'package:mspassist/src/core/api_exception.dart';
import 'package:mspassist/src/core/config.dart';
import 'package:mspassist/src/data/local_store.dart';
import 'package:mspassist/src/data/repository.dart';

Map<String, dynamic> ticket(int id, {String status = 'open', int org = 1, int? assignee, String updated = '2026-10-01T10:00:00Z'}) => {
  'id': id,
  'uuid': 'u$id',
  'number': 'CC-2026-00000$id',
  'subject': 'Ticket $id',
  'priority': 'high',
  'status': status,
  'organization': {'id': org, 'name': 'Org $org'},
  'site': {'id': 1, 'name': 'HQ'},
  'assignee': assignee == null ? null : {'id': assignee, 'name': 'Tech'},
  'updated_at': updated,
};

void main() {
  test('falls back to cached tickets offline and filters them locally', () async {
    var offline = false;
    final api = ApiClient(
      AppConfig.forBaseUrl('https://support.example.com/api/v1'),
      client: MockClient((req) async {
        if (offline) throw http.ClientException('offline');
        return http.Response(
          '{"data":[${[ticket(1), ticket(2, status: 'closed'), ticket(3, org: 2, assignee: 9)].map(jsonEncode).join(',')}],"meta":{"last_page":1}}',
          200,
        );
      }),
    );
    final repo = Repository(api, MemoryLocalStore());
    final online = await repo.tickets({});
    expect(online.fromCache, isFalse);
    expect(online.data, hasLength(3));

    offline = true;
    final active = await repo.tickets({'state': 'active'});
    expect(active.fromCache, isTrue);
    expect(active.data.map((t) => t.id), unorderedEquals([1, 3]));
    expect((await repo.tickets({'organization_id': '2'})).data.single.id, 3);
    expect((await repo.tickets({'assigned_to': 'none', 'state': 'active'})).data.single.id, 1);
    expect((await repo.tickets({'search': 'ticket 2'})).data.single.id, 2);

    // Later pages are never faked from the cache.
    await expectLater(repo.tickets({}, page: 2), throwsA(isA<ApiException>()));
  });
}
