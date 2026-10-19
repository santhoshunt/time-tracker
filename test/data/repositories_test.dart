import 'package:drift_time/data/drift_db.dart';
import 'package:drift_time/data/repositories/app_repository.dart';
import 'package:drift_time/data/repositories/event_repository.dart';
import 'package:drift_time/data/repositories/meta_repository.dart';
import 'package:drift_time/data/repositories/plan_repository.dart';
import 'package:drift_time/data/repositories/rule_repository.dart';
import 'package:drift_time/data/repositories/session_repository.dart';
import 'package:drift_time/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const video = 'com.example.video';
const chat = 'com.example.chat';
const notes = 'com.example.notes';

DateTime at(int h, int m) => DateTime(2026, 10, 19, h, m);
final day = DateTime(2026, 10, 19);
final nextDay = DateTime(2026, 10, 20);
int ms(DateTime t) => t.millisecondsSinceEpoch;

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await openDriftDb(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
  });

  tearDown(() => db.close());

  test('openDriftDb creates every table at version 1', () async {
    final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name");
    expect(rows.map((r) => r['name']), containsAll([
      'app_rules',
      'apps',
      'blocks',
      'day_plans',
      'gaps',
      'idle_spans',
      'meta',
      'raw_events',
      'session_overrides',
      'sessions',
      'templates',
    ]));
    expect(await db.getVersion(), driftDbVersion);
  });

  group('EventRepository', () {
    late EventRepository repo;
    setUp(() => repo = EventRepository(db));

    final events = [
      RawEvent(ms(at(9, 0)), video, 'Main', EventKind.resumed),
      RawEvent(ms(at(9, 30)), video, 'Main', EventKind.paused),
      RawEvent(ms(at(9, 40)), 'android', null, EventKind.screenOff),
    ];

    test('round trip keeps order and a null class', () async {
      expect(await repo.insertAll(events), 3);
      expect(await repo.between(ms(day), ms(nextDay)), events);
    });

    test('duplicates are ignored, including events with no class', () async {
      await repo.insertAll(events);
      expect(await repo.insertAll([...events, RawEvent(ms(at(10, 0)), 'android', null, EventKind.screenOn)]), 1);
      expect(await repo.between(ms(day), ms(nextDay)), hasLength(4));
    });

    test('between is half-open', () async {
      await repo.insertAll(events);
      expect(await repo.between(ms(at(9, 0)), ms(at(9, 30))), [events.first]);
    });

    test('pruneBefore deletes older events only', () async {
      await repo.insertAll(events);
      expect(await repo.pruneBefore(ms(at(9, 30))), 1);
      expect(await repo.between(0, ms(nextDay)), events.sublist(1));
    });
  });

  group('SessionRepository', () {
    late SessionRepository repo;
    late RuleRepository rules;
    setUp(() {
      repo = SessionRepository(db);
      rules = RuleRepository(db);
    });

    test('replaceDay round trip for sessions and idle spans', () async {
      await repo.replaceDay(day, nextDay, [
        Session(p: video, start: at(9, 0), end: at(9, 30)),
        Session(p: chat, start: at(10, 0), end: at(10, 5)),
      ], [
        IdleSpan(at(9, 30), at(10, 0), IdleKind.screenOff),
        IdleSpan(at(9, 31), at(9, 59), IdleKind.locked),
      ]);
      final sessions = await repo.sessionsBetween(day, nextDay);
      expect(sessions.map((s) => (s.p, s.start, s.end)), [
        (video, at(9, 0), at(9, 30)),
        (chat, at(10, 0), at(10, 5)),
      ]);
      expect(sessions.every((s) => s.id != null), isTrue);
      expect(await repo.idleBetween(day, nextDay), [
        IdleSpan(at(9, 30), at(10, 0), IdleKind.screenOff),
        IdleSpan(at(9, 31), at(9, 59), IdleKind.locked),
      ]);
    });

    test('rebuilding a day keeps session ids and their overrides', () async {
      await repo.replaceDay(day, nextDay, [Session(p: video, start: at(9, 0), end: at(9, 10))], const []);
      final id = (await repo.sessionsBetween(day, nextDay)).single.id!;
      await rules.setOverride(id, Verdict.onTrack);

      await repo.replaceDay(day, nextDay, [Session(p: video, start: at(9, 0), end: at(9, 45))], const []);
      final rebuilt = (await repo.sessionsBetween(day, nextDay)).single;
      expect(rebuilt.id, id);
      expect(rebuilt.end, at(9, 45));
      expect(await rules.allOverrides(), {id: Verdict.onTrack});
    });

    test('a session gone from a rebuild is deleted with its override', () async {
      await repo.replaceDay(day, nextDay, [
        Session(p: video, start: at(9, 0), end: at(9, 10)),
        Session(p: chat, start: at(9, 10), end: at(9, 20)),
      ], const []);
      final chatId = (await repo.sessionsBetween(day, nextDay)).last.id!;
      await rules.setOverride(chatId, Verdict.offTrack);

      await repo.replaceDay(day, nextDay, [Session(p: video, start: at(9, 0), end: at(9, 20))], const []);
      expect((await repo.sessionsBetween(day, nextDay)).map((s) => s.p), [video]);
      expect(await rules.allOverrides(), isEmpty);
    });

    test('replaceDay ignores items starting on another day and leaves other days alone', () async {
      final prevDay = DateTime(2026, 10, 18);
      final crossing = Session(p: video, start: DateTime(2026, 10, 18, 23, 30), end: at(0, 30));
      await repo.replaceDay(prevDay, day, [crossing], const []);
      await repo.replaceDay(day, nextDay, [crossing, Session(p: chat, start: at(8, 0), end: at(8, 5))], const []);
      final today = await repo.sessionsBetween(day, nextDay);
      expect(today.map((s) => s.p), [video, chat], reason: 'overlap query returns the crossing session');
      expect(today.first.start, DateTime(2026, 10, 18, 23, 30));
    });

    test('gaps: a new gap is added once and a longer end extends it', () async {
      expect(await repo.addGap(GapSpan(at(1, 0), at(3, 0))), isTrue);
      expect(await repo.addGap(GapSpan(at(1, 0), at(3, 0))), isFalse);
      expect(await repo.addGap(GapSpan(at(1, 0), at(4, 0))), isFalse);
      expect(await repo.addGap(GapSpan(at(5, 0), at(5, 0))), isFalse, reason: 'empty span');
      expect(await repo.gapsBetween(day, nextDay), [GapSpan(at(1, 0), at(4, 0))]);
      expect(await repo.gapsBetween(at(3, 30), at(3, 45)), [GapSpan(at(1, 0), at(4, 0))]);
      expect(await repo.gapsBetween(at(4, 0), at(5, 0)), isEmpty);
    });
  });

  group('PlanRepository', () {
    late PlanRepository repo;
    setUp(() => repo = PlanRepository(db));

    const deep = PlanBlock(
      name: 'Deep work',
      startMin: 540,
      endMin: 660,
      colorIdx: 2,
      repeatMask: PlanBlock.weekdays,
      skipDates: ['2026-10-21'],
      anyApp: true,
    );
    const dentist = PlanBlock(name: 'Dentist', startMin: 900, endMin: 960, date: '2026-10-20');

    test('blocks: insert, read, update and delete', () async {
      final id = await repo.insertBlock(deep);
      final id2 = await repo.insertBlock(dentist);
      expect(await repo.allBlocks(), [deep.copyWith(id: id), dentist.copyWith(id: id2)]);

      await repo.updateBlock(deep.copyWith(id: id, startMin: 480, skipDates: const []));
      expect((await repo.allBlocks()).first, deep.copyWith(id: id, startMin: 480, skipDates: const []));

      await repo.deleteBlock(id);
      expect(await repo.allBlocks(), [dentist.copyWith(id: id2)]);
    });

    test('templates: save, replace by name keeping the id, delete', () async {
      final id = await repo.saveTemplate('Workday', [deep]);
      expect(await repo.saveTemplate('Workday', [deep, dentist]), id);
      final all = await repo.allTemplates();
      expect(all.single.name, 'Workday');
      expect(all.single.blocks, [deep, dentist]);
      await repo.deleteTemplate(id);
      expect(await repo.allTemplates(), isEmpty);
    });

    test('a day plan is written once and never overwritten', () async {
      expect(await repo.frozenPlan(day), isNull);
      expect(await repo.freezePlan(day, '[1]'), isTrue);
      expect(await repo.freezePlan(day, '[2]'), isFalse);
      expect(await repo.frozenPlan(day), '[1]');
    });
  });

  group('RuleRepository', () {
    late RuleRepository repo;
    setUp(() => repo = RuleRepository(db));

    test('rules: upsert by block key, replace, delete', () async {
      await repo.upsertRule('Deep Work ', video, Verdict.offTrack, at(9, 0));
      await repo.upsertRule('deep work', video, Verdict.onTrack, at(9, 5));
      await repo.upsertRule('Evening', chat, Verdict.offTrack, at(9, 5));
      expect(await repo.allRules(), {
        ('deep work', video): Verdict.onTrack,
        ('evening', chat): Verdict.offTrack,
      });
      await repo.deleteRule('EVENING', chat);
      expect(await repo.allRules(), {('deep work', video): Verdict.onTrack});
    });

    test('only on and off can be stored', () async {
      expect(() => repo.upsertRule('Deep work', video, Verdict.guessedOff, at(9, 0)), throwsArgumentError);
      expect(() => repo.setOverride(1, Verdict.idle), throwsArgumentError);
    });

    test('overrides: set, replace, delete, and filter by day', () async {
      final sessions = SessionRepository(db);
      await sessions.replaceDay(day, nextDay, [
        Session(p: video, start: at(9, 0), end: at(9, 10)),
        Session(p: chat, start: at(23, 50), end: DateTime(2026, 10, 20, 0, 10)),
      ], const []);
      final ids = [for (final s in await sessions.sessionsBetween(day, nextDay)) s.id!];
      await repo.setOverride(ids[0], Verdict.offTrack);
      await repo.setOverride(ids[0], Verdict.onTrack);
      await repo.setOverride(ids[1], Verdict.offTrack);
      expect(await repo.allOverrides(), {ids[0]: Verdict.onTrack, ids[1]: Verdict.offTrack});
      expect(await repo.overridesBetween(nextDay, DateTime(2026, 10, 21)), {ids[1]: Verdict.offTrack});
      await repo.deleteOverride(ids[0]);
      expect(await repo.allOverrides(), {ids[1]: Verdict.offTrack});
    });
  });

  group('AppRepository', () {
    test('upsertAll, all and categoryMap', () async {
      final repo = AppRepository(db);
      await repo.upsertAll(const [
        AppInfo(p: video, label: 'Video', category: 'video'),
        AppInfo(p: notes, label: 'notes', category: 'productivity'),
      ], at(9, 0));
      await repo.upsertAll(const [AppInfo(p: video, label: 'Video Plus', category: 'video')], at(10, 0));
      expect(await repo.all(), const [
        AppInfo(p: notes, label: 'notes', category: 'productivity'),
        AppInfo(p: video, label: 'Video Plus', category: 'video'),
      ]);
      expect(await repo.categoryMap(), {video: 'video', notes: 'productivity'});
    });

    test('AppInfo.fromMap maps an unknown category to undefined', () {
      expect(AppInfo.fromMap({'p': chat, 'label': 'Chat', 'category': 'weird'}),
          const AppInfo(p: chat, label: 'Chat', category: 'undefined'));
      expect(AppInfo.fromMap({'label': 'No package'}), isNull);
    });
  });

  group('MetaRepository', () {
    test('getInt is null until set, then round trips', () async {
      final repo = MetaRepository(db);
      expect(await repo.getInt('ingest_cursor_ms'), isNull);
      await repo.setInt('ingest_cursor_ms', 42);
      await repo.setInt('ingest_cursor_ms', ms(at(9, 0)));
      expect(await repo.getInt('ingest_cursor_ms'), ms(at(9, 0)));
    });
  });
}
