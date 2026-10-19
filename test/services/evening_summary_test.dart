import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/services/evening_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_background_channels.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// Monday 19 October 2026, 21:45: past the default 21:30 summary time.
final evening = DateTime(2026, 10, 19, 21, 45);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppServices s;
  late SettingsProvider settings;
  late FakeBackgroundChannels channels;

  setUp(() async {
    s = await testServices(now: evening);
    settings = await testSettings();
    channels = FakeBackgroundChannels();
  });

  tearDown(() async {
    channels.dispose();
    await s.db.close();
  });

  FixedClock clock() => s.clock as FixedClock;

  group('buildSummary', () {
    test('a title with the score and one line per block that started', () async {
      await seedSampleDay(s, evening);
      final day = await loadDay(s, evening);
      final summary = buildSummary(day)!;

      expect(day.score!.offMin, 69);
      expect(summary.title, 'Today: ${day.score!.percent}% on track, 1 h 9 min drift');
      expect(summary.lines, [
        'Gym: no drift',
        'Deep work: 1 h 9 min drift',
        'Lunch: no drift',
        'Meetings: no drift',
        'Family: no drift',
      ]);
    });

    test('the lines add up to the drift in the title', () async {
      await seedSampleDay(s, evening);
      final day = await loadDay(s, evening);
      final summary = buildSummary(day)!;
      int minutesIn(String line) {
        final m = RegExp(r'(?:(\d+) h)? ?(?:(\d+) min)? drift$').firstMatch(line)!;
        return int.parse(m.group(1) ?? '0') * 60 + int.parse(m.group(2) ?? '0');
      }

      final total = summary.lines.map(minutesIn).fold(0, (a, b) => a + b);
      expect(total, day.score!.offMin);
    });

    test('blocks that have not started yet are left out', () async {
      await seedSampleDay(s, evening);
      clock().value = DateTime(2026, 10, 19, 13, 30);
      final day = await loadDay(s, clock().value);
      final names = buildSummary(day)!.lines.map((l) => l.split(':').first);
      expect(names, ['Gym', 'Deep work', 'Lunch', 'Meetings']);
    });

    test('null when nothing was planned', () async {
      final day = await loadDay(s, evening);
      expect(day.blocks, isEmpty);
      expect(buildSummary(day), isNull);
    });

    test('a day with no drift says so in the title', () {
      final d = DateTime(2026, 10, 19);
      final day = DayData(
        day: d,
        blocks: [ResolvedBlock(name: 'Read', start: d.add(const Duration(hours: 9)), end: d.add(const Duration(hours: 10)))],
        segments: [
          Segment(
            p: 'com.example.notes',
            start: d.add(const Duration(hours: 9)),
            end: d.add(const Duration(hours: 10)),
            verdict: Verdict.onTrack,
            blockName: 'Read',
          ),
        ],
        score: const DayScore(plannedMin: 60, offMin: 0, idleMin: 0, noDataMin: 0, percent: 100),
        labels: const {},
        now: evening,
      );
      final summary = buildSummary(day)!;
      expect(summary.title, 'Today: 100% on track, no drift');
      expect(summary.lines, ['Read: no drift']);
    });

    test('more than five blocks keeps the five that drifted most, in plan order', () {
      final d = DateTime(2026, 10, 19);
      DateTime at(int h) => d.add(Duration(hours: h));
      final blocks = [
        for (var i = 0; i < 7; i++) ResolvedBlock(name: 'B$i', start: at(8 + i), end: at(9 + i)),
      ];
      // B0 and B3 drift nothing; the rest drift 10, 20, ... minutes.
      final segments = [
        for (var i = 0; i < 7; i++)
          if (i != 0 && i != 3)
            Segment(
              p: 'com.example.video',
              start: at(8 + i),
              end: at(8 + i).add(Duration(minutes: 10 * i)),
              verdict: Verdict.offTrack,
              blockName: 'B$i',
            ),
      ];
      final day = DayData(
        day: d,
        blocks: blocks,
        segments: segments,
        score: const DayScore(plannedMin: 420, offMin: 180, idleMin: 0, noDataMin: 0, percent: 57),
        labels: const {},
        now: evening,
      );
      expect(buildSummary(day)!.lines, [
        'B1: 10 min drift',
        'B2: 20 min drift',
        'B4: 40 min drift',
        'B5: 50 min drift',
        'B6: 1 h drift',
      ]);
    });
  });

  group('nextSummaryTime', () {
    test('today when the time is still ahead', () {
      expect(nextSummaryTime(DateTime(2026, 10, 19, 13, 30), 1290), DateTime(2026, 10, 19, 21, 30));
    });

    test('tomorrow once it has passed, or at the minute itself', () {
      expect(nextSummaryTime(DateTime(2026, 10, 19, 21, 45), 1290), DateTime(2026, 10, 20, 21, 30));
      expect(nextSummaryTime(DateTime(2026, 10, 19, 21, 30), 1290), DateTime(2026, 10, 20, 21, 30));
    });

    test('across a month and a year end', () {
      expect(nextSummaryTime(DateTime(2026, 10, 31, 23, 0), 1290), DateTime(2026, 11, 1, 21, 30));
      expect(nextSummaryTime(DateTime(2026, 12, 31, 22, 0), 60), DateTime(2027, 1, 1, 1, 0));
    });

    test('keeps the wall-clock minute on a daylight saving day', () {
      // 29 March 2026 is the EU change; whatever zone the test runs in,
      // the result is built from calendar fields, so it reads 21:30.
      final next = nextSummaryTime(DateTime(2026, 3, 28, 22, 0), 1290);
      expect((next.year, next.month, next.day, next.hour, next.minute), (2026, 3, 29, 21, 30));
      final back = nextSummaryTime(DateTime(2026, 10, 24, 22, 0), 1290);
      expect((back.year, back.month, back.day, back.hour, back.minute), (2026, 10, 25, 21, 30));
    });
  });

  group('payload', () {
    test('review payload names the day and reads back', () {
      final payload = summaryPayload(DateTime(2026, 10, 19));
      expect(payload, 'review:2026-10-19');
      expect(reviewDayOf(payload), DateTime(2026, 10, 19));
    });

    test('anything else is not a review day', () {
      expect(reviewDayOf(null), isNull);
      expect(reviewDayOf('open'), isNull);
      expect(reviewDayOf('review:yesterday'), isNull);
    });
  });

  group('maybePostSummary', () {
    test('posts once per day, with the review payload', () async {
      await seedSampleDay(s, evening);
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isTrue);
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isFalse);

      final posts = channels.of('postSummary');
      expect(posts, hasLength(1));
      final args = posts.single.arguments as Map;
      expect(args['title'], startsWith('Today: '));
      expect(args['lines'], contains('Deep work: 1 h 9 min drift'));
      expect(args['payload'], 'review:2026-10-19');
      expect(await s.meta.getInt(summarySentDayKey), 20261019);
    });

    test('posts again the next evening', () async {
      await seedSampleDay(s, evening);
      await maybePostSummary(s, settings, bridge: channels.bridge);
      clock().value = DateTime(2026, 10, 20, 22, 0);
      // Tuesday has the plan but no tracked use yet; give it some.
      await s.sessions.replaceDay(
        DateTime(2026, 10, 20),
        DateTime(2026, 10, 21),
        [Session(p: 'com.example.video', start: DateTime(2026, 10, 20, 9, 0), end: DateTime(2026, 10, 20, 9, 20))],
        const [],
      );
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isTrue);
      expect(channels.of('postSummary'), hasLength(2));
      expect((channels.of('postSummary').last.arguments as Map)['payload'], 'review:2026-10-20');
    });

    test('waits for the summary minute', () async {
      await seedSampleDay(s, evening);
      clock().value = DateTime(2026, 10, 19, 21, 29);
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isFalse);
      await settings.setSummaryMinute(20 * 60);
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isTrue);
    });

    test('a run after midnight skips the missed evening', () async {
      await seedSampleDay(s, evening);
      clock().value = DateTime(2026, 10, 20, 0, 30);
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isFalse);
      expect(channels.of('postSummary'), isEmpty);
    });

    test('nothing when switched off', () async {
      await seedSampleDay(s, evening);
      await settings.setSummaryEnabled(false);
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isFalse);
      expect(channels.of('postSummary'), isEmpty);
    });

    test('nothing without a plan', () async {
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isFalse);
      expect(channels.of('postSummary'), isEmpty);
    });

    test('a summary Android did not show is tried again', () async {
      await seedSampleDay(s, evening);
      channels.postResult = false;
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isFalse);
      expect(await s.meta.getInt(summarySentDayKey), isNull);
      channels.postResult = true;
      expect(await maybePostSummary(s, settings, bridge: channels.bridge), isTrue);
      expect(channels.of('postSummary'), hasLength(2));
    });
  });

  group('bookNextSummary', () {
    test('books the next summary minute', () async {
      clock().value = DateTime(2026, 10, 19, 10, 0);
      await bookNextSummary(s, settings, bridge: channels.bridge);
      final call = channels.of('scheduleSummary').single;
      expect((call.arguments as Map)['epochMs'], DateTime(2026, 10, 19, 21, 30).millisecondsSinceEpoch);
    });

    test('cancels when switched off', () async {
      await settings.setSummaryEnabled(false);
      await bookNextSummary(s, settings, bridge: channels.bridge);
      expect(channels.of('cancelSummary'), hasLength(1));
      expect(channels.of('scheduleSummary'), isEmpty);
    });

    test('a failing native side is only logged', () async {
      channels.failing.add('scheduleSummary');
      await bookNextSummary(s, settings, bridge: channels.bridge);
      expect(channels.of('scheduleSummary'), hasLength(1));
    });
  });
}
