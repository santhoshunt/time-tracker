@Tags(['golden'])
library;

import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/review_v3_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed_history.dart';
import '../helpers/test_app.dart';

void main() {
  setUpAll(loadDriftFonts);

  Future<(AppServices, SettingsProvider)> setup(ThemeId theme) async {
    final s = await testServices();
    await seedHistory(s);
    return (s, await testSettings(theme: theme));
  }

  Widget tabs(Widget child) => Scaffold(
    body: child,
    bottomNavigationBar: NavigationBar(
      selectedIndex: 2,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.schedule_outlined), label: 'Today'),
        NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Plan'),
        NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Review'),
        NavigationDestination(icon: Icon(Icons.donut_large_outlined), label: 'Usage'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ],
    ),
  );

  Future<void> shot(
    WidgetTester tester,
    String tab,
    String file, {
    ThemeId theme = ThemeId.mono,
    Size size = const Size(393, 851),
    double textScale = 1.0,
    int back = 0,
  }) async {
    final (s, settings) = await setup(theme);
    await pumpGolden(
      tester,
      withProviders(s, settings, tabs(const ReviewV3Screen())),
      theme: theme,
      size: size,
      textScale: textScale,
    );
    if (tab != 'Day') {
      await tester.tap(find.widgetWithText(Tab, tab));
      await tester.pumpAndSettle();
    }
    for (var i = 0; i < back; i++) {
      await tester.tap(find.byTooltip('Previous ${tab.toLowerCase()}'));
      await tester.pumpAndSettle();
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$file.png'));
    await s.db.close();
  }

  testWidgets('day, mono', (t) => shot(t, 'Day', 'review_v3_day_mono'));
  testWidgets('year, mono', (t) => shot(t, 'Year', 'review_v3_year_mono'));

  for (final theme in ThemeId.values) {
    testWidgets('week, ${theme.key}', (t) => shot(t, 'Week', 'review_v3_week_${theme.key}', theme: theme));
    testWidgets('month, ${theme.key}', (t) => shot(t, 'Month', 'review_v3_month_${theme.key}', theme: theme));
  }

  testWidgets('last week with the Back pill, mono', (t) => shot(t, 'Week', 'review_v3_week_back_mono', back: 1));

  // Whole pages, so the cards below the fold are checked too.
  for (final tab in ['Day', 'Week', 'Month']) {
    testWidgets('${tab.toLowerCase()}, mono, full length', (t) => shot(
      t,
      tab,
      'review_v3_${tab.toLowerCase()}_mono_full',
      size: const Size(393, 1500),
    ));
  }

  testWidgets('month, small screen with large text', (t) => shot(
    t,
    'Month',
    'review_v3_month_mono_small_1_3',
    size: const Size(320, 640),
    textScale: 1.3,
  ));

  testWidgets('year, small screen with large text', (t) => shot(
    t,
    'Year',
    'review_v3_year_mono_small_1_3',
    size: const Size(320, 640),
    textScale: 1.3,
  ));
}
