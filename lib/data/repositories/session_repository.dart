import 'package:sqflite/sqflite.dart';

import '../../domain/models.dart';

/// Built sessions, idle spans and no-data gaps. All times are stored as
/// UTC milliseconds and come back as local DateTimes.
class SessionRepository {
  SessionRepository(this.db);

  final Database db;

  /// Replaces the sessions and idle spans that start in
  /// [dayStart, dayEnd) with [sessions] and [idleSpans], in one
  /// transaction. Items starting outside the day are ignored.
  ///
  /// A session that already exists with the same (package, start) keeps
  /// its row id and only has its end updated, because overrides are keyed
  /// by that id and the open session is rebuilt with a later end on every
  /// ingest. Sessions that no longer exist are deleted together with
  /// their overrides, so a reused id can never inherit a stale override.
  Future<void> replaceDay(
    DateTime dayStart,
    DateTime dayEnd,
    List<Session> sessions,
    List<IdleSpan> idleSpans,
  ) async {
    final fromMs = dayStart.millisecondsSinceEpoch;
    final toMs = dayEnd.millisecondsSinceEpoch;
    bool inDay(DateTime t) {
      final ms = t.millisecondsSinceEpoch;
      return ms >= fromMs && ms < toMs;
    }

    await db.transaction((txn) async {
      final existing = <(String, int), int>{};
      for (final r in await txn.query(
        'sessions',
        columns: ['id', 'p', 'start_ms'],
        where: 'start_ms >= ? AND start_ms < ?',
        whereArgs: [fromMs, toMs],
      )) {
        existing[(r['p'] as String, r['start_ms'] as int)] = r['id'] as int;
      }

      final batch = txn.batch();
      for (final s in sessions) {
        if (!inDay(s.start)) continue;
        final key = (s.p, s.start.millisecondsSinceEpoch);
        final id = existing.remove(key);
        if (id != null) {
          batch.update(
            'sessions',
            {'end_ms': s.end.millisecondsSinceEpoch},
            where: 'id = ?',
            whereArgs: [id],
          );
        } else {
          batch.insert(
            'sessions',
            {'p': s.p, 'start_ms': key.$2, 'end_ms': s.end.millisecondsSinceEpoch},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
      for (final id in existing.values) {
        batch.delete('sessions', where: 'id = ?', whereArgs: [id]);
        batch.delete('session_overrides', where: 'session_id = ?', whereArgs: [id]);
      }

      batch.delete('idle_spans', where: 'start_ms >= ? AND start_ms < ?', whereArgs: [fromMs, toMs]);
      for (final i in idleSpans) {
        if (!inDay(i.start)) continue;
        batch.insert(
          'idle_spans',
          {
            'start_ms': i.start.millisecondsSinceEpoch,
            'end_ms': i.end.millisecondsSinceEpoch,
            'kind': i.kind.key,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Sessions overlapping [from, to), oldest first. Overlap rather than
  /// "starts inside" so a session crossing midnight shows on both days.
  Future<List<Session>> sessionsBetween(DateTime from, DateTime to) async {
    final rows = await db.query(
      'sessions',
      where: 'start_ms < ? AND end_ms > ?',
      whereArgs: [to.millisecondsSinceEpoch, from.millisecondsSinceEpoch],
      orderBy: 'start_ms, id',
    );
    return [
      for (final r in rows)
        Session(
          id: r['id'] as int,
          p: r['p'] as String,
          start: _dt(r['start_ms']),
          end: _dt(r['end_ms']),
        ),
    ];
  }

  /// Idle spans overlapping [from, to), oldest first.
  Future<List<IdleSpan>> idleBetween(DateTime from, DateTime to) async {
    final rows = await db.query(
      'idle_spans',
      where: 'start_ms < ? AND end_ms > ?',
      whereArgs: [to.millisecondsSinceEpoch, from.millisecondsSinceEpoch],
      orderBy: 'start_ms, kind',
    );
    return [
      for (final r in rows)
        IdleSpan(_dt(r['start_ms']), _dt(r['end_ms']), IdleKind.fromKey(r['kind'] as String)),
    ];
  }

  /// Records a span with no data. Returns true when a new gap row was
  /// written. A gap with the same start keeps the later end, so rerunning
  /// an ingest that crashed before saving its cursor changes nothing.
  Future<bool> addGap(GapSpan gap) async {
    final startMs = gap.start.millisecondsSinceEpoch;
    final endMs = gap.end.millisecondsSinceEpoch;
    if (endMs <= startMs) return false;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'gaps',
        columns: ['end_ms'],
        where: 'start_ms = ?',
        whereArgs: [startMs],
      );
      if (rows.isEmpty) {
        await txn.insert('gaps', {'start_ms': startMs, 'end_ms': endMs});
        return true;
      }
      if ((rows.first['end_ms'] as int) < endMs) {
        await txn.update('gaps', {'end_ms': endMs}, where: 'start_ms = ?', whereArgs: [startMs]);
      }
      return false;
    });
  }

  /// Gaps overlapping [from, to), oldest first.
  Future<List<GapSpan>> gapsBetween(DateTime from, DateTime to) async {
    final rows = await db.query(
      'gaps',
      where: 'start_ms < ? AND end_ms > ?',
      whereArgs: [to.millisecondsSinceEpoch, from.millisecondsSinceEpoch],
      orderBy: 'start_ms',
    );
    return [for (final r in rows) GapSpan(_dt(r['start_ms']), _dt(r['end_ms']))];
  }

  static DateTime _dt(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms as int);
}
