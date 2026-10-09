import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the API bearer token in the platform keystore (Keychain,
/// Android Keystore-backed storage, Windows Credential Manager).
/// The web app uses an HttpOnly session cookie instead and stores nothing.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'mspassist.api_token';
  static const _accountKey = 'mspassist.account';

  Future<String?> read() async => kIsWeb ? null : _storage.read(key: _key);

  Future<void> write(String token) async {
    if (!kIsWeb) await _storage.write(key: _key, value: token);
  }

  /// Non-secret identifier of the signed-in account, used to name its cache.
  Future<String?> readAccount() async => kIsWeb ? null : _storage.read(key: _accountKey);

  Future<void> writeAccount(String account) async {
    if (!kIsWeb) await _storage.write(key: _accountKey, value: account);
  }

  Future<void> clear() async {
    if (kIsWeb) return;
    await _storage.delete(key: _key);
    await _storage.delete(key: _accountKey);
  }
}
