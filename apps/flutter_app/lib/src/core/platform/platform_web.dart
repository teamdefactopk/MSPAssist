import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Browser requests send the HttpOnly session cookie; no token is stored in JS.
http.Client createHttpClient() => BrowserClient()..withCredentials = true;

/// Laravel sets a readable XSRF-TOKEN cookie which must be echoed back
/// in the X-XSRF-TOKEN header on state-changing requests.
String? readXsrfToken() {
  for (final part in web.document.cookie.split(';')) {
    final kv = part.trim();
    if (kv.startsWith('XSRF-TOKEN=')) {
      return Uri.decodeComponent(kv.substring('XSRF-TOKEN='.length));
    }
  }
  return null;
}

Future<String> saveDownload(Uint8List bytes, String filename, String mimeType) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return filename;
}

bool get usesCookieAuth => true;

// The web cache is in-memory, so queued files are held in memory as well.
final _memoryFiles = <String, Uint8List>{};

Future<String> persistOutboxFile(Uint8List bytes, String id) async {
  _memoryFiles[id] = bytes;
  return 'mem:$id';
}

Future<Uint8List> readOutboxFile(String ref) async {
  final bytes = _memoryFiles[ref.substring(4)];
  if (bytes == null) throw StateError('Queued file is no longer available (page was reloaded).');
  return bytes;
}

Future<void> deleteOutboxFile(String ref) async => _memoryFiles.remove(ref.substring(4));

Future<void> clearOutboxFiles() async => _memoryFiles.clear();
