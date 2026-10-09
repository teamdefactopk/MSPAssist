import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mspassist/src/app.dart';
import 'package:mspassist/src/core/api_client.dart';
import 'package:mspassist/src/core/config.dart';
import 'package:mspassist/src/core/services.dart';
import 'package:mspassist/src/core/token_store.dart';
import 'package:mspassist/src/data/local_store.dart';

class MemoryTokenStore extends TokenStore {
  String? token;
  String? account;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String t) async => token = t;
  @override
  Future<String?> readAccount() async => account;
  @override
  Future<void> writeAccount(String a) async => account = a;
  @override
  Future<void> clear() async => token = account = null;
}

void main() {
  testWidgets('signed-out users see the login form and validation', (tester) async {
    final api = ApiClient(AppConfig.forBaseUrl('https://support.example.com/api/v1'), client: MockClient((_) async => http.Response('{}', 401)));
    final services = AppServices.create(api: api, store: MemoryLocalStore(), tokens: MemoryTokenStore());
    await tester.pumpWidget(MspAssistApp(services: services));
    await services.auth.restore();
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsWidgets);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
  });

  testWidgets('wrong credentials show the server message', (tester) async {
    final api = ApiClient(AppConfig.forBaseUrl('https://support.example.com/api/v1'), client: MockClient((req) async {
      if (req.url.path.endsWith('auth/token')) {
        return http.Response('{"message":"invalid","errors":{"email":["These credentials do not match an active account."]}}', 422);
      }
      return http.Response('{}', 401);
    }));
    final services = AppServices.create(api: api, store: MemoryLocalStore(), tokens: MemoryTokenStore());
    await tester.pumpWidget(MspAssistApp(services: services));
    await services.auth.restore();
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('login-email')), 'tech@example.com');
    await tester.enterText(find.byKey(const Key('login-password')), 'wrong-password');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('These credentials do not match an active account.'), findsOneWidget);
  });
}
