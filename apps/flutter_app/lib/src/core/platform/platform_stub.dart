import 'dart:typed_data';

import 'package:http/http.dart' as http;

http.Client createHttpClient() => http.Client();

String? readXsrfToken() => null;

Future<String> saveDownload(Uint8List bytes, String filename, String mimeType) async =>
    throw UnsupportedError('Downloads are not supported on this platform');

bool get usesCookieAuth => false;

/// Keeps queued file bytes until they are uploaded.
Future<String> persistOutboxFile(Uint8List bytes, String id) async => throw UnsupportedError('no file storage');

Future<Uint8List> readOutboxFile(String ref) async => throw UnsupportedError('no file storage');

Future<void> deleteOutboxFile(String ref) async {}

Future<void> clearOutboxFiles() async {}
