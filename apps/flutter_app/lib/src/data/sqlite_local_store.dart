import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';
import 'local_store.dart';

/// SQLite-backed store for Android, iOS, macOS and Windows.
/// One database file per signed-in account; deleted on logout.
class SqliteLocalStore implements LocalStore {
  SqliteLocalStore({DatabaseFactory? factory, this.directory}) : _factory = factory ?? _defaultFactory();

  final DatabaseFactory _factory;
  final String? directory;
  Database? _db;
  String? _path;

  static DatabaseFactory _defaultFactory() {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return mobile.databaseFactory;
  }

  @override
  bool get isPersistent => true;

  Database get _d {
    final db = _db;
    if (db == null) throw StateError('LocalStore used before open()');
    return db;
  }

  @override
  Future<void> open(String account) async {
    final dir = directory ?? (await getApplicationSupportDirectory()).path;
    final safe = account.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final path = p.join(dir, 'mspassist_$safe.db');
    if (_path == path && _db != null) return;
    await _db?.close();
    _path = path;
    _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE cache (key TEXT PRIMARY KEY, json TEXT NOT NULL, updated_at TEXT NOT NULL)');
          await db.execute(
            'CREATE TABLE outbox (id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, '
            'status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, error TEXT, created_at TEXT NOT NULL, '
            'next_attempt_at TEXT, ticket_uuid TEXT)',
          );
        },
      ),
    );
  }

  @override
  Future<Json?> getJson(String key) async {
    final rows = await _d.query('cache', columns: ['json'], where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : (jsonDecode(rows.first['json'] as String) as Map).cast<String, dynamic>();
  }

  @override
  Future<void> putJson(String key, Json value) => _d.insert('cache', {
    'key': key,
    'json': jsonEncode(value),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<List<Json>> getJsonByPrefix(String prefix) async {
    final rows = await _d.query('cache', columns: ['json'], where: 'key LIKE ?', whereArgs: ['${prefix.replaceAll('%', '')}%']);
    return rows.map((r) => (jsonDecode(r['json'] as String) as Map).cast<String, dynamic>()).toList();
  }

  @override
  Future<void> delete(String key) => _d.delete('cache', where: 'key = ?', whereArgs: [key]);

  @override
  Future<List<OutboxItem>> outbox() async => (await _d.query('outbox', orderBy: 'created_at ASC')).map(OutboxItem.fromRow).toList();

  @override
  Future<void> saveOutbox(OutboxItem item) => _d.insert('outbox', item.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> deleteOutbox(String id) => _d.delete('outbox', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> wipe() async {
    final path = _path;
    await _db?.close();
    _db = null;
    _path = null;
    if (path != null) await _factory.deleteDatabase(path);
  }
}
