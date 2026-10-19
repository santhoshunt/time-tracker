import 'package:sqflite/sqflite.dart';

import '../../domain/models.dart';

/// Raw usage events, kept for a few days so sessions can be rebuilt when
/// late events arrive.
///
/// Overridable so tests can make a commit fail.
class EventRepository {
  EventRepository(this.db);

  final Database db;

  /// Inserts [events] in one transaction and returns how many were new.
  /// Repeats of a stored (t, p, c, k) are skipped, which makes it safe to
  /// feed the same span from a buffer file and the direct query.
  Future<int> insertAll(List<RawEvent> events) async {
    if (events.isEmpty) return 0;
    return db.transaction((txn) async {
      final before = await _count(txn);
      final batch = txn.batch();
      for (final e in events) {
        batch.insert(
          'raw_events',
          {'t': e.t, 'p': e.p, 'c': e.c ?? '', 'k': e.kind.key},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
      return await _count(txn) - before;
    });
  }

  /// Events with [fromMs] <= t < [toMs], oldest first. Ties keep the
  /// order they were stored in, which is the order Android reported them.
  /// Rows with an unknown kind are skipped.
  Future<List<RawEvent>> between(int fromMs, int toMs) async {
    final rows = await db.query(
      'raw_events',
      where: 't >= ? AND t < ?',
      whereArgs: [fromMs, toMs],
      orderBy: 't, rowid',
    );
    return [
      for (final r in rows)
        if (EventKind.fromKey(r['k'] as String?) case final kind?)
          RawEvent(r['t'] as int, r['p'] as String, _classOrNull(r['c']), kind),
    ];
  }

  /// Undoes the '' stored for a missing class (see drift_db.dart).
  static String? _classOrNull(Object? c) => c is String && c.isNotEmpty ? c : null;

  /// Deletes events older than [ms] and returns how many went.
  Future<int> pruneBefore(int ms) =>
      db.delete('raw_events', where: 't < ?', whereArgs: [ms]);

  static Future<int> _count(DatabaseExecutor ex) async =>
      Sqflite.firstIntValue(await ex.rawQuery('SELECT COUNT(*) FROM raw_events')) ?? 0;
}
