import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/diagnostics_screen.dart';
import 'package:drift_time/screens/icon_picker_screen.dart';
import 'package:drift_time/screens/review_screen.dart';
import 'package:drift_time/screens/settings_screen.dart';
import 'package:drift_time/screens/theme_picker_screen.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

Future<PackageInfo> _info() async => PackageInfo(
  appName: 'Drift',
  packageName: driftPackage,
  version: '0.1.0',
  buildNumber: '1',
);

void main() {
  late AppServices services;
  late SettingsProvider settings;
  late FakeIconSwitcher icons;

  setUp(() async {
    icons = FakeIconSwitcher();
    services = await testServices(icons: icons);
    settings = await testSettings();
    PackageInfo.setMockInitialValues(
      appName: 'Drift',
      packageName: driftPackage,
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  tearDown(() => services.db.close());

  group('day loader', () {
    test('classifies the sample morning against the plan', () async {
      await seedSampleDay(services, testNow);
      final data = await loadDay(services, testNow);

      expect(data.blocks.map((b) => b.name), [
        'Gym',
        'Deep work',
        'Lunch',
        'Meetings',
        'Family',
      ]);
      Verdict verdictAt(int h, int m) => data.segments
          .firstWhere(
            (s) =>
                !s.start.isAfter(DateTime(2026, 10, 19, h, m)) &&
                s.end.isAfter(DateTime(2026, 10, 19, h, m)),
          )
          .verdict;
      expect(verdictAt(9, 10), Verdict.onTrack); // Notes, a rule
      expect(verdictAt(9, 50), Verdict.offTrack); // Instagram, a rule
      expect(verdictAt(10, 20), Verdict.guessedOff); // WhatsApp, social guess
      expect(verdictAt(8, 20), Verdict.guessedOn); // Spotify, audio guess
      expect(verdictAt(12, 20), Verdict.onTrack); // YouTube at an anyApp lunch
      expect(verdictAt(12, 0), Verdict.idle); // locked inside Deep work
      expect(data.score, isNotNull);
      expect(data.unanswered.map((s) => s.p), [
        'com.example.music',
        'com.example.chat',
      ]);
      expect(data.topDrift.first, ('com.example.video', 35));
    });

    test('a day with no plan has no score', () async {
      final data = await loadDay(services, testNow);
      expect(data.score, isNull);
      expect(data.blocks, isEmpty);
    });
  });

  group('Today', () {
    testWidgets('shows the score and the plan blocks in lanes', (tester) async {
      await seedSampleDay(services, testNow);
      await tester.pumpWidget(withApp(services, settings, const Scaffold(body: TodayScreen())));
      await tester.pumpAndSettle();

      expect(find.text('Deep work'), findsOneWidget);
      expect(find.textContaining('%'), findsWidgets);
      expect(find.text('Lanes'), findsOneWidget);
    });

    testWidgets('the Lanes / Ring choice is remembered', (tester) async {
      await seedSampleDay(services, testNow);
      await tester.pumpWidget(withApp(services, settings, const Scaffold(body: TodayScreen())));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ring'));
      await tester.pumpAndSettle();
      expect(settings.todayView, TodayView.ring);
      expect(find.text('Drift today'), findsOneWidget);
      expect(find.text('13:30'), findsOneWidget);
      expect(find.text('Meetings'), findsOneWidget);
    });

    testWidgets('tapping a stretch of app use explains it', (tester) async {
      await seedSampleDay(services, testNow);
      await tester.pumpWidget(withApp(services, settings, const Scaffold(body: TodayScreen())));
      await tester.pumpAndSettle();

      // The timeline opens scrolled to now (13:30), so 10:15 is above it.
      final whatsApp = find.bySemanticsLabel(RegExp('^WhatsApp')).first;
      await tester.ensureVisible(whatsApp);
      await tester.pumpAndSettle();
      await tester.tap(whatsApp);
      await tester.pumpAndSettle();
      expect(find.text('Guessed off track'), findsWidgets);
      expect(find.textContaining('10:15 to 10:24'), findsOneWidget);
    });

    testWidgets('with nothing planned it offers to plan', (tester) async {
      var planned = false;
      await tester.pumpWidget(
        withApp(services, settings, Scaffold(body: TodayScreen(onPlan: () => planned = true))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Plan today'));
      expect(planned, isTrue);
    });

    testWidgets('reloads when the services revision changes', (tester) async {
      await tester.pumpWidget(withApp(services, settings, const Scaffold(body: TodayScreen())));
      await tester.pumpAndSettle();
      expect(find.text('Nothing planned yet'), findsOneWidget);

      await seedSampleDay(services, testNow);
      services.bump();
      await tester.pumpAndSettle();
      expect(find.text('Nothing planned yet'), findsNothing);
    });
  });

  group('Settings', () {
    testWidgets('shows the version, theme and icon', (tester) async {
      await tester.pumpWidget(
        withApp(services, settings, SettingsScreen(packageInfo: _info)),
      );
      await tester.pumpAndSettle();

      expect(find.text('v0.1.0'), findsOneWidget);
      expect(find.text('Mono'), findsOneWidget);
      expect(find.text('Melting clock'), findsOneWidget);
    });

    testWidgets('the theme picker changes the theme', (tester) async {
      await tester.pumpWidget(withApp(services, settings, const ThemePickerScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Warm paper'));
      await tester.pumpAndSettle();
      expect(settings.theme, ThemeId.warmPaper);
    });

    testWidgets('the icon picker switches the launcher alias', (tester) async {
      await tester.pumpWidget(withApp(services, settings, const IconPickerScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Needle'));
      await tester.pumpAndSettle();
      expect(icons.sets, ['IconNeedle']);

      await tester.tap(find.text('Needle'));
      await tester.pumpAndSettle();
      expect(icons.sets, ['IconNeedle'], reason: 'tapping the current icon does nothing');
    });

    testWidgets('the check on launch switch flips the setting', (tester) async {
      await tester.pumpWidget(
        withApp(services, settings, SettingsScreen(packageInfo: _info)),
      );
      await tester.pumpAndSettle();

      expect(settings.updateOnLaunch, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.updateOnLaunch, isFalse);
    });
  });

  group('Diagnostics', () {
    testWidgets('lists permissions and copies a plain report', (tester) async {
      final usage = FakeUsageSource(ignoringBatteryOptimizations: false);
      await services.db.close();
      services = await testServices(usage: usage);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );

      await tester.pumpWidget(
        withApp(services, settings, const DiagnosticsScreen(packageInfo: _info)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Usage access'), findsOneWidget);
      expect(find.text('Restricted'), findsOneWidget);
      expect(find.text('0.1.0 (1)'), findsOneWidget);

      await tester.tap(find.text('Copy report'));
      await tester.pumpAndSettle();
      expect(copied.single, contains('usage_access: On'));
      expect(copied.single, contains('battery_exempt: Restricted'));
      expect(copied.single, contains('version: 0.1.0 (1)'));
      expect(find.text('Report copied'), findsOneWidget);
    });
  });

  group('Review', () {
    testWidgets('shows drift by block and steps back a day', (tester) async {
      await seedSampleDay(services, testNow);
      await tester.pumpWidget(withApp(services, settings, const Scaffold(body: ReviewScreen())));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Drift by block'), findsOneWidget);
      expect(find.text('YouTube'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      expect(find.text('Sun 18 Oct'), findsOneWidget);
      expect(find.text('Nothing planned yet'), findsOneWidget);
    });
  });
}
