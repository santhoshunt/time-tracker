import 'package:drift_time/app_services.dart';
import 'package:drift_time/data/drift_db.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/platform/icon_switcher.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/plan_screen.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/plan_timeline.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_usage_source.dart';

class _FakeIcons implements IconSwitcher {
  @override
  Future<String> current() async => iconAliasNames.first;

  @override
  Future<void> set(String aliasName) async {}
}

/// Monday 2026-10-19, 10:30.
final _now = DateTime(2026, 10, 19, 10, 30);

/// The database runs in the test isolate (the NoIsolate factory): the
/// isolate-backed factory answers on a real thread, which the fake clock
/// of testWidgets never waits for.
Future<AppServices> _services() async {
  final db = await openDriftDb(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  addTearDown(db.close);
  return AppServices(
    db: db,
    usage: FakeUsageSource(),
    icons: _FakeIcons(),
    clock: FixedClock(_now),
  );
}

Future<void> _pump(WidgetTester tester, AppServices services) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(393, 851) * 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
      ],
      child: MaterialApp(
        theme: buildDriftTheme(ThemeId.mono),
        home: const PlanScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The on-screen point for [minute] on the timeline, a little right of
/// the hour labels.
Offset _timelinePoint(WidgetTester tester, int minute) {
  final topLeft = tester.getTopLeft(find.byKey(PlanTimeline.contentKey));
  return topLeft + Offset(200, PlanTimeline.offsetOf(minute));
}

List<PlanBlock> _onDate(List<PlanBlock> all, String key) => [
  for (final b in all)
    if (b.repeatMask == 0 && b.date == key) b,
];

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('long-press and drag opens the editor with snapped times', (
    tester,
  ) async {
    final services = await _services();
    await _pump(tester, services);

    // Press at 09:05 (snaps down to 09:00), drag to 10:28 (rounds to 10:30).
    final gesture = await tester.startGesture(_timelinePoint(tester, 545));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(_timelinePoint(tester, 568));
    await tester.pump();
    await gesture.moveTo(_timelinePoint(tester, 628));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('New block'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('10:30'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Reading');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final blocks = await services.plans.allBlocks();
    expect(blocks, hasLength(1));
    expect(blocks.single.name, 'Reading');
    expect(blocks.single.startMin, 540);
    expect(blocks.single.endMin, 630);
    expect(blocks.single.repeatMask, 0);
    expect(blocks.single.date, '2026-10-19');
    expect(find.text('Reading'), findsOneWidget);
  });

  testWidgets('the add button opens the editor at the next free hour', (
    tester,
  ) async {
    final services = await _services();
    await services.plans.insertBlock(
      const PlanBlock(name: 'Deep work', startMin: 660, endMin: 720, date: '2026-10-19'),
    );
    await _pump(tester, services);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Now is 10:30 and 11:00 is taken, so 12:00 to 13:00.
    expect(find.text('New block'), findsOneWidget);
    expect(find.text('12:00'), findsOneWidget);
    expect(find.text('13:00'), findsOneWidget);
  });

  testWidgets('tapping a block opens it in the editor', (tester) async {
    final services = await _services();
    await services.plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, date: '2026-10-19'),
    );
    await _pump(tester, services);

    await tester.tap(find.text('Gym'));
    await tester.pumpAndSettle();

    expect(find.text('Edit block'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
  });

  testWidgets('save as template, apply it to another day, then undo', (
    tester,
  ) async {
    final services = await _services();
    final plans = services.plans;
    await plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, date: '2026-10-19'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Deep work', startMin: 540, endMin: 720, colorIdx: 2, date: '2026-10-19'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Errands', startMin: 1020, endMin: 1080, date: '2026-10-20'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Stretch', startMin: 420, endMin: 435, repeatMask: PlanBlock.everyDay),
    );
    await _pump(tester, services);

    // The chip row scrolls sideways; this chip sits at its end.
    await tester.ensureVisible(find.text('Save as template'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as template'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Workday');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final templates = await plans.allTemplates();
    expect(templates.single.name, 'Workday');
    expect(
      templates.single.blocks.map((b) => (b.name, b.startMin, b.endMin)),
      unorderedEquals([('Stretch', 420, 435), ('Gym', 480, 540), ('Deep work', 540, 720)]),
    );
    expect(find.text('Workday'), findsOneWidget);

    final before = await plans.allBlocks();
    await tester.tap(find.byKey(const ValueKey('planDay2026-10-20')));
    await tester.pumpAndSettle();
    expect(find.text('Errands'), findsOneWidget);

    await tester.ensureVisible(find.text('Workday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workday'));
    await tester.pumpAndSettle();

    var tuesday = _onDate(await plans.allBlocks(), '2026-10-20');
    expect(
      tuesday.map((b) => b.name),
      unorderedEquals(['Stretch', 'Gym', 'Deep work']),
    );
    expect(tuesday.firstWhere((b) => b.name == 'Deep work').colorIdx, 2);
    expect(find.text('Errands'), findsNothing);
    expect(find.text('Applied "Workday" to Tuesday'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final after = await plans.allBlocks();
    String shape(PlanBlock b) =>
        '${b.name} ${b.startMin} ${b.endMin} ${b.repeatMask} ${b.date}';
    expect(after.map(shape), unorderedEquals(before.map(shape)));
    expect(find.text('Errands'), findsOneWidget);
  });

  testWidgets('copy yesterday adds the blocks that are not already here', (
    tester,
  ) async {
    final services = await _services();
    final plans = services.plans;
    await plans.insertBlock(
      const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, date: '2026-10-18'),
    );
    await plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, repeatMask: PlanBlock.everyDay),
    );
    await _pump(tester, services);

    await tester.tap(find.text('Copy yesterday'));
    await tester.pumpAndSettle();

    final monday = _onDate(await plans.allBlocks(), '2026-10-19');
    expect(monday.map((b) => (b.name, b.startMin, b.endMin)), [('Reading', 1200, 1260)]);
    expect(find.text('Copied 1 block from yesterday'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(_onDate(await plans.allBlocks(), '2026-10-19'), isEmpty);
  });

  testWidgets('copy yesterday says so when yesterday is empty', (tester) async {
    final services = await _services();
    await _pump(tester, services);

    await tester.tap(find.text('Copy yesterday'));
    await tester.pumpAndSettle();

    expect(find.text('Yesterday has no blocks to copy'), findsOneWidget);
    expect(await services.plans.allBlocks(), isEmpty);
  });

  testWidgets('a repeating block skips the dates it was taken off', (
    tester,
  ) async {
    final services = await _services();
    await services.plans.insertBlock(
      const PlanBlock(
        name: 'Gym',
        startMin: 480,
        endMin: 540,
        repeatMask: PlanBlock.weekdays,
        skipDates: ['2026-10-20'],
      ),
    );
    await _pump(tester, services);
    expect(find.text('Gym'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('planDay2026-10-20')));
    await tester.pumpAndSettle();
    expect(find.text('Gym'), findsNothing);
    expect(find.text('Tuesday'), findsNothing); // Inside the "Plan Tuesday" span.
    expect(find.text('Plan Tuesday'), findsOneWidget);
  });
}
