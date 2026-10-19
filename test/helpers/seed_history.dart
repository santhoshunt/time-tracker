import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';

import 'seed.dart';
import 'test_app.dart';

/// Inserts the sample apps, the sample weekday plan and the Deep work and
/// Meetings rules once. Call before [seedDayUse].
Future<void> seedPlanOnce(AppServices s) async {
  await s.apps.upsertAll(sampleApps, testNow);
  for (final b in samplePlan) {
    await s.plans.insertBlock(b);
  }
  await s.rules.upsertRule('Deep work', 'com.example.notes', Verdict.onTrack, testNow);
  await s.rules.upsertRule('Deep work', 'com.example.video', Verdict.offTrack, testNow);
  await s.rules.upsertRule('Deep work', 'com.example.social', Verdict.offTrack, testNow);
  await s.rules.upsertRule('Meetings', 'com.example.meet', Verdict.onTrack, testNow);
}

/// Stores one day of made-up app use against the sample plan, with about
/// [driftMin] minutes off track inside blocks. Weekends get only some
/// unplanned evening video. Nothing is stored after [now].
///
/// Off-track time goes, in order, to Instagram then YouTube in Deep work
/// (both learned as off track there), a little WhatsApp in Meetings
/// (guessed off), then YouTube and Instagram in Family (guessed off).
/// [light] leaves out the on-track sessions.
Future<void> seedDayUse(
  AppServices s,
  DateTime day,
  int driftMin, {
  bool light = false,
  DateTime? now,
}) async {
  final d = DateTime(day.year, day.month, day.day);
  final end = DateTime(d.year, d.month, d.day + 1);
  final cutoff = now ?? testNow;
  DateTime at(int h, int m) => DateTime(d.year, d.month, d.day, h, m);
  DateTime plus(DateTime t, int m) => t.add(Duration(minutes: m));

  final sessions = <Session>[];
  final idle = <IdleSpan>[
    IdleSpan(at(0, 0), at(7, 0), IdleKind.screenOff),
    IdleSpan(at(22, 30), end, IdleKind.screenOff),
  ];
  final weekend = d.weekday >= DateTime.saturday;
  if (weekend) {
    sessions.add(Session(p: 'com.example.video', start: at(16, 0), end: at(16, 45)));
  } else {
    var left = driftMin;
    int take(int max) {
      final m = left < max ? left : max;
      left -= m;
      return m;
    }

    if (!light) {
      sessions.add(Session(p: 'com.example.music', start: at(8, 10), end: at(8, 50)));
      sessions.add(Session(p: 'com.example.notes', start: at(9, 5), end: at(9, 35)));
    }
    final insta = take(60);
    if (insta > 0) {
      sessions.add(Session(p: 'com.example.social', start: at(9, 40), end: plus(at(9, 40), insta)));
    }
    final video = take(75);
    if (video > 0) {
      sessions.add(Session(p: 'com.example.video', start: at(10, 45), end: plus(at(10, 45), video)));
    }
    if (!light) {
      sessions.add(Session(p: 'com.example.video', start: at(12, 10), end: at(12, 40)));
      sessions.add(Session(p: 'com.example.meet', start: at(13, 2), end: at(13, 25)));
    }
    final chat = take(left > 40 ? 15 : 5);
    if (chat > 0) {
      sessions.add(Session(p: 'com.example.chat', start: at(13, 35), end: plus(at(13, 35), chat)));
    }
    final evening = take(120);
    if (evening > 0) {
      sessions.add(Session(p: 'com.example.video', start: at(18, 20), end: plus(at(18, 20), evening)));
    }
    final late = take(30);
    if (late > 0) {
      sessions.add(Session(p: 'com.example.social', start: at(20, 25), end: plus(at(20, 25), late)));
    }
  }

  Session clipS(Session x) => x.end.isAfter(cutoff) ? x.copyWith(end: cutoff) : x;
  IdleSpan clipI(IdleSpan x) =>
      x.end.isAfter(cutoff) ? IdleSpan(x.start, cutoff, x.kind) : x;
  await s.sessions.replaceDay(
    d,
    end,
    [for (final x in sessions) if (x.start.isBefore(cutoff)) clipS(x)],
    [for (final x in idle) if (x.start.isBefore(cutoff)) clipI(x)],
  );
}

/// Several weeks of realistic made-up history for the Review screens:
/// - every day from Monday 7 September 2026 to [testNow] (today stops at
///   13:30), with drift that puts days in all three score buckets;
/// - September and October 2025, lightly, so the year and the previous
///   month have something to compare with.
///
/// Drift per day comes from a fixed pseudo-random sequence, so every run
/// stores the same data.
Future<void> seedHistory(AppServices s) async {
  await seedPlanOnce(s);
  var state = 20261019;
  double next() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x7fffffff;
  }

  int drift(double mean) => (mean * (0.3 + 2.0 * next())).round();

  for (var i = 0; ; i++) {
    final d = DateTime(2026, 9, 7 + i);
    if (d.isAfter(testNow)) break;
    final mean = d.month == 9 ? 150.0 : 100.0;
    await seedDayUse(s, d, drift(mean));
  }
  for (var i = 0; ; i++) {
    final d = DateTime(2025, 9, 1 + i);
    if (d.month > 10) break;
    final mean = d.month == 9 ? 190.0 : 150.0;
    await seedDayUse(s, d, drift(mean), light: true);
  }
}
