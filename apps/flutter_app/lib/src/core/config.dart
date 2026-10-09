import 'package:flutter/foundation.dart';

/// Build-time configuration. Override with
/// `--dart-define=API_BASE_URL=https://support.example.com/api/v1`.
class AppConfig {
  AppConfig._(this.apiBaseUrl);

  final Uri apiBaseUrl;

  static const _defined = String.fromEnvironment('API_BASE_URL');

  /// Chat polling interval while a conversation is open.
  static const pollInterval = Duration(seconds: 5);

  /// Maximum polling backoff after repeated errors.
  static const maxPollBackoff = Duration(seconds: 60);

  /// Explicit base URL (tests, custom builds).
  factory AppConfig.forBaseUrl(String url) => AppConfig._(Uri.parse(url.endsWith('/') ? url : '$url/'));

  static AppConfig resolve() {
    if (_defined.isNotEmpty) {
      return AppConfig._(Uri.parse(_defined.endsWith('/') ? _defined : '$_defined/'));
    }
    if (kIsWeb) {
      // Web dashboard is deployed on the same origin as the API.
      return AppConfig._(Uri.base.resolve('/api/v1/'));
    }
    // Android emulator reaches the host machine via 10.0.2.2.
    final host = defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : '127.0.0.1';
    return AppConfig._(Uri.parse('http://$host:8000/api/v1/'));
  }
}
