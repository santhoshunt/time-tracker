import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/services/review_summary.dart';
import 'package:drift_time/services/streak_loader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

final _today = DateTime(2026, 10, 19);

DayPoint _p(int daysBack, int? percent) => DayPoint(
  day: DateTime(_today.year, _today.month, _today.day - daysBack),
  percent: percent,
  plannedMin: percent == null ? 0 : 60,
  fullPlannedMin: 60,
  onMin: 0,
  idleMin: 0,
  offMin: 0,
  noDataMin: 0,
);

void main() {
  group('currentStreak', () {
    test('counts good days back to the first poor one', () {
      expect(currentStreak([_p(4, 90), _p(3, 40), _p(2, 80), _p(1, 75), _p(0, 100)], _today), 3);
    });

    test('days without a score neither add nor break', () {
      expect(currentStreak([_p(3, 90), _p(2, null), _p(1, 80), _p(0, null)], _today), 2);
    });

    test('a weak day still in progress does not break the run', () {
      expect(currentStreak([_p(2, 90), _p(1, 80), _p(0, 30)], _today), 2);
    });

    test('a poor yesterday ends it, and days ahead are ignored', () {
      expect(currentStreak([_p(2, 90), _p(1, 74), _p(0, 100), _p(-1, 100)], _today), 1);
      expect(currentStreak(const [], _today), 0);
    });
  });

  group('loadWeekProgress', () {
    late AppServices s;

    setUp(() async => s = await testServices());
    tearDown(() => s.db.close());

    /// One 09:00 to 10:00 block every day, idle (on track) on each day
    /// listed and YouTube (ruled off) on the poor one.
    Future<void> seed({required int goodDays, required int poorDaysBack}) async {
      await s.apps.upsertAll(sampleApps, testNow);
      await s.plans.insertBlock(const PlanBlock(
        name: 'Focus',
        startMin: 9 * 60,
        endMin: 10 * 60,
        repeatMask: PlanBlock.everyDay,
      ));
      await s.rules.upsertRule('Focus', 'com.example.video', Verdict.offTrack, testNow);
      for (var back = 0; back <= poorDaysBack; back++) {
        final d = DateTime(testNow.year, testNow.month, testNow.day - back);
        final next = DateTime(d.year, d.month, d.day + 1);
        final at9 = DateTime(d.year, d.month, d.day, 9);
        final at10 = DateTime(d.year, d.month, d.day, 10);
        if (back == poorDaysBack) {
          await s.sessions.replaceDay(d, next, [Session(p: 'com.example.video', start: at9, end: at10)], const []);
        } else if (back < goodDays) {
          await s.sessions.replaceDay(d, next, const [], [IdleSpan(at9, at10, IdleKind.screenOff)]);
        }
      }
    }

    test('a run longer than one 28-day chunk is counted whole', () async {
      await seed(goodDays: 41, poorDaysBack: 41);
      final w = await loadWeekProgress(s, testNow, firstWeekday: DateTime.monday);
      expect(w.streak, 41);
      expect(w.week.map((d) => d.day).first, DateTime(2026, 10, 19));
      expect(w.week, hasLength(7));
      expect(w.weekPercent, 100);
      expect(w.hasPlan, isTrue);
    });

    test('a poor day five days back stops the streak at five', () async {
      await seed(goodDays: 5, poorDaysBack: 5);
      final w = await loadWeekProgress(s, testNow, firstWeekday: DateTime.sunday);
      expect(w.streak, 5);
      // Sunday weeks: 18 to 24 October.
      expect(w.week.first.day, DateTime(2026, 10, 18));
    });

    test('nothing planned means no plan and no streak', () async {
      final w = await loadWeekProgress(s, testNow, firstWeekday: DateTime.monday);
      expect(w.hasPlan, isFalse);
      expect(w.streak, 0);
      expect(w.weekPercent, isNull);
    });
  });
}
