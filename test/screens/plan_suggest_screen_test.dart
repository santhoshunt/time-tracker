import 'package:drift_time/app_services.dart';
import 'package:drift_time/data/drift_db.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/plan_screen.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/plan_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/test_app.dart' show FakeIconSwitcher;

/// Monday 2026-10-19, 10:30.
final _now = DateTime(2026, 10, 19, 10, 30);

Future<AppServices> _services() async {
  final db = await openDriftDb(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  addTearDown(db.close);
  return AppServices(
    db: db,
    usage: FakeUsageSource(),
    icons: FakeIconSwitcher(),
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
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: buildDriftTheme(ThemeId.mono),
        home: const PlanScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Deep work on the two Mondays before today, and Gym on one of them.
Future<void> _history(AppServices s) async {
  for (final date in ['2026-10-12', '2026-10-05']) {
    await s.plans.insertBlock(PlanBlock(name: 'Deep work', startMin: 540, endMin: 720, date: date, colorIdx: 2));
  }
  await s.plans.insertBlock(const PlanBlock(name: 'Gym', startMin: 1080, endMin: 1140, date: '2026-10-12'));
}

List<PlanBlock> _today(List<PlanBlock> all) => [
  for (final b in all)
    if (b.date == '2026-10-19') b,
];

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('an empty day shows faded blocks from past weeks', (tester) async {
    final s = await _services();
    await _history(s);
    await _pump(tester, s);
    // Two planned Mondays: Deep work is on both, Gym on one of two (half).
    expect(find.byType(GhostBlockTile), findsNWidgets(2));
    expect(find.text('Deep work'), findsOneWidget);
    expect(find.text('Keep all'), findsOneWidget);
    expect(find.text('Hide suggestions'), findsOneWidget);
    // The add hint gives way to the suggestions.
    expect(find.text('Drag to add a block'), findsNothing);
  });

  testWidgets('tapping one keeps just that block, with Undo', (tester) async {
    final s = await _services();
    await _history(s);
    await _pump(tester, s);
    await tester.tap(find.text('Deep work'));
    await tester.pumpAndSettle();
    final kept = _today(await s.plans.allBlocks());
    expect(kept.single.name, 'Deep work');
    expect(kept.single.startMin, 540);
    expect(kept.single.colorIdx, 2);
    expect(kept.single.repeatMask, 0);
    expect(find.text('Added Deep work'), findsOneWidget);
    // The day has a block now, so the other suggestion goes.
    expect(find.byType(GhostBlockTile), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(_today(await s.plans.allBlocks()), isEmpty);
    expect(find.byType(GhostBlockTile), findsNWidgets(2));
  });

  testWidgets('Keep all adds every suggestion at once', (tester) async {
    final s = await _services();
    await _history(s);
    await _pump(tester, s);
    await tester.tap(find.text('Keep all'));
    await tester.pumpAndSettle();
    expect(_today(await s.plans.allBlocks()).map((b) => b.name).toList()..sort(), ['Deep work', 'Gym']);
    expect(find.text('Added 2 suggested blocks'), findsOneWidget);
  });

  testWidgets('Hide suggestions clears them for that day only', (tester) async {
    final s = await _services();
    await _history(s);
    await s.plans.insertBlock(const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, date: '2026-10-13'));
    await _pump(tester, s);
    await tester.tap(find.text('Hide suggestions'));
    await tester.pumpAndSettle();
    expect(find.byType(GhostBlockTile), findsNothing);
    expect(find.text('Drag to add a block'), findsOneWidget);

    // Tuesday 20 October has its own history (13 October).
    await tester.tap(find.byKey(const ValueKey('planDay2026-10-20')));
    await tester.pumpAndSettle();
    expect(find.byType(GhostBlockTile), findsOneWidget);
  });

  testWidgets('no suggestions on a planned day or a past one', (tester) async {
    final s = await _services();
    await _history(s);
    await s.plans.insertBlock(const PlanBlock(name: 'Errands', startMin: 900, endMin: 960, date: '2026-10-19'));
    await s.plans.insertBlock(const PlanBlock(name: 'Reading', startMin: 1200, endMin: 1260, date: '2026-10-06'));
    await _pump(tester, s);
    expect(find.byType(GhostBlockTile), findsNothing);

    // Tuesday 13 October is past and empty, with history on the 6th.
    await tester.drag(find.byKey(const ValueKey('planDay2026-10-19')), const Offset(600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('planDay2026-10-13')));
    await tester.pumpAndSettle();
    expect(find.byType(GhostBlockTile), findsNothing);
  });
}
