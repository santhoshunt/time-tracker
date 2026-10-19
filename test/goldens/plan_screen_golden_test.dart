@Tags(['golden'])
library;

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/screens/block_editor_screen.dart';
import 'package:drift_time/screens/plan_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// A realistic week around testNow (Monday 19 October): the sample
/// weekday plan, a few coloured one-offs (an early run that pulls the axis
/// back to 05:00, an evening that overlaps Family), a busy Saturday and a
/// free Sunday.
Future<void> _seedWeek(AppServices s) async {
  await seedSampleDay(s, testNow);
  const oneOffs = [
    PlanBlock(name: 'Dentist', startMin: 15 * 60, endMin: 16 * 60, colorIdx: 4, date: '2026-10-20'),
    PlanBlock(name: 'Early run', startMin: 5 * 60 + 30, endMin: 6 * 60 + 30, colorIdx: 3, date: '2026-10-21'),
    PlanBlock(name: 'Reading', startMin: 21 * 60 + 30, endMin: 22 * 60 + 30, colorIdx: 2, date: '2026-10-22'),
    PlanBlock(name: 'Movie night', startMin: 20 * 60, endMin: 23 * 60, colorIdx: 5, date: '2026-10-23'),
    PlanBlock(name: 'Hike', startMin: 7 * 60, endMin: 12 * 60, colorIdx: 3, date: '2026-10-24'),
    PlanBlock(name: 'Groceries', startMin: 17 * 60, endMin: 18 * 60, colorIdx: 1, date: '2026-10-24'),
    PlanBlock(name: 'Dinner out', startMin: 19 * 60 + 30, endMin: 22 * 60, colorIdx: 4, date: '2026-10-24'),
  ];
  for (final b in oneOffs) {
    await s.plans.insertBlock(b);
  }
}

void main() {
  setUpAll(loadDriftFonts);

  for (final theme in ThemeId.values) {
    testWidgets('plan, ${theme.key}', (tester) async {
      final s = await testServices();
      await seedSampleDay(s, testNow);
      final settings = await testSettings(theme: theme);
      await pumpGolden(tester, withProviders(s, settings, const PlanScreen()), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plan_${theme.key}.png'));
      await s.db.close();
    });
  }

  testWidgets('plan, small screen with large text', (tester) async {
    final s = await testServices();
    await seedSampleDay(s, testNow);
    final settings = await testSettings();
    await pumpGolden(
      tester,
      withProviders(s, settings, const PlanScreen()),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plan_mono_small_1_3.png'));
    await s.db.close();
  });

  for (final theme in [ThemeId.mono, ThemeId.cleanLight]) {
    testWidgets('plan week, ${theme.key}', (tester) async {
      final s = await testServices();
      await _seedWeek(s);
      final settings = await testSettings(theme: theme);
      await pumpGolden(tester, withProviders(s, settings, const PlanScreen()), theme: theme);
      await tester.tap(find.text('Week'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plan_week_${theme.key}.png'));
      await s.db.close();
    });
  }

  testWidgets('plan week, small screen with large text', (tester) async {
    final s = await testServices();
    await _seedWeek(s);
    final settings = await testSettings();
    await pumpGolden(
      tester,
      withProviders(s, settings, const PlanScreen()),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plan_week_mono_small_1_3.png'));
    await s.db.close();
  });

  for (final theme in [ThemeId.mono, ThemeId.warmPaper]) {
    testWidgets('block editor, ${theme.key}', (tester) async {
      final s = await testServices();
      await seedSampleDay(s, testNow);
      final settings = await testSettings(theme: theme);
      final block = (await s.plans.allBlocks()).firstWhere((b) => b.name == 'Deep work');
      await pumpGolden(
        tester,
        withProviders(s, settings, BlockEditorScreen(services: s, block: block, date: testNow)),
        theme: theme,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/block_editor_${theme.key}.png'),
      );
      await s.db.close();
    });
  }

  testWidgets('block editor, small screen with large text', (tester) async {
    final s = await testServices();
    final settings = await testSettings();
    await pumpGolden(
      tester,
      withProviders(
        s,
        settings,
        BlockEditorScreen(
          services: s,
          block: const PlanBlock(name: 'A long block name for a narrow phone', startMin: 540, endMin: 720, repeatMask: PlanBlock.weekdays),
          date: testNow,
        ),
      ),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/block_editor_mono_small_1_3.png'),
    );
    await s.db.close();
  });
}
