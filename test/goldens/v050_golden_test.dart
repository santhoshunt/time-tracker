@Tags(['golden'])
library;

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/screens/app_usage_screen.dart';
import 'package:drift_time/screens/plan_screen.dart';
import 'package:drift_time/screens/usage_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// The bottom bar as the app draws it in v0.5.0.
Widget _tabs(Widget child, int selected) => Scaffold(
  body: child,
  bottomNavigationBar: NavigationBar(
    selectedIndex: selected,
    destinations: const [
      NavigationDestination(icon: Icon(Icons.schedule_outlined), label: 'Today'),
      NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Plan'),
      NavigationDestination(icon: Icon(Icons.bar_chart_outlined), label: 'Review'),
      NavigationDestination(icon: Icon(Icons.donut_large), label: 'Usage'),
      NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
    ],
  ),
);

/// The sample morning plus an evening of games and a podcast, so the ring
/// has six categories.
Future<void> _seedUsage(AppServices s) async {
  await seedSampleDay(s, testNow);
  DateTime at(int h, int m) => DateTime(testNow.year, testNow.month, testNow.day, h, m);
  await s.apps.upsertAll(const [
    AppInfo(p: 'com.example.puzzle', label: 'Puzzle Quest', category: 'game'),
    AppInfo(p: 'com.example.maps', label: 'Maps', category: 'maps'),
  ], testNow);
  final day = DateTime(testNow.year, testNow.month, testNow.day);
  final existing = await s.sessions.sessionsBetween(day, day.add(const Duration(days: 1)));
  await s.sessions.replaceDay(day, DateTime(day.year, day.month, day.day + 1), [
    ...existing,
    Session(p: 'com.example.puzzle', start: at(6, 0), end: at(6, 35)),
    Session(p: 'com.example.maps', start: at(7, 40), end: at(7, 52)),
  ], [
    IdleSpan(at(7, 0), at(7, 40), IdleKind.screenOff),
    IdleSpan(at(11, 50), at(12, 10), IdleKind.locked),
  ]);
}

/// Deep work and Gym on the last two Mondays, Reading on one: an empty
/// Monday gets all three as suggestions.
Future<void> _seedHistory(AppServices s) async {
  for (final date in ['2026-10-12', '2026-10-05']) {
    await s.plans.insertBlock(PlanBlock(name: 'Deep work', startMin: 9 * 60, endMin: 12 * 60, colorIdx: 2, date: date));
    await s.plans.insertBlock(PlanBlock(name: 'Gym', startMin: 7 * 60, endMin: 8 * 60, colorIdx: 3, date: date));
  }
  await s.plans.insertBlock(const PlanBlock(name: 'Admin', startMin: 14 * 60, endMin: 15 * 60, colorIdx: 4, date: '2026-10-12'));
}

void main() {
  setUpAll(loadDriftFonts);

  for (final theme in [ThemeId.mono, ThemeId.cleanLight]) {
    testWidgets('usage, ${theme.key}', (tester) async {
      final s = await testServices();
      await _seedUsage(s);
      final settings = await testSettings(theme: theme);
      await pumpGolden(tester, withProviders(s, settings, _tabs(const UsageScreen(), 3)), theme: theme);
      if (theme == ThemeId.mono) {
        await tester.tap(find.text('Social'));
        await tester.pumpAndSettle();
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/usage_${theme.key}.png'));
      await s.db.close();
    });
  }

  testWidgets('usage, small screen with large text', (tester) async {
    final s = await testServices();
    await _seedUsage(s);
    final settings = await testSettings();
    await pumpGolden(
      tester,
      withProviders(s, settings, _tabs(const UsageScreen(), 3)),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await tester.tap(find.text('Productivity'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/usage_mono_small_1_3.png'));
    await s.db.close();
  });

  testWidgets('app page, mono', (tester) async {
    final s = await testServices();
    await _seedUsage(s);
    final sat = DateTime(2026, 10, 17);
    await s.sessions.replaceDay(sat, DateTime(2026, 10, 18), [
      Session(p: 'com.example.video', start: DateTime(2026, 10, 17, 20), end: DateTime(2026, 10, 17, 21, 10)),
    ], const []);
    final settings = await testSettings();
    await pumpGolden(
      tester,
      withProviders(s, settings, AppUsageScreen(package: 'com.example.video', day: testNow)),
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/app_usage_mono.png'));
    await s.db.close();
  });

  for (final theme in [ThemeId.mono, ThemeId.warmPaper]) {
    testWidgets('plan ghost blocks, ${theme.key}', (tester) async {
      final s = await testServices();
      await _seedHistory(s);
      final settings = await testSettings(theme: theme);
      await pumpGolden(tester, withProviders(s, settings, _tabs(const PlanScreen(), 1)), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plan_ghost_${theme.key}.png'));
      await s.db.close();
    });
  }
}
