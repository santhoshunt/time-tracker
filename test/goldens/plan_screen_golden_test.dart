@Tags(['golden'])
library;

import 'package:drift_time/domain/models.dart';
import 'package:drift_time/screens/block_editor_screen.dart';
import 'package:drift_time/screens/plan_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

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
