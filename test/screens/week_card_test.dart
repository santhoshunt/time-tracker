import 'package:drift_time/app.dart';
import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/settings_screen.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/screens/usage_screen.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/services/nudge_sync.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/score_card.dart';
import 'package:drift_time/widgets/week_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

Future<PackageInfo> _info() async => PackageInfo(
  appName: 'Drift',
  packageName: driftPackage,
  version: '0.5.0',
  buildNumber: '8',
);

void main() {
  late AppServices s;
  late SettingsProvider settings;

  setUp(() async {
    s = await testServices();
    settings = await testSettings();
  });

  tearDown(() => s.db.close());

  Future<void> pumpToday(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(withApp(s, settings, const Scaffold(body: TodayScreen())));
    await tester.pumpAndSettle();
  }

  group('Today week row', () {
    testWidgets('shows the week, the streak and the target in the day card', (tester) async {
      await seedSampleDay(s, testNow);
      final percent = (await tester.runAsync(() => loadDay(s, testNow)))!.score!.percent;
      await pumpToday(tester);
      expect(find.byType(DayCard), findsOneWidget);
      expect(find.descendant(of: find.byType(DayCard), matching: find.byType(WeekRow)), findsOneWidget);
      expect(find.text('On track'), findsOneWidget);
      // Only today has data: a streak of one at 75% or more, none below.
      expect(find.text(percent >= 75 ? '1-day streak' : 'No streak yet'), findsOneWidget);
      // The week's score is today's, the only day with a score.
      expect(find.text('$percent% of 80% target'), findsOneWidget);
    });

    testWidgets('a target of Off leaves only the streak', (tester) async {
      await seedSampleDay(s, testNow);
      await settings.setWeeklyTarget(0);
      await pumpToday(tester);
      expect(find.byType(WeekRow), findsOneWidget);
      expect(find.textContaining('target'), findsNothing);
    });

    testWidgets('a week with no plan has no week row and no line', (tester) async {
      await pumpToday(tester);
      expect(find.byType(DayCard), findsOneWidget);
      expect(find.byType(WeekRow), findsNothing);
      expect(find.descendant(of: find.byType(DayCard), matching: find.byType(Divider)), findsNothing);
    });

    testWidgets('the scored card fits a small phone with large text', (tester) async {
      await seedSampleDay(s, testNow);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(320, 640) * 2;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(withApp(s, settings, const Scaffold(body: TodayScreen())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(WeekRow), findsOneWidget);
    });

    test('streak words', () {
      expect(streakLabel(0), 'No streak yet');
      expect(streakLabel(1), '1-day streak');
      expect(streakLabel(12), '12-day streak');
    });
  });

  group('settings', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(393, 851) * 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(withApp(s, settings, const SettingsScreen(packageInfo: _info)));
      await tester.pumpAndSettle();
    }

    testWidgets('the weekly target is picked and kept', (tester) async {
      await pumpSettings(tester);
      await tester.scrollUntilVisible(find.text('Weekly target'), 200);
      await tester.pumpAndSettle();
      expect(find.text('80%'), findsOneWidget);
      await tester.tap(find.text('Weekly target'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('70%'));
      await tester.pumpAndSettle();
      expect(settings.weeklyTarget, 70);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('weekly_target_v1'), 70);
      final again = SettingsProvider();
      await again.load();
      expect(again.weeklyTarget, 70);
    });

    testWidgets('focus lock switches on and reaches the nudge snapshot', (tester) async {
      await pumpSettings(tester);
      expect(find.text('Lock instead of nudge'), findsOneWidget);
      await tester.tap(find.text('Lock instead of nudge'));
      await tester.pumpAndSettle();
      expect(settings.focusLock, isTrue);
      final snapshot = await tester.runAsync(
        () => buildNudgeSnapshot(s, settings, DriftColors.of(ThemeId.mono)),
      );
      expect(snapshot!.lock, isTrue);
      expect(snapshot.toJson()['lock'], isTrue);
    });

    testWidgets('the notification switches save and reach the snapshot', (tester) async {
      await pumpSettings(tester);
      expect(find.text('Nudges and notifications'), findsOneWidget);
      for (final row in ['Today in notifications', 'Block reminders']) {
        await tester.scrollUntilVisible(find.text(row), 200);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(row));
        await tester.pumpAndSettle();
        await tester.tap(find.text(row));
        await tester.pumpAndSettle();
      }
      expect(settings.todayNotifications, isFalse);
      expect(settings.blockReminders, isFalse);
      final again = SettingsProvider();
      await again.load();
      expect(again.todayNotifications, isFalse);
      expect(again.blockReminders, isFalse);
      final snapshot = await tester.runAsync(
        () => buildNudgeSnapshot(s, settings, DriftColors.of(ThemeId.mono)),
      );
      expect(snapshot!.status, isFalse);
      expect(snapshot.reminders, isFalse);
    });

    test('both notification switches are on for a new install', () async {
      SharedPreferences.setMockInitialValues({});
      final p = SettingsProvider();
      await p.load();
      expect(p.todayNotifications, isTrue);
      expect(p.blockReminders, isTrue);
    });

    testWidgets('the lock row hides with live nudges off', (tester) async {
      await settings.setNudgesEnabled(false);
      await pumpSettings(tester);
      expect(find.text('Lock instead of nudge'), findsNothing);
    });

    test('a stored target out of range is pulled back in', () async {
      SharedPreferences.setMockInitialValues({'weekly_target_v1': 130});
      final p = SettingsProvider();
      await p.load();
      expect(p.weeklyTarget, 100);
      SharedPreferences.setMockInitialValues({'weekly_target_v1': 20});
      await p.load();
      expect(p.weeklyTarget, 50);
      SharedPreferences.setMockInitialValues({});
      await p.load();
      expect(p.weeklyTarget, 80);
      expect(p.focusLock, isFalse);
    });
  });

  testWidgets('five tabs fit a small phone with large text, Usage fourth', (tester) async {
    final nudges = FakeNudgeBridge()
      ..notifications = true
      ..overlay = true;
    final services = await tester.runAsync(() => testServices(nudges: nudges));
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(320, 640) * 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(DriftApp(services: services!, settings: settings));
    await tester.pumpAndSettle();

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
      [for (final d in bar.destinations) (d as NavigationDestination).label],
      ['Today', 'Plan', 'Review', 'Usage', 'Settings'],
    );
    await tester.tap(find.text('Usage'));
    await tester.pumpAndSettle();
    expect(find.byType(UsageScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => services.db.close());
  });
}
