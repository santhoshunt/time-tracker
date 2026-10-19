import 'dart:io';

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/ingestor.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/backup_codec.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// A non-default value for every setting, so a restore that silently fell
/// back to defaults can't pass.
const _settings = <String, Object>{
  'theme_v1': 'warmPaper',
  'today_view_v1': 'ring',
  'nudges_enabled_v1': false,
  'nudge_after_min_v1': 10,
  'nudge_repeat_min_v1': 30,
  'quiet_start_min_v1': 1380,
  'quiet_end_min_v1': 360,
  'setup_skipped_v1': ['overlay', 'notifications'],
  'week_start_v1': 'sunday',
  'summary_enabled_v1': false,
  'summary_minute_v1': 1200,
};

/// Fills every backed-up table with at least one row.
Future<void> _seedAll(AppServices s) async {
  await seedSampleDay(s, testNow);
  final sessionId =
      (await s.db.query('sessions', columns: ['id'], limit: 1)).first['id']
          as int;
  await s.db.insert('session_overrides', {
    'session_id': sessionId,
    'verdict': 'on',
  });
  await s.db.insert('templates', {
    'name': 'Weekend',
    'blocks_json': '[{"name":"Walk","startMin":480,"endMin":540}]',
  });
  await s.db.insert('day_plans', {
    'date': '2026-10-18',
    'blocks_json': '[{"name":"Read","startMin":600,"endMin":660}]',
  });
  await s.db.insert('gaps', {'start_ms': 1760900000000, 'end_ms': 1760903600000});
  await s.db.insert('meta', {'key': 'ingest_cursor', 'value': '1760910000000'});
  await s.db.insert('raw_events', {
    't': 1760910000000,
    'p': 'com.example.notes',
    'c': '',
    'k': 'resumed',
  });
}

Future<Map<String, List<Map<String, Object?>>>> _tables(AppServices s) async => {
  for (final t in backupTables) t: await s.db.query(t, orderBy: 'rowid'),
};

/// Databases opened by a test. An in-memory database stays shared until it
/// is closed, so a second phone needs the first one closed.
final _open = <AppServices>[];

Future<AppServices> _services() async {
  final s = await testServices();
  _open.add(s);
  return s;
}

