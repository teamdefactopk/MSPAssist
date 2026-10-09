import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'config.dart';
import 'platform/platform.dart' as platform;

class DownloadedFile {
  DownloadedFile(this.bytes, this.filename, this.contentType);
  final Uint8List bytes;
  final String filename;
  final String contentType;
}

/// Thin JSON client for the MSPAssist REST API.
class ApiClient {
  ApiClient(this.config, {http.Client? client}) : _http = client ?? platform.createHttpClient();

  final AppConfig config;
  final http.Client _http;
  String? token;

  /// Called when the server rejects our credentials (expired/revoked token).
  void Function()? onUnauthorized;

  static const _timeout = Duration(seconds: 30);
  static const _uploadTimeout = Duration(minutes: 3);

  Uri uri(String path, [Map<String, Object?>? query]) {
    final clean = path.startsWith('/') ? path.substring(1) : path;
    final u = config.apiBaseUrl.resolve(clean);
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v.toString().isNotEmpty) q[k] = v.toString();
    });
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  Map<String, String> _headers({bool json = true}) => {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
        if (platform.usesCookieAuth && platform.readXsrfToken() != null) 'X-XSRF-TOKEN': platform.readXsrfToken()!,
      };

  /// Web only: obtain the XSRF-TOKEN cookie before the first state-changing request.
  Future<void> ensureCsrfCookie({bool force = false}) async {
    if (!platform.usesCookieAuth) return;
    if (!force && platform.readXsrfToken() != null) return;
    await _send(() => _http.get(config.apiBaseUrl.resolve('../../sanctum/csrf-cookie'), headers: _headers()));
  }

  Future<dynamic> get(String path, {Map<String, Object?>? query}) =>
      _json(() => _http.get(uri(path, query), headers: _headers()));

  Future<dynamic> post(String path, {Object? body}) => _mutating(() => _http.post(uri(path), headers: _headers(), body: jsonEncode(body ?? {})));

  Future<dynamic> patch(String path, {Object? body}) => _mutating(() => _http.patch(uri(path), headers: _headers(), body: jsonEncode(body ?? {})));

  Future<dynamic> put(String path, {Object? body}) => _mutating(() => _http.put(uri(path), headers: _headers(), body: jsonEncode(body ?? {})));

  Future<dynamic> delete(String path) => _mutating(() => _http.delete(uri(path), headers: _headers()));

  Future<dynamic> upload(String path, {required Uint8List bytes, required String filename, Map<String, String> fields = const {}}) {
    return _mutating(() async {
      final req = http.MultipartRequest('POST', uri(path))
        ..headers.addAll(_headers(json: false))
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
      return http.Response.fromStream(await _http.send(req));
    }, timeout: _uploadTimeout);
  }

  Future<DownloadedFile> download(String path, {Map<String, Object?>? query}) async {
    final res = await _send(() => _http.get(uri(path, query), headers: _headers(json: false)));
    if (res.statusCode >= 400) throw _error(res);
    final disposition = res.headers['content-disposition'] ?? '';
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    return DownloadedFile(res.bodyBytes, match?.group(1) ?? 'download', res.headers['content-type'] ?? 'application/octet-stream');
  }

  Future<dynamic> _mutating(Future<http.Response> Function() call, {Duration timeout = _timeout}) async {
    await ensureCsrfCookie();
    try {
      return await _json(call, timeout: timeout);
    } on ApiException catch (e) {
      // 419 = CSRF token mismatch (expired cookie). Refresh once and retry.
      if (e.statusCode == 419 && platform.usesCookieAuth) {
        await ensureCsrfCookie(force: true);
        return _json(call, timeout: timeout);
      }
      rethrow;
    }
  }

  Future<dynamic> _json(Future<http.Response> Function() call, {Duration timeout = _timeout}) async {
    final res = await _send(call, timeout: timeout);
    if (res.statusCode >= 400) throw _error(res);
    if (res.statusCode == 204 || res.body.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<http.Response> _send(Future<http.Response> Function() call, {Duration timeout = _timeout}) async {
    try {
      return await call().timeout(timeout);
    } on TimeoutException {
      throw ApiException(0, 'The server did not respond in time.');
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Cannot reach the server. Check your connection. (${e.message})');
    } catch (e) {
      if (e is ApiException) rethrow;
      // SocketException/HandshakeException etc. (dart:io types are not importable on web).
      throw ApiException(0, 'Cannot reach the server. Check your connection.');
    }
  }

  ApiException _error(http.Response res) {
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}
    final errors = <String, List<String>>{};
    final raw = body?['errors'];
    if (raw is Map) {
      raw.forEach((k, v) => errors[k.toString()] = v is List ? v.map((e) => e.toString()).toList() : [v.toString()]);
    }
    if (res.statusCode == 401) onUnauthorized?.call();
    return ApiException(
      res.statusCode,
      body?['message']?.toString() ?? _defaultMessage(res.statusCode),
      code: body?['code']?.toString(),
      errors: errors,
      body: body,
    );
  }

  static String _defaultMessage(int status) => switch (status) {
        401 => 'Your session has expired. Please sign in again.',
        403 => 'You do not have permission to do that.',
        404 => 'Not found.',
        409 => 'This item was changed by someone else.',
        419 => 'Your session expired. Please try again.',
        429 => 'Too many requests. Please wait a moment.',
        _ => 'Unexpected server error ($status).',
      };
}
