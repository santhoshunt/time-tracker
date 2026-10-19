import 'dart:convert';

import 'package:drift_time/data/drift_db.dart';
import 'package:drift_time/data/repositories/app_repository.dart';
import 'package:drift_time/data/repositories/event_repository.dart';
import 'package:drift_time/data/repositories/meta_repository.dart';
import 'package:drift_time/data/repositories/plan_repository.dart';
import 'package:drift_time/data/repositories/rule_repository.dart';
import 'package:drift_time/data/repositories/session_repository.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/domain/ingestor.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/plan_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_usage_source.dart';

const video = 'com.example.video';
const chat = 'com.example.chat';
const notes = 'com.example.notes';
const launcher = 'com.example.launcher';

DateTime at(int h, int m, {int day = 19}) => DateTime(2026, 10, day, h, m);
int ms(DateTime t) => t.millisecondsSinceEpoch;

/// Throws from insertAll on the calls listed in [failOn] (1-based), to
/// stand in for a commit that fails.
class FailingEventRepository extends EventRepository {
  FailingEventRepository(super.db, this.failOn);

  final Set<int> failOn;
  int calls = 0;

  @override
  Future<int> insertAll(List<RawEvent> events) {
    calls++;
    if (failOn.contains(calls)) throw StateError('disk full');
    return super.insertAll(events);
  }
}

String jsonl(List<Map<String, Object?>> events) => events.map(jsonEncode).join('\n');

