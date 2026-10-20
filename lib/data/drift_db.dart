import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// File name of Drift's database inside the app's databases folder.
const driftDbFileName = 'drift.db';

/// Schema version. Version 1 is the first release's tables; version 2
/// (v0.7.0) adds the app group tables. Upgrades only ever create tables,
/// so an old phone's rows are never rewritten.
const driftDbVersion = 2;

/// Opens (and on first run creates) Drift's database.
///
/// [factory] defaults to the sqflite plugin; tests pass
/// `databaseFactoryFfi` and `inMemoryDatabasePath` as [path], so this
/// file never imports the ffi package, which is a dev dependency only.
Future<Database> openDriftDb({String? path, DatabaseFactory? factory}) async {
  final dbFactory = factory ?? databaseFactory;
  final dbPath = path ?? p.join(await dbFactory.getDatabasesPath(), driftDbFileName);
  return dbFactory.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      version: driftDbVersion,
      onCreate: (db, version) async {
        await _create(db, version);
        await _addGroups(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await _addGroups(db);
      },
    ),
  );
}

/// Version 2: app groups. A group has a name, an emoji, a colour index and
/// a kind ('productive' or 'distracting'); its apps are rows of
/// `app_group_members`; `block_groups` links a block name key (as
/// `app_rules` uses it) to a group with a verdict ('on' or 'off').
Future<void> _addGroups(Database db) async {
  final batch = db.batch()
    ..execute('CREATE TABLE IF NOT EXISTS app_groups(id INTEGER PRIMARY KEY, '
        'name TEXT, emoji TEXT, color_idx INTEGER, kind TEXT, sort INTEGER)')
    ..execute('CREATE TABLE IF NOT EXISTS app_group_members(group_id INTEGER, '
        'p TEXT, PRIMARY KEY(group_id, p))')
    ..execute('CREATE TABLE IF NOT EXISTS block_groups(block_key TEXT, '
        'group_id INTEGER, verdict TEXT, PRIMARY KEY(block_key, group_id))');
  await batch.commit(noResult: true);
}

/// The schema from the plan, plus `meta` for the ingest cursor and the
/// last app-list refresh. They live here rather than in
/// SharedPreferences so they are cleared, backed up and restored together
/// with the rows they describe.
///
/// `raw_events.c` holds '' rather than NULL for events with no activity
/// class: SQLite treats NULLs as distinct in a UNIQUE constraint, so
/// NULL would let duplicate screen and keyguard events through.
///
/// Only syntax that SQLite 3.22 (Android 9, minSdk 28) understands is
/// used here and in the repositories; there is no UPSERT.
Future<void> _create(Database db, int version) async {
  final batch = db.batch()
    ..execute('CREATE TABLE raw_events(t INTEGER, p TEXT, c TEXT, k TEXT, '
        'UNIQUE(t, p, c, k))')
    ..execute('CREATE TABLE sessions(id INTEGER PRIMARY KEY, p TEXT, '
        'start_ms INTEGER, end_ms INTEGER, UNIQUE(p, start_ms))')
    ..execute('CREATE TABLE idle_spans(start_ms INTEGER, end_ms INTEGER, '
        'kind TEXT, UNIQUE(start_ms, kind))')
    ..execute('CREATE TABLE gaps(start_ms INTEGER PRIMARY KEY, end_ms INTEGER)')
    ..execute('CREATE TABLE blocks(id INTEGER PRIMARY KEY, name TEXT, '
        'start_min INTEGER, end_min INTEGER, color_idx INTEGER, '
        'repeat_mask INTEGER, date TEXT, skip_dates TEXT, any_app INTEGER)')
    ..execute('CREATE TABLE templates(id INTEGER PRIMARY KEY, name TEXT UNIQUE, '
        'blocks_json TEXT)')
    ..execute('CREATE TABLE day_plans(date TEXT PRIMARY KEY, blocks_json TEXT)')
    ..execute('CREATE TABLE app_rules(block_key TEXT, p TEXT, verdict TEXT, '
        'updated_ms INTEGER, PRIMARY KEY(block_key, p))')
    ..execute('CREATE TABLE session_overrides(session_id INTEGER PRIMARY KEY, '
        'verdict TEXT)')
    ..execute('CREATE TABLE apps(p TEXT PRIMARY KEY, label TEXT, category TEXT, '
        'last_seen_ms INTEGER)')
    ..execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
  await batch.commit(noResult: true);
}
