/// Error returned by the API (or a transport failure when [statusCode] is 0).
class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.code, this.errors = const {}, this.body});

  final int statusCode;
  final String message;
  final String? code;
  final Map<String, List<String>> errors;
  final Map<String, dynamic>? body;

  bool get isNetwork => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;
  bool get isConflict => statusCode == 409;
  bool get isValidation => statusCode == 422;
  bool get isServerError => statusCode >= 500;

  /// Errors worth retrying automatically (offline, timeouts, server hiccups, rate limits).
  bool get isTransient => isNetwork || isServerError || statusCode == 429 || statusCode == 408;

  String get firstError => errors.values.expand((e) => e).firstOrNull ?? message;

  @override
  String toString() => firstError;
}
