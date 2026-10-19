import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/platform/usage_source.dart';
import 'package:drift_time/services/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

DateTime _at(DateTime d, int h, int m) => DateTime(d.year, d.month, d.day, h, m);

Future<void> _sessions(AppServices s, DateTime day, List<Session> list) =>
    s.sessions.replaceDay(
      DateTime(day.year, day.month, day.day),
      DateTime(day.year, day.month, day.day + 1),
      list,
      const [],
    );

void main() {
  late AppServices s;

  setUp(() async => s = await testServices());
  tearDown(() => s.db.close());

  group('loadUsage', () {
    test('sums each app and category, largest first, plan or no plan', () async {
      await seedSampleDay(s, testNow);
      final u = await loadUsage(s, testNow, testNow);
      // Notes 70 + Zoom 20, YouTube 65, Spotify 40, Instagram 25 + WhatsApp 9.
      expect(u.totalMinutes, 229);
      expect([for (final c in u.categories) (c.category, c.minutes)], [
        (AppCategories.productivity, 90),
        (AppCategories.video, 65),
        (AppCategories.audio, 40),
        (AppCategories.social, 34),
      ]);
      final productivity = u.categories.first;
      expect([for (final a in productivity.apps) (a.label, a.minutes)], [
        ('Notes', 70),
        ('Zoom', 20),
      ]);
      expect(u.categories.last.apps.map((a) => a.label), ['Instagram', 'WhatsApp']);
    });

    test('stops at now and at the edges of the period', () async {
      await s.apps.upsertAll(sampleApps, testNow);
      final yesterday = DateTime(2026, 10, 18);
      await _sessions(s, yesterday, [
        // 23:30 to 00:30: half belongs to each day.
        Session(p: 'com.example.video', start: _at(yesterday, 23, 30), end: _at(testNow, 0, 30)),
      ]);
      await _sessions(s, testNow, [
        // Runs past "now" (13:30), which a clock change can leave behind.
        Session(p: 'com.example.social', start: _at(testNow, 13, 0), end: _at(testNow, 14, 0)),
      ]);
      final today = await loadUsage(s, testNow, testNow);
      expect(today.categories.firstWhere((c) => c.category == 'video').minutes, 30);
      expect(today.categories.firstWhere((c) => c.category == 'social').minutes, 30);
      final before = await loadUsage(s, yesterday, yesterday);
      expect(before.totalMinutes, 30);
      final both = await loadUsage(s, yesterday, testNow);
      expect(both.totalMinutes, 90);
    });

    test('leaves out system components and Drift itself', () async {
      await s.apps.upsertAll(sampleApps, testNow);
      await _sessions(s, testNow, [
        Session(p: 'com.example.notes', start: _at(testNow, 9, 0), end: _at(testNow, 9, 10)),
        Session(p: 'com.example.playservices', start: _at(testNow, 9, 10), end: _at(testNow, 9, 40)),
        Session(p: driftPackage, start: _at(testNow, 10, 0), end: _at(testNow, 10, 30)),
      ]);
      final u = await loadUsage(s, testNow, testNow);
      expect(u.totalMinutes, 10);
      expect(u.categories.single.apps.single.label, 'Notes');
    });

    test('before the app list loads, unknown apps count under Other', () async {
      await _sessions(s, testNow, [
        Session(p: 'com.example.mystery', start: _at(testNow, 9, 0), end: _at(testNow, 9, 25)),
        Session(p: driftPackage, start: _at(testNow, 10, 0), end: _at(testNow, 10, 30)),
      ]);
      final u = await loadUsage(s, testNow, testNow);
      final other = u.categories.single;
      expect(other.category, AppCategories.undefined);
      expect(other.apps.single.label, 'com.example.mystery');
      expect(u.totalMinutes, 25);
    });

    test('a day with nothing is empty', () async {
      final u = await loadUsage(s, testNow, testNow);
      expect(u.isEmpty, isTrue);
      expect(u.categories, isEmpty);
      final ahead = await loadUsage(s, DateTime(2026, 10, 25), DateTime(2026, 10, 25));
      expect(ahead.isEmpty, isTrue);
    });
  });

  group('loadAppDetail', () {
    test('seven days, the runs that day and the time per block', () async {
      await seedSampleDay(s, testNow);
      final sat = DateTime(2026, 10, 17);
      await _sessions(s, sat, [
        Session(p: 'com.example.video', start: _at(sat, 20, 0), end: _at(sat, 20, 45)),
      ]);
      final d = await loadAppDetail(s, 'com.example.video', testNow);
      expect(d.label, 'YouTube');
      expect(d.category, AppCategories.video);
      expect(d.dayMinutes, 65);
      expect(d.lastSevenDays.map((x) => x.$1).first, DateTime(2026, 10, 13));
      expect(d.lastSevenDays.map((x) => x.$2), [0, 0, 0, 0, 45, 0, 65]);
      expect(d.daySpans, [
        (_at(testNow, 11, 15), _at(testNow, 11, 50)),
        (_at(testNow, 12, 10), _at(testNow, 12, 40)),
      ]);
      // 11:15 to 11:50 in Deep work, where YouTube is ruled off; 12:10 to
      // 12:40 at Lunch, where any app is fine.
      expect([for (final b in d.byBlock) (b.block, b.minutes, b.offTrack)], [
        ('Deep work', 35, true),
        ('Lunch', 30, false),
      ]);
    });

    test('time outside every block gets its own row, last', () async {
      await seedSampleDay(s, testNow);
      await _sessions(s, testNow, [
        Session(p: 'com.example.video', start: _at(testNow, 6, 0), end: _at(testNow, 6, 20)),
        Session(p: 'com.example.video', start: _at(testNow, 9, 30), end: _at(testNow, 9, 40)),
      ]);
      final d = await loadAppDetail(s, 'com.example.video', testNow);
      expect([for (final b in d.byBlock) (b.block, b.minutes, b.offTrack)], [
        ('Deep work', 10, true),
        (null, 20, false),
      ]);
    });
  });
}
