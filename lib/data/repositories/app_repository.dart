import 'package:sqflite/sqflite.dart';

import '../../domain/models.dart';

/// The launchable apps last reported by Android, with their categories.
/// Uninstalled apps stay, so old sessions keep a label and a category.
class AppRepository {
  AppRepository(this.db);

  final Database db;

  /// Inserts or refreshes [apps] in one transaction, stamping them as
  /// seen at [seen].
  Future<void> upsertAll(List<AppInfo> apps, DateTime seen) async {
    if (apps.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final a in apps) {
        batch.insert(
          'apps',
          {
            'p': a.p,
            'label': a.label,
            'category': a.category,
            'last_seen_ms': seen.millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Every known app, by label.
  Future<List<AppInfo>> all() async {
    final rows = await db.query('apps', orderBy: 'label COLLATE NOCASE, p');
    return [
      for (final r in rows)
        AppInfo(
          p: r['p'] as String,
          label: r['label'] as String? ?? r['p'] as String,
          category: r['category'] as String? ?? 'undefined',
        ),
    ];
  }

  /// Package to category, the shape the classifier takes.
  Future<Map<String, String>> categoryMap() async {
    final rows = await db.query('apps', columns: ['p', 'category']);
    return {
      for (final r in rows) r['p'] as String: r['category'] as String? ?? 'undefined',
    };
  }
}