/// Exports [s] and closes its database, so the next [_services] call is
/// a different phone.
Future<Map<String, dynamic>> _exportAndClose(
  AppServices s,
  SettingsProvider settings,
) async {
  final data = decodeBackupGz(encodeBackupGz(await exportAll(s, settings)));
  await s.db.close();
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    for (final s in _open) {
      if (s.db.isOpen) await s.db.close();
    }
    _open.clear();
  });

  test('the codec covers every SettingsProvider key', () {
    final source = File(
      'lib/providers/settings_provider.dart',
    ).readAsStringSync();
    final keys = {
      for (final m in RegExp(
        r"static const _k\w+ = '([^']+)'",
      ).allMatches(source))
        m.group(1)!,
    }..removeWhere((k) => k.startsWith('drive_') || k.startsWith('update_'));
    expect(backupSettingKeys.keys.toSet(), keys);
  });

  test('update keys describe this install and are never restored', () {
    expect(backupSettingKeys.keys.where((k) => k.startsWith('update_')), isEmpty);
  });

  group('round trip', () {
    late Map<String, List<Map<String, Object?>>> before;
    late Map<String, dynamic> decoded;

    setUp(() async {
      SharedPreferences.setMockInitialValues(Map.of(_settings));
      final settings = SettingsProvider();
      await settings.load();
      final from = await _services();
      await _seedAll(from);
      before = await _tables(from);
      decoded = await _exportAndClose(from, settings);
    });

    test('exports every table but raw_events, and every setting', () {
      expect(decoded['app'], 'drift');
      expect(decoded['version'], 1);
      expect(DateTime.tryParse(decoded['exportedAt'] as String), isNotNull);
      final tables = decoded['tables'] as Map<String, dynamic>;
      expect(tables.keys.toSet(), backupTables.toSet());
      expect(tables.containsKey('raw_events'), isFalse);
      for (final t in backupTables) {
        expect((tables[t] as List), isNotEmpty, reason: t);
      }
      expect(decoded['settings'], _settings);
    });

    test('a fresh phone gets every row and setting back', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.load();
      final to = await _services();
      var bumps = 0;
      to.revision.addListener(() => bumps++);

      await importAll(to, settings, decoded);

      final after = await _tables(to);
      for (final t in backupTables) {
        expect(after[t], before[t], reason: t);
      }
      // The override still points at its session.
      final joined = await to.db.rawQuery(
        'SELECT COUNT(*) AS n FROM session_overrides o '
        'JOIN sessions s ON s.id = o.session_id',
      );
      expect(joined.first['n'], 1);
      expect(await to.db.query('raw_events'), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      for (final MapEntry(:key, :value) in _settings.entries) {
        expect(prefs.get(key), value, reason: key);
      }
      // Through SettingsProvider, so the app sees it without a restart.
      expect(settings.theme, ThemeId.warmPaper);
      expect(settings.nudgeAfterMin, 10);
      expect(settings.firstWeekday, DateTime.sunday);
      expect(settings.skippedSetup, {'overlay', 'notifications'});
      expect(bumps, greaterThan(0));
    });

    test('rows already on the phone are replaced, raw_events kept', () async {
      SharedPreferences.setMockInitialValues({'theme_v1': 'blackCyan'});
      final settings = SettingsProvider();
      await settings.load();
      final to = await _services();
      await to.plans.insertBlock(
        const PlanBlock(name: 'Old', startMin: 60, endMin: 120),
      );
      await to.db.insert('raw_events', {
        // Recent, so the ingest importAll runs first doesn't prune it.
        't': testNow.millisecondsSinceEpoch,
        'p': 'com.example.video',
        'c': '',
        'k': 'resumed',
      });
      final backup = Map<String, dynamic>.of(decoded)
        ..['settings'] = {'theme_v1': 'cleanLight'};

      await importAll(to, settings, backup);

      expect((await _tables(to))['blocks'], before['blocks']);
      expect(await to.db.query('raw_events'), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_v1'), 'cleanLight');
      // A setting the backup lacks goes back to its default.
      expect(prefs.containsKey('nudge_after_min_v1'), isFalse);
      expect(settings.nudgeAfterMin, 5);
    });
  });

  test('the first ingest after a restore keeps the backup\'s last day', () async {
    final settings = await testSettings();
    final from = await _services();
    await seedSampleDay(from, testNow);
    final sessionId =
        (await from.db.query('sessions', columns: ['id'], limit: 1))
                .first['id']
            as int;
    await from.rules.setOverride(sessionId, Verdict.onTrack);
    // The old phone last ingested at 22:00 on the seeded day.
    await from.meta.setInt(
      Ingestor.cursorKey,
      DateTime(2026, 10, 19, 22).millisecondsSinceEpoch,
    );
    final day = await from.sessions.sessionsBetween(
      DateTime(2026, 10, 19),
      DateTime(2026, 10, 20),
    );
    final data = await _exportAndClose(from, settings);

    // A new phone the next morning, with none of that day's events.
    final to = await testServices(now: DateTime(2026, 10, 20, 10));
    _open.add(to);
    await importAll(to, settings, data);
    await to.ingest();

    final kept = await to.sessions.sessionsBetween(
      DateTime(2026, 10, 19),
      DateTime(2026, 10, 20),
    );
    expect(kept, hasLength(day.length));
    expect(await to.rules.allOverrides(), {sessionId: Verdict.onTrack});
  });

  group('rejected backups change nothing', () {
    late AppServices to;
    late SettingsProvider settings;
    late Map<String, List<Map<String, Object?>>> original;
    late Map<String, dynamic> valid;

    setUp(() async {
      SharedPreferences.setMockInitialValues(Map.of(_settings));
      final fromSettings = SettingsProvider();
      await fromSettings.load();
      final from = await _services();
      await _seedAll(from);
      valid = await _exportAndClose(from, fromSettings);

      SharedPreferences.setMockInitialValues({'theme_v1': 'mono'});
      settings = SettingsProvider();
      await settings.load();
      to = await _services();
      await to.plans.insertBlock(
        const PlanBlock(name: 'Mine', startMin: 600, endMin: 660, repeatMask: PlanBlock.everyDay),
      );
      await to.db.insert('apps', {'p': 'com.mine', 'label': 'Mine'});
      // One ingest first, so the one importAll runs before restoring only
      // moves the cursor.
      await to.ingest();
      original = await _tables(to);
    });

    Future<void> expectUnchanged() async {
      final now = await _tables(to);
      for (final t in backupTables) {
        expect(now[t], original[t], reason: t);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_v1'), 'mono');
    }

    test('a backup from another app', () async {
      final foreign = Map<String, dynamic>.of(valid)
        ..['app'] = 'expense_tracker';
      await expectLater(
        importAll(to, settings, foreign),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('expense_tracker'),
          ),
        ),
      );
      await expectUnchanged();
    });

    test('a backup from a newer Drift', () async {
      final newer = Map<String, dynamic>.of(valid)..['version'] = 2;
      await expectLater(
        importAll(to, settings, newer),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('newer Drift'),
          ),
        ),
      );
      await expectUnchanged();
    });

    test('a backup missing a table', () async {
      final tables = Map<String, dynamic>.of(
        valid['tables'] as Map<String, dynamic>,
      )..remove('gaps');
      final partial = Map<String, dynamic>.of(valid)..['tables'] = tables;
      await expectLater(
        importAll(to, settings, partial),
        throwsA(isA<BackupFormatException>()),
      );
      await expectUnchanged();
    });

    test('a row that fails to insert rolls every table back', () async {
      final tables = Map<String, dynamic>.of(
        valid['tables'] as Map<String, dynamic>,
      );
      // meta is written last, after every other table was already
      // deleted and refilled inside the transaction.
      expect(backupTables.last, 'meta');
      tables['meta'] = [
        ...(tables['meta'] as List),
        {'key': 'bad', 'value': 'x', 'no_such_column': 1},
      ];
      final broken = Map<String, dynamic>.of(valid)..['tables'] = tables;
      await expectLater(importAll(to, settings, broken), throwsA(anything));
      // The ingest importAll runs first rewrites the cursor row in meta;
      // every other table must hold exactly what it did.
      final now = await _tables(to);
      for (final t in backupTables.where((t) => t != 'meta')) {
        expect(now[t], original[t], reason: t);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_v1'), 'mono');
    });
  });

  test('garbage bytes are rejected with FormatException', () {
    expect(
      () => decodeBackupGz(encodeBackupGz({}).sublist(0, 5)),
      throwsFormatException,
    );
  });
}
