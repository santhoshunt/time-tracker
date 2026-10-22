import 'package:sqflite/sqflite.dart';

import '../../domain/models.dart';

/// Learned (block, app) rules and one-off session overrides: the user's
/// answers to "was this on track?".
///
/// Only the answers are stored: [Verdict.onTrack], [Verdict.offTrack] and
/// [Verdict.neutral], as 'on', 'off' and 'neutral'. The other verdicts are
/// computed, never answered. An older Drift reads 'neutral' as no answer.
class RuleRepository {
  RuleRepository(this.db);

  final Database db;

  /// Remembers [verdict] for [p] inside every block named [blockName]
  /// (matched by [blockKey]), replacing an earlier answer.
  Future<void> upsertRule(String blockName, String p, Verdict verdict, DateTime when) async {
    await db.insert(
      'app_rules',
      {
        'block_key': blockKey(blockName),
        'p': p,
        'verdict': _toDb(verdict),
        'updated_ms': when.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Forgets a learned rule, so the app falls back to anyApp or its
  /// category guess in that block again.
  Future<void> deleteRule(String blockName, String p) => db.delete(
        'app_rules',
        where: 'block_key = ? AND p = ?',
        whereArgs: [blockKey(blockName), p],
      );

  /// Every rule as (block key, package) to verdict, the shape the
  /// classifier takes.
  Future<Map<(String, String), Verdict>> allRules() async {
    final rows = await db.query('app_rules');
    return {
      for (final r in rows)
        (r['block_key'] as String, r['p'] as String): ?_fromDb(r['verdict'] as String?),
    };
  }

  /// Sets the verdict for one session only, without teaching a rule.
  Future<void> setOverride(int sessionId, Verdict verdict) async {
    await db.insert(
      'session_overrides',
      {'session_id': sessionId, 'verdict': _toDb(verdict)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Clears a session's own verdict so rules and guesses apply again.
  Future<void> deleteOverride(int sessionId) =>
      db.delete('session_overrides', where: 'session_id = ?', whereArgs: [sessionId]);

  /// Every override, keyed by session id.
  Future<Map<int, Verdict>> allOverrides() async =>
      _overrideMap(await db.query('session_overrides'));

  /// Overrides for sessions overlapping [from, to), for one day's view.
  Future<Map<int, Verdict>> overridesBetween(DateTime from, DateTime to) async {
    final rows = await db.rawQuery(
      'SELECT o.session_id, o.verdict FROM session_overrides o '
      'JOIN sessions s ON s.id = o.session_id '
      'WHERE s.start_ms < ? AND s.end_ms > ?',
      [to.millisecondsSinceEpoch, from.millisecondsSinceEpoch],
    );
    return _overrideMap(rows);
  }

  static Map<int, Verdict> _overrideMap(List<Map<String, Object?>> rows) => {
        for (final r in rows) r['session_id'] as int: ?_fromDb(r['verdict'] as String?),
      };

  static String _toDb(Verdict v) => switch (v) {
        Verdict.onTrack => 'on',
        Verdict.offTrack => 'off',
        Verdict.neutral => 'neutral',
        _ => throw ArgumentError.value(v, 'verdict', 'only onTrack, offTrack or neutral can be stored'),
      };

  static Verdict? _fromDb(String? s) => switch (s) {
        'on' => Verdict.onTrack,
        'off' => Verdict.offTrack,
        'neutral' => Verdict.neutral,
        _ => null,
      };
}
