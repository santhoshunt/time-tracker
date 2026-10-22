@Tags(['golden'])
library;

import 'package:drift_time/domain/models.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// YouTube answered Neutral in Lunch: a solid grey slice in the lanes,
/// with its label readable on it in a dark and two light themes.
void main() {
  setUpAll(loadDriftFonts);

  for (final theme in [ThemeId.mono, ThemeId.cleanLight, ThemeId.warmPaper]) {
    testWidgets('today lanes with a neutral app, ${theme.key}', (tester) async {
      final s = await testServices();
      await seedSampleDay(s, testNow);
      await s.rules.upsertRule('Lunch', 'com.example.video', Verdict.neutral, testNow);
      final settings = await testSettings(theme: theme);
      await pumpGolden(
        tester,
        withProviders(s, settings, const Scaffold(body: TodayScreen())),
        theme: theme,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/today_neutral_${theme.key}.png'),
      );
      await s.db.close();
    });
  }
}
