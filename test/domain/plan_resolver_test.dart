import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/plan_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-19 is a Monday.
final monday = DateTime(2026, 10, 19);

DateTime on(DateTime day, int h, int m) => DateTime(day.year, day.month, day.day, h, m);

void main() {
  test('the fixture week starts on a Monday', () {
    expect(monday.weekday, DateTime.monday);
  });

  test('repeat masks: each weekday bit applies on that weekday only', () {
    for (var bit = 0; bit < 7; bit++) {
      final block = PlanBlock(id: bit, name: 'Bit $bit', startMin: 540, endMin: 600, repeatMask: 1 << bit);
      for (var offset = 0; offset < 7; offset++) {
        final day = DateTime(2026, 10, 19 + offset);
        final resolved = resolvePlan(day, [block]);
        if (day.weekday - 1 == bit) {
          expect(resolved, [ResolvedBlock(name: 'Bit $bit', start: on(day, 9, 0), end: on(day, 10, 0))],
              reason: 'bit $bit on ${dateKey(day)}');
        } else {
          expect(resolved, isEmpty, reason: 'bit $bit on ${dateKey(day)}');
        }
      }
    }
  });

  test('weekday and every-day masks', () {
    final weekdays = PlanBlock(name: 'Work', startMin: 540, endMin: 1020, repeatMask: PlanBlock.weekdays);
    final daily = PlanBlock(name: 'Sleep', startMin: 0, endMin: 420, repeatMask: PlanBlock.everyDay);
    final saturday = DateTime(2026, 10, 24);
    expect(resolvePlan(monday, [weekdays, daily]).map((b) => b.name), ['Sleep', 'Work']);
    expect(resolvePlan(saturday, [weekdays, daily]).map((b) => b.name), ['Sleep']);
  });

  test('a one-off block applies only on its date', () {
    final block = PlanBlock(name: 'Dentist', startMin: 900, endMin: 960, date: '2026-10-20');
    expect(resolvePlan(monday, [block]), isEmpty);
    expect(resolvePlan(DateTime(2026, 10, 20), [block]),
        [ResolvedBlock(name: 'Dentist', start: DateTime(2026, 10, 20, 15), end: DateTime(2026, 10, 20, 16))]);
  });

  test('skip dates remove a repeating block for that day only', () {
    final block = PlanBlock(
      name: 'Deep work',
      startMin: 540,
      endMin: 660,
      repeatMask: PlanBlock.everyDay,
      skipDates: const ['2026-10-19'],
    );
    expect(resolvePlan(monday, [block]), isEmpty);
    expect(resolvePlan(DateTime(2026, 10, 20), [block]), hasLength(1));
  });

  test('a frozen plan wins over the live blocks', () {
    final live = [PlanBlock(name: 'Gym', startMin: 1080, endMin: 1140, repeatMask: PlanBlock.everyDay)];
    final frozen = encodeFrozenPlan([
      const PlanBlock(name: 'Deep work', startMin: 540, endMin: 660, repeatMask: PlanBlock.everyDay, anyApp: true, colorIdx: 3),
    ]);
    expect(resolvePlan(monday, live, frozenJson: frozen), [
      ResolvedBlock(name: 'Deep work', start: on(monday, 9, 0), end: on(monday, 11, 0), anyApp: true, colorIdx: 3),
    ]);
  });

  test('a frozen empty plan stays empty even when live blocks exist', () {
    final live = [PlanBlock(name: 'Gym', startMin: 1080, endMin: 1140, repeatMask: PlanBlock.everyDay)];
    expect(resolvePlan(monday, live, frozenJson: '[]'), isEmpty);
  });

  test('a malformed frozen plan falls back to the live blocks', () {
    final live = [PlanBlock(name: 'Gym', startMin: 1080, endMin: 1140, repeatMask: PlanBlock.everyDay)];
    expect(resolvePlan(monday, live, frozenJson: '{not json').map((b) => b.name), ['Gym']);
    expect(resolvePlan(monday, live, frozenJson: '{"a": 1}').map((b) => b.name), ['Gym']);
  });

  test('overlapping blocks are both kept, sorted by start', () {
    final blocks = [
      PlanBlock(name: 'Calls', startMin: 600, endMin: 660, repeatMask: PlanBlock.everyDay),
      PlanBlock(name: 'Deep work', startMin: 540, endMin: 720, repeatMask: PlanBlock.everyDay),
    ];
    expect(resolvePlan(monday, blocks), [
      ResolvedBlock(name: 'Deep work', start: on(monday, 9, 0), end: on(monday, 12, 0)),
      ResolvedBlock(name: 'Calls', start: on(monday, 10, 0), end: on(monday, 11, 0)),
    ]);
  });

  test('a block ending at 24:00 ends at the next midnight', () {
    final block = PlanBlock(name: 'Wind down', startMin: 1320, endMin: 1440, repeatMask: PlanBlock.everyDay);
    expect(resolvePlan(monday, [block]),
        [ResolvedBlock(name: 'Wind down', start: on(monday, 22, 0), end: DateTime(2026, 10, 20))]);
  });

  test('blocks that end at or before their start are skipped', () {
    final blocks = [
      PlanBlock(name: 'Empty', startMin: 600, endMin: 600, repeatMask: PlanBlock.everyDay),
      PlanBlock(name: 'Backwards', startMin: 700, endMin: 600, repeatMask: PlanBlock.everyDay),
    ];
    expect(resolvePlan(monday, blocks), isEmpty);
  });

  test('PlanBlock JSON round trip', () {
    const block = PlanBlock(
      id: 7,
      name: 'Deep work',
      startMin: 540,
      endMin: 660,
      colorIdx: 2,
      repeatMask: PlanBlock.weekdays,
      skipDates: ['2026-10-21'],
      anyApp: true,
    );
    expect(PlanBlock.fromJson(block.toJson()), block);
    expect(decodeFrozenPlan(encodeFrozenPlan([block])), [block]);
  });

  test('blockKey trims and lower-cases', () {
    expect(blockKey('  Deep Work '), 'deep work');
  });

  // The test machine runs in IST, which has no daylight-saving changes, so
  // DateTime(y, m, d) can never produce a 23- or 25-hour day here. These
  // cases drive the pure placeBlocks with hand-built UTC frames that model
  // the two kinds of change, which is the same code path DayFrame.local
  // feeds on a phone in a zone that has them.
  group('daylight-saving days through hand-built frames', () {
    final start = DateTime.utc(2026, 3, 29);

    // Clocks jump from 02:00 to 03:00: wall minutes from 120 on are one
    // hour closer to midnight in real time.
    final short = DayFrame(
      start: start,
      end: start.add(const Duration(hours: 23)),
      wallClock: (m) => start.add(Duration(minutes: m < 120 ? m : m - 60)),
    );

    // Clocks fall back from 03:00 to 02:00: wall minutes from 180 on are
    // one hour further from midnight in real time.
    final long = DayFrame(
      start: start,
      end: start.add(const Duration(hours: 25)),
      wallClock: (m) => start.add(Duration(minutes: m < 180 ? m : m + 60)),
    );

    final allDay = PlanBlock(name: 'All day', startMin: 0, endMin: 1440, repeatMask: PlanBlock.everyDay);
    final night = PlanBlock(name: 'Night', startMin: 60, endMin: 240, repeatMask: PlanBlock.everyDay);

    test('a 23-hour day: an all-day block is 23 hours and a block over the '
        'jump loses the missing hour', () {
      final placed = placeBlocks([allDay, night], short);
      expect(placed[0].end.difference(placed[0].start), const Duration(hours: 23));
      expect(placed[1].end.difference(placed[1].start), const Duration(hours: 2));
    });

    test('a 25-hour day: an all-day block is 25 hours and a block over the '
        'repeat gains an hour', () {
      final placed = placeBlocks([allDay, night], long);
      expect(placed[0].end.difference(placed[0].start), const Duration(hours: 25));
      expect(placed[1].end.difference(placed[1].start), const Duration(hours: 4));
    });

    test('the local frame of an IST day is 24 hours', () {
      final frame = DayFrame.local(monday);
      expect(frame.end.difference(frame.start), const Duration(hours: 24));
      expect(frame.at(1440), DateTime(2026, 10, 20));
    });
  });
}
