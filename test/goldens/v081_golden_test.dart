@Tags(['golden'])
library;

import 'package:drift_time/screens/settings_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/golden.dart';
import '../helpers/test_app.dart';

Future<PackageInfo> _info() async => PackageInfo(
  appName: 'Drift',
  packageName: 'io.github.santhoshunt.drift',
  version: '0.8.1',
  buildNumber: '14',
);

/// Settings option B: Apps on top with the to-sort badge on Learned rules,
/// the other settings as category rows, and one category page.
void main() {
  setUpAll(loadDriftFonts);

  for (final theme in [ThemeId.mono, ThemeId.cleanLight]) {
    testWidgets('settings root with apps waiting, ${theme.key}', (tester) async {
      final s = await testServices();
      s.toSort.value = 3;
      final settings = await testSettings(theme: theme);
      await pumpGolden(
        tester,
        withProviders(s, settings, const SettingsScreen(packageInfo: _info)),
        theme: theme,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_root_badge_${theme.key}.png'),
      );
      await s.db.close();
    });
  }

  testWidgets('settings nudges page', (tester) async {
    final s = await testServices();
    final settings = await testSettings();
    // The providers sit above the app, as in DriftApp, so the pushed page
    // reaches them.
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      withApp(s, settings, const SettingsScreen(packageInfo: _info)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nudges'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_nudges_mono.png'),
    );
    await s.db.close();
  });
}
