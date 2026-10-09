import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mspassist/src/core/api_client.dart';
import 'package:mspassist/src/core/api_exception.dart';
import 'package:mspassist/src/core/config.dart';

void main() {
  final config = AppConfig.forBaseUrl('https://support.example.com/api/v1');

  test('builds URLs, sends bearer token and JSON', () async {
    late http.Request seen;
    final api = ApiClient(
      config,
      client: MockClient((req) async {
        seen = req;
        return http.Response('{"data":[]}', 200);
      }),
    )..token = 'secret';
    await api.get('tickets', query: {'status': 'open', 'empty': null, 'page': 2});
    expect(seen.url.toString(), 'https://support.example.com/api/v1/tickets?status=open&page=2');
    expect(seen.headers['Authorization'], 'Bearer secret');
    expect(seen.headers['Accept'], 'application/json');
  });

  test('maps validation and conflict responses', () async {
    final api = ApiClient(
      config,
      client: MockClient((req) async {
        if (req.url.path.endsWith('status')) {
          return http.Response(
            jsonEncode({
              'message': 'changed',
              'code': 'version_conflict',
              'current': {'id': 1},
            }),
            409,
          );
        }
        return http.Response(
          jsonEncode({
            'message': 'invalid',
            'errors': {
              'subject': ['Subject is required.'],
            },
          }),
          422,
        );
      }),
    );
    await expectLater(api.post('tickets'), throwsA(isA<ApiException>().having((e) => e.firstError, 'firstError', 'Subject is required.')));
    await expectLater(
      api.post('tickets/1/status'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'version_conflict').having((e) => e.isConflict, 'isConflict', true)),
    );
  });

  test('transport failures become transient network errors', () async {
    final api = ApiClient(config, client: MockClient((_) async => throw http.ClientException('no route')));
    await expectLater(api.get('me'), throwsA(isA<ApiException>().having((e) => e.isNetwork && e.isTransient, 'network', true)));
  });

  test('401 triggers the unauthorized callback', () async {
    var called = false;
    final api = ApiClient(config, client: MockClient((_) async => http.Response('{"message":"Unauthenticated."}', 401)))..onUnauthorized = () => called = true;
    await expectLater(api.get('me'), throwsA(isA<ApiException>()));
    expect(called, isTrue);
  });
}
