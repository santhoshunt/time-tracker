import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/system_apps.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  final t = DateTime(2026, 10, 19, 10);

  test('apps without a home-screen icon become idle time with the same span', () {
    final idle = <IdleSpan>[];
    final kept = withoutSystemApps(
      [
        Session(p: 'com.example.notes', start: t, end: t.add(const Duration(minutes: 5))),
        Session(p: 'com.google.android.gms', start: t.add(const Duration(minutes: 5)), end: t.add(const Duration(minutes: 6))),
      ],
      {'com.example.notes'},
      idle,
    );
    expect(kept.map((s) => s.p), ['com.example.notes']);
    expect(idle, [
      IdleSpan(t.add(const Duration(minutes: 5)), t.add(const Duration(minutes: 6)), IdleKind.idleApp),
    ]);
  });

  test('an empty app list changes nothing, so a new install hides no real use', () {
    final idle = <IdleSpan>[];
    final sessions = [Session(p: 'com.google.android.gms', start: t, end: t.add(const Duration(minutes: 3)))];
    expect(withoutSystemApps(sessions, const {}, idle), sessions);
    expect(idle, isEmpty);
  });

  group('on a classified day', () {
    test('Google Play services inside a block is idle and never asked about', () async {
      final s = await testServices();
      await seedSampleDay(s, testNow);
      await s.sessions.replaceDay(
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 20),
        [
          ...await s.sessions.sessionsBetween(DateTime(2026, 10, 19), DateTime(2026, 10, 20)),
          Session(p: 'com.google.android.gms', start: DateTime(2026, 10, 19, 9, 36), end: DateTime(2026, 10, 19, 9, 39)),
        ],
        await s.sessions.idleBetween(DateTime(2026, 10, 19), DateTime(2026, 10, 20)),
      );
      final day = await loadDay(s, testNow);
      expect(day.segments.where((x) => x.p == 'com.google.android.gms'), isEmpty);
      final at = day.segments.firstWhere(
        (x) => !x.start.isAfter(DateTime(2026, 10, 19, 9, 37)) && x.end.isAfter(DateTime(2026, 10, 19, 9, 37)),
      );
      expect(at.verdict, Verdict.idle);
      expect(day.unanswered.map((x) => x.p), isNot(contains('com.google.android.gms')));
      await s.db.close();
    });

    test('a guessed app used under a minute is not asked about; a minute is', () async {
      final s = await testServices();
      await seedSampleDay(s, testNow);
      final d0 = DateTime(2026, 10, 19);
      final d1 = DateTime(2026, 10, 20);
      final base = await s.sessions.sessionsBetween(d0, d1);
      final idle = await s.sessions.idleBetween(d0, d1);
      // A maps app (guessed on) for 30 seconds in Deep work.
      await s.apps.upsertAll(const [AppInfo(p: 'com.example.maps', label: 'Maps', category: 'maps')], d0);
      await s.sessions.replaceDay(d0, d1, [
        ...base,
        Session(p: 'com.example.maps', start: DateTime(2026, 10, 19, 11, 12), end: DateTime(2026, 10, 19, 11, 12, 30)),
      ], idle);
      expect((await loadDay(s, testNow)).unanswered.map((x) => x.p), isNot(contains('com.example.maps')));

      await s.sessions.replaceDay(d0, d1, [
        ...base,
        Session(p: 'com.example.maps', start: DateTime(2026, 10, 19, 11, 12), end: DateTime(2026, 10, 19, 11, 13)),
      ], idle);
      expect((await loadDay(s, testNow)).unanswered.map((x) => x.p), contains('com.example.maps'));
      await s.db.close();
    });
  });
}
