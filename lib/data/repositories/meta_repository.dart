import 'package:sqflite/sqflite.dart';

/// Small bookkeeping values that belong with the data, such as the ingest
/// cursor. Kept in the database rather than SharedPreferences so they
/// can never disagree with the rows they describe after a restore or a
/// cleared cache.
class MetaRepository {
  MetaRepository(this.db);

  final Database db;

  /// The integer stored under [key], or null when unset or not a number.
  Future<int?> getInt(String key) async {
    final rows = await db.query('meta', columns: ['value'], where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return int.tryParse(rows.first['value'] as String? ?? '');
  }

  /// Stores [value] under [key], replacing any earlier value.
  Future<void> setInt(String key, int value) async {
    await db.insert(
      'meta',
      {'key': key, 'value': value.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
