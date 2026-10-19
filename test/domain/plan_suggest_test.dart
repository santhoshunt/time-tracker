import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/plan_resolver.dart';
import 'package:drift_time/domain/plan_suggest.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tuesday 27 October 2026; the same weekday before it falls on 20, 13
/// and 6 October and 29 September.
final _date = DateTime(2026, 10, 27);

PlanBlock _on(String date, String name, int startH, int endH, {int color = 0, bool anyApp = false}) =>
    PlanBlock(
      name: name,
      startMin: startH * 60,
      endMin: endH * 60,
      date: date,
      colorIdx: color,
      anyApp: anyApp,
    );

List<(String, int, int)> _slots(List<PlanBlock> blocks) => [
  for (final b in blocks) (b.name, b.startMin ~/ 60, b.endMin ~/ 60),
];

void main() {
  test('offers what most of the planned weekdays had', () {
    final live = [
      _on('2026-10-20', 'Deep work', 9, 12),
      _on('2026-10-13', 'Deep work', 9, 12),
      _on('2026-10-06', 'Deep work', 9, 12),
      _on('2026-10-20', 'Gym', 18, 19),
    ];
    // Three weekdays had a plan (29 September had none), so a slot needs
    // two of them: Deep work has three, Gym one.
    expect(_slots(suggestPlan(_date, live, const {})), [('Deep work', 9, 12)]);
  });

  test('a single planned week is enough, and empty weeks never outvote it', () {
    final live = [
      _on('2026-10-20', 'Deep work', 9, 12),
      _on('2026-10-20', 'Gym', 18, 19),
    ];
    expect(_slots(suggestPlan(_date, live, const {})), [
      ('Deep work', 9, 12),
      ('Gym', 18, 19),
    ]);
  });

  test('a frozen plan wins over the live blocks for its day', () {
    final live = [_on('2026-10-13', 'Deep work', 9, 12)];
    final frozen = {
      '2026-10-13': encodeFrozenPlan([_on('2026-10-13', 'Reading', 20, 21)]),
    };
    expect(_slots(suggestPlan(_date, live, frozen)), [('Reading', 20, 21)]);
  });

  test('of two overlapping slots the more common one stays', () {
    final live = [
      _on('2026-10-20', 'Admin', 10, 11),
      _on('2026-10-13', 'Admin', 10, 11),
      _on('2026-10-13', 'Deep work', 9, 12),
      _on('2026-10-06', 'Deep work', 9, 12),
      _on('2026-09-29', 'Deep work', 9, 12),
    ];
    expect(_slots(suggestPlan(_date, live, const {})), [('Deep work', 9, 12)]);
  });

  test('on a tie the more recent slot stays', () {
    final live = [
      _on('2026-10-20', 'Admin', 10, 11),
      _on('2026-10-13', 'Deep work', 9, 12),
    ];
    expect(_slots(suggestPlan(_date, live, const {})), [('Admin', 10, 11)]);
  });

  test('the newest copy gives the name, colour and any-app setting', () {
    final live = [
      _on('2026-10-20', 'deep work ', 9, 12, color: 2, anyApp: true),
      _on('2026-10-13', 'Deep work', 9, 12, color: 1),
    ];
    final b = suggestPlan(_date, live, const {}).single;
    expect(b.name, 'deep work ');
    expect(b.colorIdx, 2);
    expect(b.anyApp, isTrue);
  });

  test('suggestions are one-offs dated the day asked for, in start order', () {
    final live = [
      _on('2026-10-20', 'Gym', 18, 19),
      _on('2026-10-20', 'Deep work', 9, 12),
    ];
    final out = suggestPlan(_date, live, const {});
    expect(out.map((b) => b.name), ['Deep work', 'Gym']);
    expect(out.every((b) => b.date == '2026-10-27' && b.repeatMask == 0 && b.id == null), isTrue);
  });

  test('a repeating block counts on the weeks it ran', () {
    const tuesday = 1 << (DateTime.tuesday - 1);
    final live = [
      const PlanBlock(
        name: 'Standup',
        startMin: 9 * 60,
        endMin: 9 * 60 + 30,
        repeatMask: tuesday,
        skipDates: ['2026-10-20', '2026-10-13', '2026-10-06'],
      ),
      _on('2026-10-20', 'Reading', 20, 21),
    ];
    // Planned weekdays: 20 Oct (Reading) and 29 Sep (Standup only). Each
    // slot appears once of two, which is half.
    expect(_slots(suggestPlan(_date, live, const {})).map((s) => s.$1), ['Standup', 'Reading']);
  });

  test('a day a repeating block was taken off gets no suggestions', () {
    const tuesday = 1 << (DateTime.tuesday - 1);
    final live = [
      const PlanBlock(
        name: 'Gym',
        startMin: 8 * 60,
        endMin: 9 * 60,
        repeatMask: tuesday,
        skipDates: ['2026-10-27'],
      ),
    ];
    expect(suggestPlan(_date, live, const {}), isEmpty);
    // The next Tuesday was not touched, so Gym is offered there.
    expect(_slots(suggestPlan(DateTime(2026, 11, 3), [
      live.single.copyWith(repeatMask: 0, date: '2026-10-20'),
    ], const {})), [('Gym', 8, 9)]);
  });

  test('no history, no suggestions', () {
    expect(suggestPlan(_date, const [], const {}), isEmpty);
    // Blocks with no length are ignored.
    expect(suggestPlan(_date, [_on('2026-10-20', 'Broken', 9, 9)], const {}), isEmpty);
  });
}
