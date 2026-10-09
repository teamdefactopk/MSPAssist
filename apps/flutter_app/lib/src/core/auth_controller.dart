import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import '../models/models.dart';
import '../sync/sync_service.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'platform/platform.dart' as platform;
import 'token_store.dart';

enum AuthStatus { unknown, signedOut, signedIn }

class AuthController extends ChangeNotifier {
  AuthController({required this.api, required this.tokens, required this.store, required this.sync}) {
    api.onUnauthorized = _handleUnauthorized;
  }

  final ApiClient api;
  final TokenStore tokens;
  final LocalStore store;
  final SyncService sync;

  AuthStatus status = AuthStatus.unknown;
  Me? me;

  /// True when signed in from cached credentials without reaching the server.
  bool offline = false;

  String get _host => api.config.apiBaseUrl.host;

  Future<void> restore() async {
    try {
      if (platform.usesCookieAuth) {
        await _loadMe();
      } else {
        final token = await tokens.read();
        final account = await tokens.readAccount();
        if (token == null || account == null) {
          _setSignedOut();
          return;
        }
        api.token = token;
        await store.open(account);
        try {
          await _loadMe();
        } on ApiException catch (e) {
          if (!e.isNetwork) rethrow;
          final cached = await store.getJson('me');
          if (cached == null) rethrow;
          me = Me(cached);
          offline = true;
        }
      }
      await _signedIn();
    } on ApiException {
      api.token = null;
      _setSignedOut();
    }
  }

  Future<void> login(String email, String password, {String deviceName = 'MSPAssist app'}) async {
    if (platform.usesCookieAuth) {
      await api.ensureCsrfCookie(force: true);
      final res = await api.post('auth/login', body: {'email': email, 'password': password}) as Map;
      // Session ID is rotated on login; refresh the CSRF cookie for later requests.
      await api.ensureCsrfCookie(force: true);
      me = Me((res['user'] as Map).cast());
      await store.open('web');
    } else {
      final res = await api.post('auth/token', body: {'email': email, 'password': password, 'device_name': deviceName}) as Map;
      final token = res['token'] as String;
      me = Me((res['user'] as Map).cast());
      final account = '${me!.id}_$_host';
      api.token = token;
      await tokens.write(token);
      await tokens.writeAccount(account);
      await store.open(account);
    }
    await store.putJson('me', me!.json);
    offline = false;
    await _signedIn();
  }

  Future<void> refreshProfile() async {
    await _loadMe();
    notifyListeners();
  }

  Future<void> _loadMe() async {
    final res = await api.get('me') as Map;
    me = Me((res['user'] as Map).cast());
    if (!platform.usesCookieAuth) await store.putJson('me', me!.json);
    if (platform.usesCookieAuth) await store.open('web');
    offline = false;
  }

  Future<void> _signedIn() async {
    status = AuthStatus.signedIn;
    notifyListeners();
    await sync.start();
  }

  /// Explicit logout: revoke server credentials and delete all local data
  /// (cache, queued actions, queued files) for this account.
  Future<void> logout() async {
    try {
      await api.post('auth/logout');
    } catch (_) {
      // Still clear local state when offline; the token expires server-side.
    }
    sync.stop();
    await store.wipe();
    await platform.clearOutboxFiles();
    await tokens.clear();
    api.token = null;
    _setSignedOut();
  }

  /// Token expired or revoked: sign out but keep the local outbox so the
  /// same user can sign back in and sync their drafts.
  void _handleUnauthorized() {
    if (status != AuthStatus.signedIn) return;
    sync.stop();
    api.token = null;
    tokens.clear();
    _setSignedOut();
  }

  void _setSignedOut() {
    me = null;
    offline = false;
    status = AuthStatus.signedOut;
    notifyListeners();
  }
}
