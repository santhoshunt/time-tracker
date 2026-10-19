import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/plan_screen.dart';
import 'package:drift_time/widgets/plan_timeline.dart';
import 'package:drift_time/widgets/plan_week_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';

// testNow is Monday 19 October 2026, 13:30.

DateTime _d(int day, [int month = 10]) => DateTime(2026, month, day);

Future<(AppServices, SettingsProvider)> _setUp({
  int firstWeekday = DateTime.monday,
}) async {
  final s = await testServices();
  addTearDown(s.db.close);
  SharedPreferences.setMockInitialValues({
    if (firstWeekday == DateTime.sunday) 'week_start_v1': 'sunday',
  });
  final settings = SettingsProvider();
  await settings.load();
  return (s, settings);
}

/// Pumps the Plan tab on a phone-sized screen and switches it to Week.
Future<void> _pumpWeek(
  WidgetTester tester,
  AppServices s,
  SettingsProvider settings,
) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(393, 851) * 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(withApp(s, settings, const PlanScreen()));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Week'));
  await tester.pumpAndSettle();
}

/// The chip row scrolls sideways; a chip may sit past the edge.
Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Finder _day(DateTime d) => find.byKey(PlanWeekView.dayKey(d));

Finder _inDay(DateTime d, String text) =>
    find.descendant(of: _day(d), matching: find.text(text));

/// Everything about a block except its row id, which an insert renews.
String _shape(PlanBlock b) =>
    '${b.name} ${b.startMin} ${b.endMin} ${b.colorIdx} ${b.repeatMask} '
    '${b.date} ${b.anyApp} ${b.skipDates.join(',')}';

Future<List<String>> _shapes(AppServices s) async =>
    (await s.plans.allBlocks()).map(_shape).toList()..sort();

List<(String, int, int)> _oneOffs(List<PlanBlock> all, DateTime d) => [
  for (final b in all)
    if (b.repeatMask == 0 && b.date == dateKey(d)) (b.name, b.startMin, b.endMin),
]..sort((a, b) => a.$2.compareTo(b.$2));

