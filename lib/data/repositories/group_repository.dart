import 'package:sqflite/sqflite.dart';

import '../../domain/app_groups.dart';
import '../../domain/models.dart';

/// App groups, their apps, and the blocks that use them (schema version 2).
class GroupRepository {
  GroupRepository(this.db);

  final Database db;

  /// Every group with its apps, in the order they were made, then by name.
  Future<List<AppGroup>> all() async {
    final rows = await db.query('app_groups', orderBy: 'sort, name COLLATE NOCASE, id');
    final members = await db.query('app_group_members');
    final apps = <int, Set<String>>{};
    for (final m in members) {
      (apps[m['group_id'] as int] ??= <String>{}).add(m['p'] as String);
    }
    return [
      for (final r in rows)
        AppGroup(
          id: r['id'] as int,
          name: r['name'] as String? ?? '',
          emoji: r['emoji'] as String? ?? '',
          colorIdx: r['color_idx'] as int? ?? 0,
          kind: GroupKind.fromKey(r['kind'] as String?),
          apps: apps[r['id'] as int] ?? const {},
        ),
    ];
  }

  /// Inserts [group] (no id) or updates it, replacing its apps, in one
  /// transaction. Returns the id.
  Future<int> save(AppGroup group) => db.transaction((txn) async {
    final row = {
      'name': group.name,
      'emoji': group.emoji,
      'color_idx': group.colorIdx,
      'kind': group.kind.name,
    };
    final int id;
    if (group.id == null) {
      final sort = Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COALESCE(MAX(sort), -1) + 1 FROM app_groups'),
          ) ??
          0;
      id = await txn.insert('app_groups', {...row, 'sort': sort});
    } else {
      id = group.id!;
      await txn.update('app_groups', row, where: 'id = ?', whereArgs: [id]);
      await txn.delete('app_group_members', where: 'group_id = ?', whereArgs: [id]);
    }
    final batch = txn.batch();
    for (final p in group.apps) {
      batch.insert('app_group_members', {'group_id': id, 'p': p});
    }
    await batch.commit(noResult: true);
    return id;
  });

  /// Removes a group, its apps and every block's use of it.
  Future<void> delete(int id) => db.transaction((txn) async {
    await txn.delete('app_groups', where: 'id = ?', whereArgs: [id]);
    await txn.delete('app_group_members', where: 'group_id = ?', whereArgs: [id]);
    await txn.delete('block_groups', where: 'group_id = ?', whereArgs: [id]);
  });

  /// The groups blocks named [blockName] use, by id.
  Future<Map<int, Verdict>> forBlock(String blockName) async {
    final rows = await db.query(
      'block_groups',
      where: 'block_key = ?',
      whereArgs: [blockKey(blockName)],
    );
    return {for (final r in rows) r['group_id'] as int: ?_fromDb(r['verdict'] as String?)};
  }

  /// Replaces the groups blocks named [blockName] use.
  Future<void> setForBlock(String blockName, Map<int, Verdict> groups) =>
      db.transaction((txn) async {
        final key = blockKey(blockName);
        await txn.delete('block_groups', where: 'block_key = ?', whereArgs: [key]);
        for (final MapEntry(key: groupId, value: verdict) in groups.entries) {
          await txn.insert('block_groups', {
            'block_key': key,
            'group_id': groupId,
            'verdict': verdict == Verdict.offTrack ? 'off' : 'on',
          });
        }
      });

  /// A block renamed from [oldName] to [newName] takes its groups along;
  /// with [keepOld] (the old name is still used by another block) they are
  /// copied instead, as the block editor does with app rules.
  Future<void> moveBlock(String oldName, String newName, {required bool keepOld}) async {
    if (blockKey(oldName) == blockKey(newName)) return;
    final groups = await forBlock(oldName);
    await setForBlock(newName, groups);
    if (!keepOld) await setForBlock(oldName, const {});
  }

  /// Everything the classifier and the nudge snapshot need, in two queries
  /// and the group read.
  Future<AppGroups> snapshot() async {
    final groups = await all();
    if (groups.isEmpty) return AppGroups.none;
    final links = await db.query('block_groups');
    final byBlock = <String, Map<int, Verdict>>{};
    for (final r in links) {
      final v = _fromDb(r['verdict'] as String?);
      if (v == null) continue;
      (byBlock[r['block_key'] as String] ??= {})[r['group_id'] as int] = v;
    }
    return AppGroups(groups: groups, byBlock: byBlock);
  }

  static Verdict? _fromDb(String? s) => switch (s) {
    'on' => Verdict.onTrack,
    'off' => Verdict.offTrack,
    _ => null,
  };
}
