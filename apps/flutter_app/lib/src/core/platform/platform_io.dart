import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

http.Client createHttpClient() => http.Client();

String? readXsrfToken() => null;

/// Saves to the Downloads folder where available, otherwise app documents.
Future<String> saveDownload(Uint8List bytes, String filename, String mimeType) async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } catch (_) {
    dir = null;
  }
  dir ??= await getApplicationDocumentsDirectory();
  final safe = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  var path = p.join(dir.path, safe);
  var i = 1;
  while (await File(path).exists()) {
    path = p.join(dir.path, '${p.basenameWithoutExtension(safe)} ($i)${p.extension(safe)}');
    i++;
  }
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

bool get usesCookieAuth => false;

Future<Directory> _outboxDir() async {
  final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'outbox_files'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Copies a picked file into app-private storage so it survives until upload.
Future<String> persistOutboxFile(Uint8List bytes, String id) async {
  final file = File(p.join((await _outboxDir()).path, id));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<Uint8List> readOutboxFile(String ref) => File(ref).readAsBytes();

Future<void> deleteOutboxFile(String ref) async {
  final f = File(ref);
  if (await f.exists()) await f.delete();
}

/// Removes all queued files (logout).
Future<void> clearOutboxFiles() async {
  final dir = await _outboxDir();
  if (await dir.exists()) await dir.delete(recursive: true);
}
