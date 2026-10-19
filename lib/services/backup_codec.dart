import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../app_services.dart';
import '../domain/ingestor.dart';
import '../providers/settings_provider.dart';

/// The `app` value every Drift backup carries.
const backupApp = 'drift';

/// The newest payload shape this build reads and writes.
const backupVersion = 1;

/// Every table a backup holds, in the order it is written back.
/// `raw_events` is left out: it is pruned after a few days and every
/// session is already derived from it.
const backupTables = [
  'blocks',
  'templates',
  'day_plans',
  'app_rules',
  'session_overrides',
  'apps',
  'sessions',
  'idle_spans',
  'gaps',
  'meta',
];

/// The SharedPreferences keys SettingsProvider owns, with the type each is
/// stored as. They are read and written here directly because
/// SettingsProvider has no backup methods; after an import
/// [SettingsProvider.load] picks the new values up. Drive's own `drive_`
/// keys and the updater's `update_` keys are left out: they describe this
/// install (its connection, its version history), not a choice the user
/// made, and restoring them could show a false "Updated to" toast.
const backupSettingKeys = <String, PrefType>{
  'theme_v1': PrefType.string,
  'today_view_v1': PrefType.string,
  'nudges_enabled_v1': PrefType.boolean,
  'nudge_after_min_v1': PrefType.integer,
  'nudge_repeat_min_v1': PrefType.integer,
  'quiet_start_min_v1': PrefType.integer,
  'quiet_end_min_v1': PrefType.integer,
  'setup_skipped_v1': PrefType.stringList,
  'week_start_v1': PrefType.string,
  'summary_enabled_v1': PrefType.boolean,
  'summary_minute_v1': PrefType.integer,
  'focus_lock_v1': PrefType.boolean,
  'weekly_target_v1': PrefType.integer,
};

/// How a setting is stored in SharedPreferences.
enum PrefType { string, boolean, integer, stringList }

/// Why a backup can't be restored. [message] is shown as is.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Every table but raw_events, read in one transaction so an ingest landing
/// half-way can't mix two moments, plus the settings.
///
/// [settings] is taken so callers pass the provider whose values are
/// current; its preferences are read from SharedPreferences, where every
/// setter has already written them.
Future<Map<String, Object?>> exportAll(
  AppServices s,
  SettingsProvider settings,
) async {
  final tables = await s.db.transaction((txn) async {
    return {
      for (final t in backupTables) t: await txn.query(t),
    };
  });
  return {
    'app': backupApp,
    'version': backupVersion,
    'exportedAt': s.clock.now().toUtc().toIso8601String(),
    'tables': tables,
    'settings': await _readSettings(),
  };
}

Future<Map<String, Object?>> _readSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in backupSettingKeys.entries) {
    try {
      final v = value == PrefType.stringList
          ? prefs.getStringList(key)
          : prefs.get(key);
      if (v != null) out[key] = v;
    } catch (e) {
      debugPrint('Backup skipped setting $key: $e');
    }
  }
  return out;
}

/// Gzipped JSON. Top-level so [compute] can run it in another isolate.
Uint8List encodeBackupGz(Map<String, Object?> data) =>
    Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(data))));

/// The inverse of [encodeBackupGz]. Throws [FormatException] for anything
/// that isn't a gzipped JSON object.
Map<String, dynamic> decodeBackupGz(Uint8List bytes) {
  final List<int> raw;
  try {
    raw = gzip.decode(bytes);
  } catch (_) {
    throw const FormatException('Not a gzip backup file');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(raw));
  } catch (_) {
    throw const FormatException('Not a Drift backup file');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Not a Drift backup file');
  }
  return decoded;
}

/// [encodeBackupGz] in a worker isolate.
Future<Uint8List> encodeBackupGzAsync(Map<String, Object?> data) =>
    compute(encodeBackupGz, data, debugLabel: 'encodeBackupGz');

/// [decodeBackupGz] in a worker isolate.
Future<Map<String, dynamic>> decodeBackupGzAsync(Uint8List bytes) =>
    compute(decodeBackupGz, bytes, debugLabel: 'decodeBackupGz');