void main() {
  late Database db;
  late FakeUsageSource source;
  late EventRepository events;
  late SessionRepository sessions;
  late PlanRepository plans;
  late AppRepository apps;
  late MetaRepository meta;
  late FixedClock clock;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await openDriftDb(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    source = FakeUsageSource(apps: [
      {'p': video, 'label': 'Video', 'category': 'video'},
      {'p': notes, 'label': 'Notes', 'category': 'productivity'},
    ]);
    events = EventRepository(db);
    sessions = SessionRepository(db);
    plans = PlanRepository(db);
    apps = AppRepository(db);
    meta = MetaRepository(db);
    clock = FixedClock(at(12, 0));
  });

  tearDown(() => db.close());

  Ingestor ingestor({EventRepository? eventRepo}) => Ingestor(
        source: source,
        events: eventRepo ?? events,
        sessions: sessions,
        plans: plans,
        apps: apps,
        meta: meta,
        clock: clock,
        extraIdlePackages: const {'io.github.santhoshunt.drift', 'com.android.systemui'},
        readBufferFile: source.readFile,
      );

  Future<List<Session>> sessionsOn(int dayOfMonth) =>
      sessions.sessionsBetween(DateTime(2026, 10, dayOfMonth), DateTime(2026, 10, dayOfMonth + 1));

  test('buffer files are committed before they are deleted, and a file that '
      'fails to commit or parse is kept', () async {
    const good = '/buffer/1000-2000.jsonl';
    const failing = '/buffer/3000-4000.jsonl';
    const corrupt = '/buffer/5000-6000.jsonl';
    source.bufferFiles.addAll({
      good: jsonl([
        eventMap(at(9, 0), video, 'Main', 'resumed'),
        eventMap(at(9, 30), video, 'Main', 'paused'),
      ]),
      failing: jsonl([eventMap(at(10, 0), chat, 'Main', 'resumed')]),
      corrupt: '${jsonEncode(eventMap(at(11, 0), notes, 'Main', 'resumed'))}\nnot json',
    });
    final repo = FailingEventRepository(db, {2});
    List<RawEvent>? committedAtDelete;
    source.onDeleteBuffer = (paths) async {
      expect(paths, [good]);
      committedAtDelete = await events.between(0, ms(at(23, 0)));
    };

    final result = await ingestor(eventRepo: repo).run();

    expect(committedAtDelete, hasLength(2), reason: 'rows were in the database before the delete');
    expect(source.deletedBuffers, [good]);
    expect(source.bufferFiles.keys, unorderedEquals([failing, corrupt]));
    expect(result.eventsAdded, 2);
    expect((await sessionsOn(19)).map((s) => (s.p, s.start, s.end)), [(video, at(9, 0), at(9, 30))]);

    // The next run with a healthy repository commits the kept good file.
    source.onDeleteBuffer = null;
    final retry = await ingestor().run();
    expect(retry.eventsAdded, 1);
    expect(source.bufferFiles.keys, [corrupt]);
  });

  test('reruns are idempotent and extend the open session with the same id', () async {
    source.events.addAll([
      eventMap(at(9, 0), video, 'Main', 'resumed'),
      eventMap(at(9, 30), video, 'Main', 'paused'),
      eventMap(at(11, 30), notes, 'Main', 'resumed'),
    ]);
    final first = await ingestor().run();
    expect(first.eventsAdded, 3);
    final before = await sessionsOn(19);
    expect(before.map((s) => (s.p, s.end)), [(video, at(9, 30)), (notes, at(12, 0))]);

    final second = await ingestor().run();
    expect(second.eventsAdded, 0);
    expect(second.gapsAdded, 0);
    expect(await sessionsOn(19), before);

    clock.value = at(12, 30);
    await ingestor().run();
    final after = await sessionsOn(19);
    expect(after.last.id, before.last.id);
    expect(after.last.end, at(12, 30));
    expect(await sessions.gapsBetween(at(0, 0, day: 1), at(0, 0, day: 30)), isEmpty);
  });

  test('a gap is recorded when Android\'s earliest event is later than the '
      'cursor, minus the span a buffer file covered', () async {
    final cursor = at(8, 0, day: 17);
    await meta.setInt(Ingestor.cursorKey, ms(cursor));
    source
      ..useEarliestOverride = true
      ..earliestOverride = ms(at(20, 0, day: 17));
    source.bufferFiles['/buffer/${ms(cursor)}-${ms(at(12, 0, day: 17))}.jsonl'] =
        jsonl([eventMap(at(9, 0, day: 17), video, 'Main', 'resumed')]);

    final result = await ingestor().run();
    expect(result.gapsAdded, 1);
    expect(await sessions.gapsBetween(at(0, 0, day: 1), at(0, 0, day: 30)),
        [GapSpan(at(12, 0, day: 17), at(20, 0, day: 17))]);

    final again = await ingestor().run();
    expect(again.gapsAdded, 0);
  });

  test('no gap when Android still holds events from before the cursor', () async {
    await meta.setInt(Ingestor.cursorKey, ms(at(8, 0)));
    source
      ..useEarliestOverride = true
      ..earliestOverride = ms(at(8, 0, day: 12));
    final result = await ingestor().run();
    expect(result.gapsAdded, 0);
    expect(source.queries.single, (ms(at(6, 0)), ms(at(12, 0))), reason: 'cursor minus 2 h to now');
  });

  test('raw events older than 3 local days are pruned after sessions are built', () async {
    await events.insertAll([
      RawEvent(ms(at(10, 0, day: 15)), video, 'Main', EventKind.resumed),
      RawEvent(ms(at(10, 30, day: 15)), video, 'Main', EventKind.paused),
      RawEvent(ms(at(10, 0, day: 16)), notes, 'Main', EventKind.resumed),
      RawEvent(ms(at(10, 30, day: 16)), notes, 'Main', EventKind.paused),
    ]);
    final result = await ingestor().run();
    expect(result.daysRebuilt, 8, reason: 'first run reaches back 7 days');
    final left = await events.between(0, ms(at(23, 0)));
    expect(left.map((e) => e.p).toSet(), {notes});
    expect((await sessionsOn(15)).single.p, video, reason: 'the session outlives its raw events');
  });

  test('yesterday\'s plan is frozen once and later edits do not change it', () async {
    final id = await plans.insertBlock(
      const PlanBlock(name: 'Deep work', startMin: 540, endMin: 660, repeatMask: PlanBlock.everyDay),
    );
    await meta.setInt(Ingestor.cursorKey, ms(at(22, 0, day: 18)));

    await ingestor().run();
    final frozen = await plans.frozenPlan(DateTime(2026, 10, 18));
    expect(frozen, isNotNull);
    expect(await plans.frozenPlan(DateTime(2026, 10, 19)), isNull, reason: 'today has not ended');

    await plans.updateBlock(
      PlanBlock(id: id, name: 'Deep work', startMin: 780, endMin: 900, repeatMask: PlanBlock.everyDay),
    );
    clock.value = at(15, 0);
    await ingestor().run();
    expect(await plans.frozenPlan(DateTime(2026, 10, 18)), frozen);
    expect(
      resolvePlan(DateTime(2026, 10, 18), await plans.allBlocks(), frozenJson: frozen).single.start,
      at(9, 0, day: 18),
    );
  });

  test('a session crossing midnight gets its real end when the day before is rebuilt', () async {
    // The previous ingest at 23:55 stored the video session as open.
    await events.insertAll([RawEvent(ms(at(23, 30, day: 18)), video, 'Main', EventKind.resumed)]);
    await sessions.replaceDay(DateTime(2026, 10, 18), DateTime(2026, 10, 19), [
      Session(p: video, start: at(23, 30, day: 18), end: at(23, 55, day: 18)),
    ], const []);
    final id = (await sessionsOn(18)).single.id;
    await meta.setInt(Ingestor.cursorKey, ms(at(23, 55, day: 18)));
    source.events.add(eventMap(at(0, 30), video, 'Main', 'paused'));
    source
      ..useEarliestOverride = true
      ..earliestOverride = ms(at(0, 0, day: 12));
    clock.value = at(9, 0);

    final result = await ingestor().run();
    expect(result.daysRebuilt, 2);
    final today = await sessionsOn(19);
    expect(today.single.id, id);
    expect(today.single.end, at(0, 30));
  });

  test('a stuck buffer file with events from an already pruned day does not '
      'rebuild that day', () async {
    final oldDay = DateTime(2026, 10, 14);
    await sessions.replaceDay(oldDay, DateTime(2026, 10, 15), [
      Session(p: video, start: at(9, 0, day: 14), end: at(9, 30, day: 14)),
      Session(p: chat, start: at(10, 0, day: 14), end: at(10, 20, day: 14)),
    ], const []);
    final before = await sessionsOn(14);
    await RuleRepository(db).setOverride(before.last.id!, Verdict.offTrack);
    await meta.setInt(Ingestor.cursorKey, ms(at(22, 0, day: 18)));
    source
      ..useEarliestOverride = true
      ..earliestOverride = ms(at(0, 0, day: 12));
    source.bufferFiles['/buffer/stuck.jsonl'] =
        jsonl([eventMap(at(15, 0, day: 14), notes, 'Main', 'resumed')]);

    final result = await ingestor().run();
    expect(result.eventsAdded, 1);
    expect(result.daysRebuilt, 5, reason: '10-15 to 10-19');
    expect(await sessionsOn(14), before);
    expect(await RuleRepository(db).allOverrides(), {before.last.id!: Verdict.offTrack});
  });

  test('launchers reported by homePackages become idle, not sessions', () async {
    source.events.addAll([
      eventMap(at(9, 0), launcher, 'Home', 'resumed'),
      eventMap(at(9, 5), launcher, 'Home', 'paused'),
      eventMap(at(9, 5), video, 'Main', 'resumed'),
      eventMap(at(9, 10), video, 'Main', 'paused'),
    ]);
    await ingestor().run();
    expect((await sessionsOn(19)).map((s) => s.p), [video]);
    expect(await sessions.idleBetween(at(0, 0), at(23, 0)),
        [IdleSpan(at(9, 0), at(9, 5), IdleKind.idleApp)]);
  });

  test('the apps table refreshes at most once a local day', () async {
    await ingestor().run();
    await ingestor().run();
    expect(source.listAppsCalls, 1);
    expect(await apps.categoryMap(), {video: 'video', notes: 'productivity'});

    clock.value = at(8, 0, day: 20);
    await ingestor().run();
    expect(source.listAppsCalls, 2);
  });

  test('the cursor advances to now', () async {
    await ingestor().run();
    expect(await meta.getInt(Ingestor.cursorKey), ms(at(12, 0)));
  });
}