void main() {
  testWidgets('the week shows seven columns with each day\'s blocks', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    await s.plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, repeatMask: PlanBlock.weekdays),
    );
    await s.plans.insertBlock(
      const PlanBlock(
        name: 'Deep work',
        startMin: 540,
        endMin: 720,
        repeatMask: PlanBlock.weekdays,
        skipDates: ['2026-10-21'],
      ),
    );
    await s.plans.insertBlock(
      const PlanBlock(name: 'Hike', startMin: 420, endMin: 660, colorIdx: 3, date: '2026-10-24'),
    );
    await s.plans.insertBlock(
      const PlanBlock(name: 'Errands', startMin: 900, endMin: 960, date: '2026-10-27'),
    );
    await _pumpWeek(tester, s, settings);

    expect(find.text('Plan this week'), findsOneWidget);
    expect(find.text('19 to 25 Oct'), findsOneWidget);
    for (var day = 19; day <= 25; day++) {
      expect(_day(_d(day)), findsOneWidget);
    }
    expect(_day(_d(18)), findsNothing);
    expect(_day(_d(26)), findsNothing);

    for (var day = 19; day <= 23; day++) {
      expect(_inDay(_d(day), 'Gym'), findsOneWidget);
    }
    expect(_inDay(_d(20), 'Deep work'), findsOneWidget);
    // The repeating block sits out the date it was taken off.
    expect(_inDay(_d(21), 'Deep work'), findsNothing);
    expect(_inDay(_d(24), 'Hike'), findsOneWidget);
    expect(_inDay(_d(24), 'Gym'), findsNothing);
    expect(find.text('Errands'), findsNothing); // Next week.
    expect(
      find.bySemanticsLabel('Sunday 25 October, no blocks'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Monday 19 October, 2 blocks'),
      findsOneWidget,
    );
    // No add button over the last column.
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  test('week starts and labels', () {
    expect(planWeekStart(_d(21), DateTime.monday), _d(19));
    expect(planWeekStart(_d(21), DateTime.sunday), _d(18));
    expect(planWeekStart(_d(18), DateTime.sunday), _d(18));
    final today = _d(19);
    expect(planWeekLabel(_d(12), today), '12 to 18 Oct');
    expect(planWeekLabel(_d(26), today), '26 Oct to 1 Nov');
    expect(planWeekLabel(DateTime(2026, 12, 28), today), '28 Dec 2026 to 3 Jan 2027');
    expect(planWeekLabel(DateTime(2027, 1, 4), today), '4 to 10 Jan 2027');
  });

  test('the axis starts earlier when a block does', () {
    expect(PlanWeekView.axisStart(const []), 360);
    expect(
      PlanWeekView.axisStart(const [
        PlanBlock(name: 'Run', startMin: 330, endMin: 390),
        PlanBlock(name: 'Gym', startMin: 480, endMin: 540),
      ]),
      300,
    );
    expect(PlanWeekView.axisMarks(360), [360, 540, 720, 900, 1080, 1260, 1440]);
    // 05:00 is too close to 06:00 for its own label.
    expect(PlanWeekView.axisMarks(300).first, 360);
    expect(PlanWeekView.axisMarks(240).first, 240);
  });

  testWidgets('the week starts on Sunday when the setting says so', (
    tester,
  ) async {
    final (s, settings) = await _setUp(firstWeekday: DateTime.sunday);
    await _pumpWeek(tester, s, settings);

    expect(find.text('18 to 24 Oct'), findsOneWidget);
    expect(_day(_d(18)), findsOneWidget);
    expect(_day(_d(24)), findsOneWidget);
    expect(_day(_d(25)), findsNothing);
    final left = tester.getTopLeft(_day(_d(18))).dx;
    expect(left, lessThan(tester.getTopLeft(_day(_d(19))).dx));
  });

  testWidgets('the arrows move a week and This week comes back', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    await _pumpWeek(tester, s, settings);
    expect(find.text('This week'), findsNothing);

    await tester.tap(find.byTooltip('Next week'));
    await tester.pumpAndSettle();
    expect(find.text('26 Oct to 1 Nov'), findsOneWidget);
    expect(find.text('Plan next week'), findsOneWidget);
    expect(_day(_d(1, 11)), findsOneWidget);

    await tester.tap(find.byTooltip('Previous week'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous week'));
    await tester.pumpAndSettle();
    expect(find.text('12 to 18 Oct'), findsOneWidget);
    expect(find.text('Plan last week'), findsOneWidget);

    await tester.tap(find.text('This week'));
    await tester.pumpAndSettle();
    expect(find.text('19 to 25 Oct'), findsOneWidget);
    expect(find.text('This week'), findsNothing);
  });

  testWidgets('tapping a day opens it in the Day view', (tester) async {
    final (s, settings) = await _setUp();
    await s.plans.insertBlock(
      const PlanBlock(name: 'Dentist', startMin: 900, endMin: 960, date: '2026-10-21'),
    );
    await _pumpWeek(tester, s, settings);

    await tester.tap(_day(_d(21)));
    await tester.pumpAndSettle();

    expect(find.byType(PlanWeekView), findsNothing);
    expect(find.byType(PlanTimeline), findsOneWidget);
    expect(find.text('Plan Wednesday'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('a day in a later week opens with its pill on the strip', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    await _pumpWeek(tester, s, settings);

    await tester.tap(find.byTooltip('Next week'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Next week'));
    await tester.pumpAndSettle();
    await tester.tap(_day(_d(5, 11)));
    await tester.pumpAndSettle();

    expect(find.text('Plan Thursday'), findsOneWidget);
    final pill = find.byKey(const ValueKey('planDay2026-11-05'));
    expect(pill, findsOneWidget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final box = tester.getRect(pill);
    expect(box.left, greaterThanOrEqualTo(0));
    expect(box.right, lessThanOrEqualTo(screen.width));

    // Today still returns to the usual first page.
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text('Plan Monday'), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('planDay2026-10-19'))).left, lessThan(60));
  });

  testWidgets('copy to next week replaces only days it has something for, then undo', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    final plans = s.plans;
    await plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, repeatMask: PlanBlock.weekdays),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, colorIdx: 2, date: '2026-10-19'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Hike', startMin: 420, endMin: 660, colorIdx: 3, anyApp: true, date: '2026-10-24'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Errands', startMin: 1020, endMin: 1080, date: '2026-10-26'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Dentist', startMin: 900, endMin: 960, date: '2026-10-27'),
    );
    final before = await _shapes(s);
    await _pumpWeek(tester, s, settings);

    await _tapChip(tester, 'Copy to next week');

    final all = await plans.allBlocks();
    expect(_oneOffs(all, _d(26)), [('Reading', 1200, 1260)]);
    // This Tuesday has nothing to copy, so next Tuesday's dentist stays.
    expect(_oneOffs(all, _d(27)), [('Dentist', 900, 960)]);
    expect(_oneOffs(all, _d(31)), [('Hike', 420, 660)]);
    final hike = all.firstWhere((b) => b.date == '2026-10-31');
    expect((hike.colorIdx, hike.anyApp), (3, true));
    // The repeating block is never copied.
    expect(all.where((b) => b.name == 'Gym'), hasLength(1));
    // This week is untouched.
    expect(_oneOffs(all, _d(19)), [('Reading', 1200, 1260)]);
    expect(find.text('Copied this week to 26 Oct to 1 Nov'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(await _shapes(s), before);
  });

  testWidgets('copy to next week with only repeating blocks changes nothing', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    await s.plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, repeatMask: PlanBlock.weekdays),
    );
    await s.plans.insertBlock(
      const PlanBlock(name: 'Errands', startMin: 1020, endMin: 1080, date: '2026-10-26'),
    );
    final before = await _shapes(s);
    await _pumpWeek(tester, s, settings);

    await _tapChip(tester, 'Copy to next week');

    expect(
      find.text('Nothing to copy: this week has only repeating blocks'),
      findsOneWidget,
    );
    expect(await _shapes(s), before);
  });

  testWidgets('fill weekends asks for a template when there is none', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    await _pumpWeek(tester, s, settings);

    await _tapChip(tester, 'Fill weekends');

    expect(find.text('Save a template first'), findsOneWidget);
    expect(find.text('Fill weekends with'), findsNothing);
    expect(await s.plans.allBlocks(), isEmpty);
  });

  testWidgets('fill weekends applies the picked template, then undo', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    final plans = s.plans;
    await plans.insertBlock(
      const PlanBlock(name: 'Stretch', startMin: 420, endMin: 435, repeatMask: PlanBlock.everyDay),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Groceries', startMin: 1020, endMin: 1080, date: '2026-10-24'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, date: '2026-10-23'),
    );
    await plans.saveTemplate('Workday', const [
      PlanBlock(name: 'Deep work', startMin: 540, endMin: 720),
    ]);
    await plans.saveTemplate('Weekend', const [
      PlanBlock(name: 'Stretch', startMin: 420, endMin: 435),
      PlanBlock(name: 'Long walk', startMin: 480, endMin: 600, colorIdx: 3),
      PlanBlock(name: 'Family', startMin: 1080, endMin: 1260, anyApp: true),
    ]);
    final before = await _shapes(s);
    await _pumpWeek(tester, s, settings);

    await _tapChip(tester, 'Fill weekends');
    expect(find.text('Fill weekends with'), findsOneWidget);
    expect(find.text('3 blocks, 07:00 to 21:00'), findsOneWidget);
    await tester.tap(find.text('Weekend'));
    await tester.pumpAndSettle();

    final all = await plans.allBlocks();
    const filled = [('Long walk', 480, 600), ('Family', 1080, 1260)];
    expect(_oneOffs(all, _d(24)), filled);
    expect(_oneOffs(all, _d(25)), filled);
    // The repeating Stretch already covers both days, so it is not added.
    expect(all.where((b) => b.name == 'Stretch'), hasLength(1));
    expect(_oneOffs(all, _d(23)), [('Reading', 1200, 1260)]);
    expect(
      find.text('Applied "Weekend" to Sat 24 Oct and Sun 25 Oct'),
      findsOneWidget,
    );
    expect(_inDay(_d(25), 'Long walk'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(await _shapes(s), before);
    expect(_inDay(_d(24), 'Groceries'), findsOneWidget);
  });

  testWidgets('holding a day copies it to the picked days without doubling', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    final plans = s.plans;
    await plans.insertBlock(
      const PlanBlock(
        name: 'Gym',
        startMin: 480,
        endMin: 540,
        colorIdx: 3,
        repeatMask: PlanBlock.weekdays,
        skipDates: ['2026-10-22'],
      ),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, date: '2026-10-19'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Errands', startMin: 1020, endMin: 1080, date: '2026-10-21'),
    );
    final before = await _shapes(s);
    await _pumpWeek(tester, s, settings);

    await tester.longPress(_day(_d(19)));
    await tester.pumpAndSettle();
    expect(find.text('Copy Mon 19 Oct to'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(6));
    expect(find.text('Mon 19 Oct'), findsNothing);
    final copy = find.widgetWithText(FilledButton, 'Copy');
    expect(tester.widget<FilledButton>(copy).onPressed, isNull);

    for (final day in ['Wed 21 Oct', 'Thu 22 Oct', 'Sat 24 Oct']) {
      await tester.tap(find.text(day));
      await tester.pump();
    }
    await tester.tap(copy);
    await tester.pumpAndSettle();

    final all = await plans.allBlocks();
    // Wednesday already has the repeating Gym, so only Reading lands, and
    // it replaces Errands.
    expect(_oneOffs(all, _d(21)), [('Reading', 1200, 1260)]);
    // Thursday was taken off the repeating Gym, so it gets a copy.
    expect(_oneOffs(all, _d(22)), [('Gym', 480, 540), ('Reading', 1200, 1260)]);
    expect(_oneOffs(all, _d(24)), [('Gym', 480, 540), ('Reading', 1200, 1260)]);
    final satGym = all.firstWhere((b) => b.date == '2026-10-24' && b.name == 'Gym');
    expect((satGym.repeatMask, satGym.colorIdx), (0, 3));
    expect(_oneOffs(all, _d(20)), isEmpty);
    expect(find.text('Copied Mon 19 Oct to 3 days'), findsOneWidget);
    expect(_inDay(_d(21), 'Gym'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(await _shapes(s), before);
    expect(_inDay(_d(21), 'Errands'), findsOneWidget);
  });

  testWidgets('holding an empty day says there is nothing to copy', (
    tester,
  ) async {
    final (s, settings) = await _setUp();
    await _pumpWeek(tester, s, settings);

    await tester.longPress(_day(_d(25)));
    await tester.pumpAndSettle();

    expect(find.text('Sun 25 Oct has no blocks to copy'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('select all ticks every other day', (tester) async {
    final (s, settings) = await _setUp();
    await s.plans.insertBlock(
      const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, date: '2026-10-20'),
    );
    await _pumpWeek(tester, s, settings);

    await tester.longPress(_day(_d(20)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Copy'));
    await tester.pumpAndSettle();

    final all = await s.plans.allBlocks();
    for (final day in [19, 21, 22, 23, 24, 25]) {
      expect(_oneOffs(all, _d(day)), [('Reading', 1200, 1260)]);
    }
    expect(find.text('Copied Tue 20 Oct to 6 days'), findsOneWidget);
  });
}
