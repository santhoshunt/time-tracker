import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/plan_resolver.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/services/period_loader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed_history.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices s;

  setUp(() async => s = await testServices());
  tearDown(() => s.db.close());

  /// Monday 12 to Sunday 18 October 2026, the week before testNow, with
  /// the awkward cases a per-day split could get wrong.
  Future<void> seedWeek() async {
    await seedPlanOnce(s);
    final drifts = [40, 130, 200, 90, 260, 0, 0];
    for (var i = 0; i < 7; i++) {
      await seedDayUse(s, DateTime(2026, 10, 12 + i), drifts[i]);
    }
    // Today's morning too, so the range reaches into today.
    await seedDayUse(s, testNow, 60);

    // A session crossing midnight, Tuesday into Wednesday. It starts on
    // Tuesday, so replaceDay for Tuesday keeps it.
    await s.sessions.replaceDay(
      DateTime(2026, 10, 13),
      DateTime(2026, 10, 14),
      [
        ...(await s.sessions.sessionsBetween(DateTime(2026, 10, 13), DateTime(2026, 10, 14)))
            .where((x) => x.start.day == 13),
        Session(
          p: 'com.example.video',
          start: DateTime(2026, 10, 13, 23, 20),
          end: DateTime(2026, 10, 14, 0, 40),
        ),
      ],
      await s.sessions.idleBetween(DateTime(2026, 10, 13), DateTime(2026, 10, 14)),
    );
    // A gap inside Thursday's Deep work.
    await s.sessions.addGap(GapSpan(DateTime(2026, 10, 15, 9, 50), DateTime(2026, 10, 15, 10, 30)));
    // Wednesday's Instagram answered as on track for that session only.
    final wed = await s.sessions.sessionsBetween(DateTime(2026, 10, 14, 9), DateTime(2026, 10, 14, 12));
    final insta = wed.firstWhere((x) => x.p == 'com.example.social');
    await s.rules.setOverride(insta.id!, Verdict.onTrack);
    // Friday frozen with Deep work only, as if the plan was edited later.
    await s.plans.freezePlan(
      DateTime(2026, 10, 16),
      encodeFrozenPlan([
        const PlanBlock(name: 'Deep work', startMin: 9 * 60, endMin: 12 * 60, repeatMask: PlanBlock.weekdays),
      ]),
    );
  }

  test('matches loadDay for every day of a seeded week, today and two future days', () async {
    await seedWeek();
    final days = await loadDays(s, DateTime(2026, 10, 12), DateTime(2026, 10, 21, 18));
    expect(days, hasLength(10));

    for (final d in days) {
      final one = await loadDay(s, d.day);
      final what = dateKey(d.day);
      expect(d.day, one.day, reason: what);
      expect(d.blocks, one.blocks, reason: what);
      expect(d.segments, one.segments, reason: what);
      expect(d.score, one.score, reason: what);
      expect(d.labels, one.labels, reason: what);
      expect(d.now, one.now, reason: what);
    }

    DayData on(int day) => days.firstWhere((d) => d.day.day == day);
    // The cases the split has to get right really are in the data.
    expect(
      on(14).segments.first,
      isA<Segment>()
          .having((x) => x.p, 'p', 'com.example.video')
          .having((x) => x.end, 'end', DateTime(2026, 10, 14, 0, 40)),
      reason: 'the session from Tuesday night carries into Wednesday',
    );
    expect(on(15).segments.any((x) => x.verdict == Verdict.noData), isTrue);
    expect(
      on(14).segments.any((x) => x.p == 'com.example.social' && x.verdict == Verdict.onTrack),
      isTrue,
    );
    expect(on(16).blocks.map((b) => b.name), ['Deep work']);
    expect(on(19).score, isNotNull, reason: 'today scores what has passed');
    expect(on(20).score, isNull, reason: 'tomorrow has no score');
    expect(on(20).blocks, isNotEmpty, reason: 'but it still has its plan');
    expect(on(21).segments, isEmpty);
  });

  test('a past planned day with nothing stored has no score, in both loaders', () async {
    await seedPlanOnce(s);
    final monday = DateTime(2026, 10, 5);
    final days = await loadDays(s, monday, monday);
    expect(days.single.blocks, isNotEmpty);
    expect(days.single.segments, isEmpty);
    expect(days.single.score, isNull);

    // loadDay is loadDays for one day, so Today shows the same.
    expect((await loadDay(s, monday)).score, isNull);
  });

  test('a day with only an idle span is tracked and scores', () async {
    await seedPlanOnce(s);
    final monday = DateTime(2026, 10, 5);
    await s.sessions.replaceDay(
      monday,
      DateTime(2026, 10, 6),
      const [],
      [IdleSpan(DateTime(2026, 10, 5), DateTime(2026, 10, 5, 7), IdleKind.screenOff)],
    );
    final d = (await loadDays(s, monday, monday)).single;
    expect(d.score?.percent, 100);
    expect(d.segments, (await loadDay(s, monday)).segments);
  });

  test('an empty or reversed range loads nothing', () async {
    expect(await loadDays(s, DateTime(2026, 10, 5), DateTime(2026, 10, 4)), isEmpty);
  });

  test('a whole year comes back one entry per day, oldest first', () async {
    await seedHistory(s);
    final days = await loadDays(s, DateTime(2026, 1, 1), DateTime(2026, 12, 31));
    expect(days, hasLength(365));
    expect(days.first.day, DateTime(2026, 1, 1));
    expect(days.last.day, DateTime(2026, 12, 31));
    for (var i = 1; i < days.length; i++) {
      expect(days[i].day.isAfter(days[i - 1].day), isTrue);
    }
    final scored = days.where((d) => d.score != null).map((d) => d.day).toList();
    expect(scored.first, DateTime(2026, 9, 7), reason: 'tracking starts on 7 September');
    expect(scored.last, DateTime(2026, 10, 19));
  });
}
