import 'package:drift_time/domain/models.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/services/review_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

/// A day with one block from 09:00 lasting [plannedMin] and the given
/// score, and [driftApps] as off-track segments inside it.
DayData day(
  DateTime d, {
  int plannedMin = 0,
  int offMin = 0,
  int idleMin = 0,
  int noDataMin = 0,
  int? percent,
  Map<String, int> driftApps = const {},
  String block = 'Deep work',
}) {
  final start = DateTime(d.year, d.month, d.day, 9);
  final blocks = plannedMin == 0
      ? const <ResolvedBlock>[]
      : [ResolvedBlock(name: block, start: start, end: start.add(Duration(minutes: plannedMin)))];
  var t = start;
  final segments = <Segment>[];
  for (final e in driftApps.entries) {
    final end = t.add(Duration(minutes: e.value));
    segments.add(Segment(p: e.key, start: t, end: end, verdict: Verdict.offTrack, blockName: block));
    t = end;
  }
  return DayData(
    day: DateTime(d.year, d.month, d.day),
    blocks: blocks,
    segments: segments,
    score: percent == null
        ? null
        : DayScore(
            plannedMin: plannedMin,
            offMin: offMin,
            idleMin: idleMin,
            noDataMin: noDataMin,
            percent: percent,
          ),
    labels: const {'com.example.video': 'YouTube', 'com.example.social': 'Instagram'},
    now: testNow,
  );
}

