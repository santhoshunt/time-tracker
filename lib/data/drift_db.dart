import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// File name of Drift's database inside the app's databases folder.
const driftDbFileName = 'drift.db';

/// Schema version. Every table ships in version 1, so nothing needs a
/// migration until a later release changes the shape; that release bumps
/// this and adds an `onUpgrade` step.
const driftDbVersion = 1;

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
    options: OpenDatabaseOptions(version: driftDbVersion, onCreate: _create),
  );
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
