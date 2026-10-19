@Tags(['golden'])
library;

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/rules_screen.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/ask_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  setUpAll(loadDriftFonts);

  Future<(AppServices, SettingsProvider)> setup(ThemeId theme) async {
    final s = await testServices();
    await seedSampleDay(s, testNow);
    return (s, await testSettings(theme: theme));
  }

  Widget tabs(Widget child) => Scaffold(
    body: child,
    bottomNavigationBar: NavigationBar(
      destinations: const [
        NavigationDestination(icon: Icon(Icons.schedule_outlined), label: 'Today'),
        NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Plan'),
        NavigationDestination(icon: Icon(Icons.bar_chart_outlined), label: 'Review'),
        NavigationDestination(icon: Icon(Icons.donut_large_outlined), label: 'Usage'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ],
    ),
  );

  /// Pumps Today and opens the ask sheet for WhatsApp during Deep work.
  Future<void> pumpAsk(
    WidgetTester tester,
    AppServices s,
    SettingsProvider settings,
    ThemeId theme, {
    Size size = const Size(393, 851),
    double textScale = 1.0,
  }) async {
    await pumpGolden(
      tester,
      withProviders(s, settings, tabs(const TodayScreen())),
      theme: theme,
      size: size,
      textScale: textScale,
    );
    final day = await loadDay(s, testNow);
    final whatsApp = day.unanswered.firstWhere((x) => x.p == 'com.example.chat');
    showAskSheet(tester.element(find.byType(TodayScreen)), s, day, whatsApp);
    await tester.pumpAndSettle();
  }

  /// The sample rules plus one under a key no block uses any more.
  Future<void> moreRules(AppServices s) async {
    await s.rules.upsertRule('Reading', 'com.example.notes', Verdict.onTrack, testNow);
    await s.rules.upsertRule('Reading', 'com.example.chat', Verdict.offTrack, testNow);
    await s.rules.upsertRule('Gym', 'com.example.music', Verdict.onTrack, testNow);
  }

  for (final theme in ThemeId.values) {
    testWidgets('ask sheet, ${theme.key}', (tester) async {
      final (s, settings) = await setup(theme);
      await pumpAsk(tester, s, settings, theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ask_sheet_${theme.key}.png'));
      await s.db.close();
    });
  }

  /// Friday 16 October, a weekday with the sample blocks: apps nobody has
  /// ruled on yet in Meetings and Family, so Not sorted has guesses both
  /// ways.
  Future<void> moreUnsorted(AppServices s) async {
    final d = DateTime(2026, 10, 16);
    DateTime at(int h, int m) => DateTime(d.year, d.month, d.day, h, m);
    await s.sessions.replaceDay(
      d,
      DateTime(d.year, d.month, d.day + 1),
      [
        Session(p: 'com.example.chat', start: at(13, 5), end: at(13, 20)),
        Session(p: 'com.example.notes', start: at(13, 25), end: at(13, 50)),
        Session(p: 'com.example.video', start: at(19, 0), end: at(19, 40)),
        Session(p: 'com.example.music', start: at(20, 0), end: at(20, 30)),
      ],
      const [],
    );
  }

  Future<void> openNotSorted(WidgetTester tester) async {
    await tester.tap(find.textContaining('Not sorted'));
    await tester.pumpAndSettle();
  }

  for (final theme in [ThemeId.mono, ThemeId.cleanLight]) {
    testWidgets('learned rules, not sorted, ${theme.key}', (tester) async {
      final (s, settings) = await setup(theme);
      await moreRules(s);
      await moreUnsorted(s);
      await pumpGolden(tester, withProviders(s, settings, const RulesScreen()), theme: theme);
      await openNotSorted(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/rules_${theme.key}.png'));
      await s.db.close();
    });
  }

  testWidgets('learned rules, sorted, mono', (tester) async {
    final (s, settings) = await setup(ThemeId.mono);
    await moreRules(s);
    await moreUnsorted(s);
    await pumpGolden(tester, withProviders(s, settings, const RulesScreen()));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/rules_sorted_mono.png'));
    await s.db.close();
  });

  testWidgets('ask sheet, small screen with large text', (tester) async {
    final (s, settings) = await setup(ThemeId.mono);
    await pumpAsk(tester, s, settings, ThemeId.mono, size: const Size(320, 640), textScale: 1.3);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ask_sheet_mono_small_1_3.png'));
    await s.db.close();
  });

  testWidgets('learned rules, small screen with large text', (tester) async {
    final (s, settings) = await setup(ThemeId.mono);
    await moreRules(s);
    await moreUnsorted(s);
    await pumpGolden(
      tester,
      withProviders(s, settings, const RulesScreen()),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await openNotSorted(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/rules_mono_small_1_3.png'));
    await s.db.close();
  });
}
