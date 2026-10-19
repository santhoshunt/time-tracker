@Tags(['golden'])
library;

import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/diagnostics_screen.dart';
import 'package:drift_time/screens/icon_picker_screen.dart';
import 'package:drift_time/screens/onboarding_screen.dart';
import 'package:drift_time/screens/settings_screen.dart';
import 'package:drift_time/screens/theme_picker_screen.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

Future<PackageInfo> _info() async => PackageInfo(
  appName: 'Drift',
  packageName: driftPackage,
  version: '0.1.0',
  buildNumber: '1',
);

void main() {
  setUpAll(loadDriftFonts);

  Future<(AppServices, SettingsProvider)> setup(ThemeId theme, {bool seed = true}) async {
    final s = await testServices(usage: FakeUsageSource(ignoringBatteryOptimizations: false));
    if (seed) await seedSampleDay(s, testNow);
    return (s, await testSettings(theme: theme));
  }

  Widget tabs(Widget child) => Scaffold(body: child, bottomNavigationBar: NavigationBar(
    destinations: const [
      NavigationDestination(icon: Icon(Icons.schedule_outlined), label: 'Today'),
      NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Plan'),
      NavigationDestination(icon: Icon(Icons.bar_chart_outlined), label: 'Review'),
      NavigationDestination(icon: Icon(Icons.donut_large_outlined), label: 'Usage'),
      NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
    ],
  ));

  for (final theme in ThemeId.values) {
    testWidgets('today lanes, ${theme.key}', (tester) async {
      final (s, settings) = await setup(theme);
      await pumpGolden(tester, withProviders(s, settings, tabs(const TodayScreen())), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/today_lanes_${theme.key}.png'));
      await s.db.close();
    });

    testWidgets('today ring, ${theme.key}', (tester) async {
      final (s, settings) = await setup(theme);
      await settings.setTodayView(TodayView.ring);
      await pumpGolden(tester, withProviders(s, settings, tabs(const TodayScreen())), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/today_ring_${theme.key}.png'));
      await s.db.close();
    });

    testWidgets('settings, ${theme.key}', (tester) async {
      final (s, settings) = await setup(theme, seed: false);
      await pumpGolden(tester, withProviders(s, settings, tabs(const SettingsScreen(packageInfo: _info))), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_${theme.key}.png'));
      await s.db.close();
    });
  }

  testWidgets('theme picker', (tester) async {
    final (s, settings) = await setup(ThemeId.mono, seed: false);
    await pumpGolden(tester, withProviders(s, settings, const ThemePickerScreen()));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/theme_picker_mono.png'));
    await s.db.close();
  });

  testWidgets('icon picker', (tester) async {
    final (s, settings) = await setup(ThemeId.mono, seed: false);
    await pumpGolden(tester, withProviders(s, settings, const IconPickerScreen()));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/icon_picker_mono.png'));
    await s.db.close();
  });

  testWidgets('diagnostics', (tester) async {
    final (s, settings) = await setup(ThemeId.mono);
    await pumpGolden(tester, withProviders(s, settings, const DiagnosticsScreen(packageInfo: _info)));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/diagnostics_mono.png'));
    await s.db.close();
  });

  for (final theme in [ThemeId.mono, ThemeId.cleanLight]) {
    testWidgets('onboarding, ${theme.key}', (tester) async {
      final usage = FakeUsageSource(usageAccess: false);
      await pumpGolden(
        tester,
        OnboardingScreen(steps: setupSteps(usage), onDone: () {}),
        theme: theme,
      );
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/onboarding_${theme.key}.png'));
    });
  }

  testWidgets('today lanes, small screen with large text', (tester) async {
    final (s, settings) = await setup(ThemeId.mono);
    await pumpGolden(
      tester,
      withProviders(s, settings, tabs(const TodayScreen())),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/today_lanes_mono_small_1_3.png'));
    await s.db.close();
  });

  testWidgets('settings, small screen with large text', (tester) async {
    final (s, settings) = await setup(ThemeId.mono, seed: false);
    await pumpGolden(
      tester,
      withProviders(s, settings, tabs(const SettingsScreen(packageInfo: _info))),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_mono_small_1_3.png'));
    await s.db.close();
  });
}
