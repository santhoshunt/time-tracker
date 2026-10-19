import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../domain/models.dart';

/// Plan blocks, saved templates and the frozen per-date plans.
class PlanRepository {
  PlanRepository(this.db);

  final Database db;

  /// Every live block, in start order.
  Future<List<PlanBlock>> allBlocks() async {
    final rows = await db.query('blocks', orderBy: 'start_min, end_min, id');
    return [for (final r in rows) _blockFromRow(r)];
  }

  /// Stores a new block and returns its id. Any id on [block] is ignored.
  Future<int> insertBlock(PlanBlock block) {
    final row = _blockToRow(block)..remove('id');
    return db.insert('blocks', row);
  }

  /// Saves changes to an existing block, matched by its id.
  Future<void> updateBlock(PlanBlock block) async {
    final id = block.id;
    if (id == null) throw ArgumentError('updateBlock needs a block with an id');
    await db.update('blocks', _blockToRow(block)..remove('id'), where: 'id = ?', whereArgs: [id]);
  }

  /// Removes a block from the live plan. Frozen past days keep it.
  Future<void> deleteBlock(int id) => db.delete('blocks', where: 'id = ?', whereArgs: [id]);

  /// Every saved template, by name.
  Future<List<PlanTemplate>> allTemplates() async {
    final rows = await db.query('templates', orderBy: 'name COLLATE NOCASE');
    return [
      for (final r in rows)
        PlanTemplate(
          id: r['id'] as int,
          name: r['name'] as String,
          blocks: [
            for (final item in jsonDecode(r['blocks_json'] as String) as List<dynamic>)
              PlanBlock.fromJson(item as Map<String, dynamic>),
          ],
        ),
    ];
  }

  /// Saves [blocks] under [name], replacing a template of the same name
  /// but keeping its id. Returns the template's id.
  Future<int> saveTemplate(String name, List<PlanBlock> blocks) {
    final json = jsonEncode([for (final b in blocks) b.toJson()]);
    return db.transaction((txn) async {
      final rows = await txn.query('templates', columns: ['id'], where: 'name = ?', whereArgs: [name]);
      if (rows.isEmpty) {
        return txn.insert('templates', {'name': name, 'blocks_json': json});
      }
      final id = rows.first['id'] as int;
      await txn.update('templates', {'blocks_json': json}, where: 'id = ?', whereArgs: [id]);
      return id;
    });
  }

  /// Removes a template; days it was applied to keep their blocks.
  Future<void> deleteTemplate(int id) => db.delete('templates', where: 'id = ?', whereArgs: [id]);

  /// The frozen plan JSON for [date]'s local day, or null if that day was
  /// never frozen.
  Future<String?> frozenPlan(DateTime date) async {
    final rows = await db.query(
      'day_plans',
      columns: ['blocks_json'],
      where: 'date = ?',
      whereArgs: [dateKey(date)],
    );
    return rows.isEmpty ? null : rows.first['blocks_json'] as String;
  }

  /// Frozen plan JSON by yyyy-MM-dd for every frozen day in [from, to).
  /// `day_plans.date` sorts as text in date order, so one query does.
  Future<Map<String, String>> frozenPlansBetween(DateTime from, DateTime to) async {
    final rows = await db.query(
      'day_plans',
      columns: ['date', 'blocks_json'],
      where: 'date >= ? AND date < ?',
      whereArgs: [dateKey(from), dateKey(to)],
    );
    return {for (final r in rows) r['date'] as String: r['blocks_json'] as String};
  }

  /// Stores [json] as [date]'s frozen plan unless one is already stored,
  /// and returns whether it wrote. A frozen plan is never overwritten:
  /// it is the record of what the plan was on that day.
  Future<bool> freezePlan(DateTime date, String json) {
    final key = dateKey(date);
    return db.transaction((txn) async {
      final rows = await txn.query('day_plans', columns: ['date'], where: 'date = ?', whereArgs: [key]);
      if (rows.isNotEmpty) return false;
      await txn.insert('day_plans', {'date': key, 'blocks_json': json});
      return true;
    });
  }

  static Map<String, Object?> _blockToRow(PlanBlock b) => {
        'id': b.id,
        'name': b.name,
        'start_min': b.startMin,
        'end_min': b.endMin,
        'color_idx': b.colorIdx,
        'repeat_mask': b.repeatMask,
        'date': b.date,
        'skip_dates': jsonEncode(b.skipDates),
        'any_app': b.anyApp ? 1 : 0,
      };

  static PlanBlock _blockFromRow(Map<String, Object?> r) {
    final skip = r['skip_dates'] as String?;
    return PlanBlock(
      id: r['id'] as int,
      name: r['name'] as String? ?? '',
      startMin: r['start_min'] as int? ?? 0,
      endMin: r['end_min'] as int? ?? 0,
      colorIdx: r['color_idx'] as int? ?? 0,
      repeatMask: r['repeat_mask'] as int? ?? 0,
      date: r['date'] as String?,
      skipDates: skip == null || skip.isEmpty
          ? const []
          : [for (final d in jsonDecode(skip) as List<dynamic>) d as String],
      anyApp: (r['any_app'] as int? ?? 0) != 0,
    );
  }
}
