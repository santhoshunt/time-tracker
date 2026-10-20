import 'dart:io';

import 'package:drift_time/data/drift_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A phone on v0.6.0 has a version 1 database. v0.7.0 must open it, keep
/// every row and add the group tables, or the app would not start.
void main() {
  late Directory dir;

  setUpAll(sqfliteFfiInit);
  setUp(() async => dir = await Directory.systemTemp.createTemp('drift_migration'));
  tearDown(() async => dir.delete(recursive: true));

  Future<List<String>> tables(Database db) async => [
    for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'"))
      r['name'] as String,
  ];

  test('a version 1 database opens as version 2 with its rows intact', () async {
    final path = '${dir.path}/drift.db';
    // A version 1 file with three of its tables, built with the v0.6.0
    // statements; the upgrade only adds tables, so these are what it could
    // disturb.
    final v1 = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE blocks(id INTEGER PRIMARY KEY, name TEXT, '
              'start_min INTEGER, end_min INTEGER, color_idx INTEGER, '
              'repeat_mask INTEGER, date TEXT, skip_dates TEXT, any_app INTEGER)');
          await db.execute('CREATE TABLE app_rules(block_key TEXT, p TEXT, verdict TEXT, '
              'updated_ms INTEGER, PRIMARY KEY(block_key, p))');
          await db.execute('CREATE TABLE sessions(id INTEGER PRIMARY KEY, p TEXT, '
              'start_ms INTEGER, end_ms INTEGER, UNIQUE(p, start_ms))');
        },
      ),
    );
    await v1.insert('blocks', {'name': 'Work', 'start_min': 690, 'end_min': 780, 'color_idx': 1, 'repeat_mask': 31, 'skip_dates': '[]', 'any_app': 0});
    await v1.insert('app_rules', {'block_key': 'work', 'p': 'com.example.notes', 'verdict': 'on', 'updated_ms': 1});
    await v1.insert('sessions', {'p': 'com.example.notes', 'start_ms': 1000, 'end_ms': 2000});
    expect(await v1.getVersion(), 1);
    await v1.close();

    final v2 = await openDriftDb(path: path, factory: databaseFactoryFfiNoIsolate);
    expect(await v2.getVersion(), driftDbVersion);
    expect(driftDbVersion, 2);
    expect(await tables(v2), containsAll(['app_groups', 'app_group_members', 'block_groups']));
    expect((await v2.query('blocks')).single['name'], 'Work');
    expect((await v2.query('app_rules')).single['p'], 'com.example.notes');
    expect(await v2.query('sessions'), hasLength(1));
    // The new tables take rows.
    final id = await v2.insert('app_groups', {'name': 'Work apps', 'emoji': 'x', 'color_idx': 2, 'kind': 'productive', 'sort': 0});
    await v2.insert('app_group_members', {'group_id': id, 'p': 'com.example.notes'});
    await v2.insert('block_groups', {'block_key': 'work', 'group_id': id, 'verdict': 'on'});
    await v2.close();

    // And a second open changes nothing.
    final again = await openDriftDb(path: path, factory: databaseFactoryFfiNoIsolate);
    expect(await again.query('block_groups'), hasLength(1));
    await again.close();
  });

  test('a new install gets every table at version 2', () async {
    final db = await openDriftDb(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    expect(await db.getVersion(), 2);
    expect(
      await tables(db),
      containsAll(['raw_events', 'sessions', 'blocks', 'app_rules', 'meta', 'app_groups', 'app_group_members', 'block_groups']),
    );
    await db.close();
  });
}