/// Replaces every backed-up table with [data]'s rows in one transaction,
/// then the settings, then bumps [AppServices.revision].
///
/// Everything is checked before anything is deleted: a backup from another
/// app, from a newer Drift, or missing a table throws
/// [BackupFormatException] and changes nothing. A row that fails to insert
/// rolls the whole transaction back.
///
/// raw_events is not touched. `meta` comes back as it was backed up, except
/// the ingest cursor, which moves to just after the backup's last day (see
/// [_resumeCursor]): the next ingest then refills the days since the
/// backup from this phone's own events without rewriting the last day the
/// backup holds.
Future<void> importAll(
  AppServices s,
  SettingsProvider settings,
  Map<String, dynamic> data,
) async {
  final tables = _validated(data);

  // Joins an ingest already running, so its cursor write can't land on
  // top of the restored one.
  await s.ingest();

  final cursor = _resumeCursor(tables['meta']!, s.clock.now());
  await s.db.transaction((txn) async {
    final batch = txn.batch();
    for (final t in backupTables) {
      batch.delete(t);
      for (final row in tables[t]!) {
        batch.insert(t, row);
      }
    }
    if (cursor != null) {
      batch.insert('meta', {
        'key': Ingestor.cursorKey,
        'value': '$cursor',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  });

  final block = data['settings'];
  await _writeSettings(block is Map ? block : const {});
  await settings.load();
  s.bump();
}

/// The ingest cursor to restore with, or null to keep the backup's own.
///
/// The ingestor rebuilds every day from the cursor's day (less
/// [Ingestor.queryOverlap]) out of this phone's raw events. With the
/// backup's cursor as is, the next ingest would rebuild the backup's last
/// day and replace that day's restored sessions (and their overrides) with
/// this phone's events. Moving the cursor to the start of the next day,
/// plus the overlap, makes the first rebuilt day the day after the
/// backup's, so the restored day stays whole and the days since are
/// filled from this phone. When the backup's cursor is today there is no
/// such day yet, so the backup's cursor stays and today is rebuilt.
int? _resumeCursor(List<Map<String, Object?>> meta, DateTime now) {
  final row = meta.where((r) => r['key'] == Ingestor.cursorKey).firstOrNull;
  final ms = int.tryParse('${row?['value']}');
  if (ms == null) return null;
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final nextDay = DateTime(t.year, t.month, t.day + 1);
  if (nextDay.isAfter(now)) return null;
  return nextDay.add(Ingestor.queryOverlap).millisecondsSinceEpoch;
}

Map<String, List<Map<String, Object?>>> _validated(Map<String, dynamic> data) {
  final app = data['app'];
  if (app != backupApp) {
    throw BackupFormatException(
      app is String
          ? 'This is a backup from "$app", not from Drift.'
          : 'This file is not a Drift backup.',
    );
  }
  final version = data['version'];
  if (version is! int || version < 1) {
    throw const BackupFormatException('This Drift backup has no valid version.');
  }
  if (version > backupVersion) {
    throw BackupFormatException(
      'This backup is from a newer Drift (format $version). Update Drift, '
      'then restore it.',
    );
  }
  final raw = data['tables'];
  if (raw is! Map) {
    throw const BackupFormatException('This Drift backup has no tables.');
  }
  final out = <String, List<Map<String, Object?>>>{};
  for (final t in backupTables) {
    final rows = raw[t];
    if (rows is! List || rows.any((r) => r is! Map)) {
      throw BackupFormatException('This Drift backup is missing the $t table.');
    }
    out[t] = [
      for (final r in rows) Map<String, Object?>.from(r as Map),
    ];
  }
  return out;
}

/// Replace semantics: a key the backup lacks goes back to its default.
/// A value of the wrong type is dropped the same way.
Future<void> _writeSettings(Map<dynamic, dynamic> block) async {
  final prefs = await SharedPreferences.getInstance();
  for (final MapEntry(:key, :value) in backupSettingKeys.entries) {
    final v = block[key];
    try {
      switch ((value, v)) {
        case (PrefType.string, final String s):
          await prefs.setString(key, s);
        case (PrefType.boolean, final bool b):
          await prefs.setBool(key, b);
        case (PrefType.integer, final int i):
          await prefs.setInt(key, i);
        case (PrefType.stringList, final List<dynamic> l):
          // JSON hands lists back as List<dynamic>.
          await prefs.setStringList(key, [for (final e in l) '$e']);
        default:
          await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('Restore skipped setting $key: $e');
    }
  }
}