void main() {
  group('summarize', () {
    test('weights the score by minutes, not by days', () {
      // A long poor day and a short perfect one: averaging the two days
      // would say 75%, but 600 known minutes with 200 off is 67%.
      final s = summarize([
        day(DateTime(2026, 10, 12), plannedMin: 500, offMin: 200, percent: 60),
        day(DateTime(2026, 10, 13), plannedMin: 100, offMin: 0, percent: 100),
      ]);
      expect(s.plannedMin, 600);
      expect(s.offMin, 200);
      expect(s.percent, 67);
    });

    test('leaves no-data time out of both sides', () {
      final s = summarize([
        day(DateTime(2026, 10, 12), plannedMin: 300, offMin: 50, noDataMin: 100, percent: 75),
      ]);
      expect(s.noDataMin, 100);
      expect(s.percent, 75); // (300 - 100 - 50) / (300 - 100)
    });

    test('is null when nothing known was planned', () {
      expect(summarize(const []).percent, isNull);
      expect(summarize([day(DateTime(2026, 10, 17))]).percent, isNull);
      final allNoData = summarize([
        day(DateTime(2026, 10, 12), plannedMin: 60, noDataMin: 60, percent: null),
      ]);
      expect(allNoData.percent, isNull);
      expect(allNoData.hasPlan, isTrue);
      expect(summarize([day(DateTime(2026, 10, 17))]).hasPlan, isFalse);
    });

    test('lists per-day scores and finds the worst and best day', () {
      final s = summarize([
        day(DateTime(2026, 10, 12), plannedMin: 100, offMin: 20, percent: 80),
        day(DateTime(2026, 10, 13), plannedMin: 100, offMin: 45, percent: 55),
        day(DateTime(2026, 10, 14)),
        day(DateTime(2026, 10, 15), plannedMin: 100, offMin: 45, percent: 55),
        day(DateTime(2026, 10, 16), plannedMin: 100, offMin: 5, percent: 95),
      ]);
      expect(s.dayScores, [80, 55, null, 55, 95]);
      expect(s.worstDay?.day, DateTime(2026, 10, 13), reason: 'earliest on a tie');
      expect(s.bestDay?.day, DateTime(2026, 10, 16));
      expect(summarize([day(DateTime(2026, 10, 17))]).worstDay, isNull);
    });

    test('splits a day into on track, idle and off track for the bars', () {
      final s = summarize([
        day(DateTime(2026, 10, 12), plannedMin: 180, offMin: 30, idleMin: 50, noDataMin: 10, percent: 82),
      ]);
      final p = s.days.single;
      expect(p.fullPlannedMin, 180);
      expect(p.onMin, 90);
      expect(p.idleMin, 50);
      expect(p.offMin, 30);
      expect(p.noDataMin, 10);
    });

    test('sums drift apps and drift by block across days, largest first', () {
      final s = summarize([
        day(
          DateTime(2026, 10, 12),
          plannedMin: 180,
          offMin: 40,
          percent: 78,
          driftApps: {'com.example.video': 25, 'com.example.social': 15},
        ),
        day(
          DateTime(2026, 10, 13),
          plannedMin: 180,
          offMin: 20,
          percent: 89,
          driftApps: {'com.example.social': 20},
          block: 'Family',
        ),
      ]);
      expect(s.topDrift, [('com.example.social', 35), ('com.example.video', 25)]);
      expect(s.labelOf('com.example.social'), 'Instagram');
      expect(s.driftByBlock, [('Deep work', 40), ('Family', 20)]);
    });

    test('counts the best streak at 75% or more, skipping unscored days', () {
      DayData scored(int d, int pct) =>
          day(DateTime(2026, 10, d), plannedMin: 100, offMin: 100 - pct, percent: pct);
      final s = summarize([
        scored(1, 80),
        scored(2, 75),
        scored(3, 74), // breaks it
        scored(4, 90),
        scored(5, 76),
        day(DateTime(2026, 10, 6)), // weekend: neither breaks nor counts
        day(DateTime(2026, 10, 7)),
        scored(8, 88),
        scored(9, 59), // breaks it
        scored(10, 100),
      ]);
      expect(s.bestStreak, 3);
      expect(summarize([scored(1, 70), scored(2, 60)]).bestStreak, 0);
    });
  });

  group('deltaPercent', () {
    test('is the difference, or null when either side has no score', () {
      final a = summarize([day(DateTime(2026, 10, 12), plannedMin: 100, offMin: 20, percent: 80)]);
      final b = summarize([day(DateTime(2026, 10, 5), plannedMin: 100, offMin: 26, percent: 74)]);
      final none = summarize(const []);
      expect(deltaPercent(a, b), 6);
      expect(deltaPercent(b, a), -6);
      expect(deltaPercent(a, a), 0);
      expect(deltaPercent(a, none), isNull);
      expect(deltaPercent(none, a), isNull);
    });
  });

  group('buckets', () {
    test('split at 75 and 60', () {
      expect(bucketOf(null), ScoreBucket.none);
      expect(bucketOf(100), ScoreBucket.good);
      expect(bucketOf(75), ScoreBucket.good);
      expect(bucketOf(74), ScoreBucket.fair);
      expect(bucketOf(60), ScoreBucket.fair);
      expect(bucketOf(59), ScoreBucket.poor);
      expect(bucketOf(0), ScoreBucket.poor);
    });
  });

  group('periods', () {
    test('a Monday week across a month edge', () {
      final w = weekOf(DateTime(2026, 10, 1, 15, 30));
      expect(w.start, DateTime(2026, 9, 28));
      expect(w.end, DateTime(2026, 10, 4));
      expect(daysIn(w), 7);
    });

    test('a week starting on Sunday or Saturday', () {
      final sun = weekOf(DateTime(2026, 10, 19), firstWeekday: DateTime.sunday);
      expect(sun.start, DateTime(2026, 10, 18));
      expect(sun.end, DateTime(2026, 10, 24));
      final sat = weekOf(DateTime(2026, 10, 17), firstWeekday: DateTime.saturday);
      expect(sat.start, DateTime(2026, 10, 17));
      expect(weekOf(DateTime(2026, 10, 18)).start, DateTime(2026, 10, 12),
          reason: 'Sunday ends a Monday week');
    });

    test('a week across a year edge', () {
      final w = weekOf(DateTime(2027, 1, 1));
      expect(w.start, DateTime(2026, 12, 28));
      expect(w.end, DateTime(2027, 1, 3));
    });

    test('February in the leap year 2028 has 29 days', () {
      final feb = monthOf(DateTime(2028, 2, 10));
      expect(feb.start, DateTime(2028, 2, 1));
      expect(feb.end, DateTime(2028, 2, 29));
      expect(daysIn(feb), 29);
      expect(daysIn(monthOf(DateTime(2027, 2, 10))), 28);
      expect(daysIn(yearOf(DateTime(2028, 6, 1))), 366);
    });

    test('a month step from 31 January lands in February', () {
      final next = stepPeriod(ReviewPeriod.month, DateTime(2026, 1, 31), 1);
      expect(next, DateTime(2026, 2, 1));
      expect(monthOf(next).end, DateTime(2026, 2, 28));
      expect(stepPeriod(ReviewPeriod.month, DateTime(2026, 3, 31), -1), DateTime(2026, 2, 1));
      expect(stepPeriod(ReviewPeriod.month, DateTime(2026, 1, 15), -1), DateTime(2025, 12, 1));
      expect(stepPeriod(ReviewPeriod.month, DateTime(2026, 11, 30), 14), DateTime(2028, 1, 1));
    });

    test('year, week and day steps', () {
      expect(stepPeriod(ReviewPeriod.year, DateTime(2028, 2, 29), 1), DateTime(2029, 1, 1));
      expect(stepPeriod(ReviewPeriod.year, DateTime(2026, 10, 19), -2), DateTime(2024, 1, 1));
      expect(stepPeriod(ReviewPeriod.week, DateTime(2026, 10, 21), -1), DateTime(2026, 10, 12));
      expect(stepPeriod(ReviewPeriod.week, DateTime(2026, 10, 21), 2), DateTime(2026, 11, 2));
      expect(
        stepPeriod(ReviewPeriod.week, DateTime(2026, 10, 21), 0, firstWeekday: DateTime.sunday),
        DateTime(2026, 10, 18),
      );
      expect(stepPeriod(ReviewPeriod.day, DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });

    test('periodsBetween counts back to today', () {
      final today = DateTime(2026, 10, 19);
      expect(periodsBetween(ReviewPeriod.day, DateTime(2026, 10, 18, 23), today), 1);
      expect(periodsBetween(ReviewPeriod.day, DateTime(2025, 10, 19), today), 365);
      expect(periodsBetween(ReviewPeriod.week, DateTime(2026, 10, 18), today), 1);
      expect(periodsBetween(ReviewPeriod.week, DateTime(2026, 10, 25), today), 0);
      expect(periodsBetween(ReviewPeriod.month, DateTime(2025, 12, 31), today), 10);
      expect(periodsBetween(ReviewPeriod.year, DateTime(2024, 6, 1), today), 2);
    });

    test('periodOf picks the right range for each period', () {
      final t = DateTime(2026, 10, 19, 13, 30);
      expect(periodOf(ReviewPeriod.day, t).start, DateTime(2026, 10, 19));
      expect(periodOf(ReviewPeriod.day, t).end, DateTime(2026, 10, 19));
      expect(periodOf(ReviewPeriod.week, t).end, DateTime(2026, 10, 25));
      expect(periodOf(ReviewPeriod.month, t).end, DateTime(2026, 10, 31));
      expect(periodOf(ReviewPeriod.year, t).start, DateTime(2026, 1, 1));
    });
  });

  test('summarizeByMonth groups days by calendar month', () {
    final months = summarizeByMonth([
      day(DateTime(2026, 9, 30), plannedMin: 100, offMin: 50, percent: 50),
      day(DateTime(2026, 10, 1), plannedMin: 100, offMin: 10, percent: 90),
      day(DateTime(2026, 10, 2), plannedMin: 100, offMin: 30, percent: 70),
    ]);
    expect(months.map((m) => m.$1), [DateTime(2026, 9), DateTime(2026, 10)]);
    expect(months.map((m) => m.$2.percent), [50, 80]);
  });
}
