import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mspassist/src/data/local_store.dart';
import 'package:mspassist/src/data/sqlite_local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late SqliteLocalStore store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('msp');
    store = SqliteLocalStore(factory: databaseFactoryFfi, directory: dir.path);
    await store.open('7_support.example.com');
  });

  tearDown(() => dir.delete(recursive: true));

  test('caches JSON and queries by prefix', () async {
    await store.putJson('ticket:1', {'id': 1, 'subject': 'A'});
    await store.putJson('ticket:2', {'id': 2, 'subject': 'B'});
    await store.putJson('ticketmap:x', {'id': 1});
    expect((await store.getJson('ticket:1'))!['subject'], 'A');
    expect((await store.getJsonByPrefix('ticket:')).length, 2);
  });

  test('persists the outbox across reopen and wipes everything on logout', () async {
    await store.saveOutbox(OutboxItem(id: 'a', kind: 'send_message', ticketUuid: 't', payload: {'body': 'hi'}, status: OutboxStatus.failed, error: 'boom'));
    final reopened = SqliteLocalStore(factory: databaseFactoryFfi, directory: dir.path);
    await reopened.open('7_support.example.com');
    final item = (await reopened.outbox()).single;
    expect(item.status, OutboxStatus.failed);
    expect(item.error, 'boom');
    expect(item.payload['body'], 'hi');

    await reopened.wipe();
    expect(dir.listSync().where((f) => f.path.endsWith('.db')), isEmpty);
  });

  test('accounts are isolated', () async {
    await store.putJson('me', {'id': 7});
    await store.open('8_support.example.com');
    expect(await store.getJson('me'), isNull);
  });
}
