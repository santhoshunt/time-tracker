import 'dart:convert';
import 'dart:io';

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/nudge_snapshot.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/onboarding_screen.dart';
import 'package:drift_time/screens/settings_screen.dart';
import 'package:drift_time/services/nudge_sync.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices s;
  late SettingsProvider settings;
  late FakeNudgeBridge nudges;
  late Directory dir;

  setUp(() async {
    nudges = FakeNudgeBridge();
    s = await testServices(nudges: nudges);
    settings = await testSettings();
    dir = await Directory.systemTemp.createTemp('drift_nudge');
  });

  tearDown(() async {
    await s.db.close();
    await dir.delete(recursive: true);
  });

  group('snapshot', () {
    test('covers the rest of today and tomorrow with the learned rules', () async {
      await seedSampleDay(s, testNow);
      final snap = await buildNudgeSnapshot(s, settings, DriftColors.of(ThemeId.mono));

      // 13:30 on a Monday: Gym, Deep work and Lunch have ended; Meetings
      // and Family remain today, then Tuesday's five blocks.
      expect(snap.windows.map((w) => w.block), [
        'Meetings',
        'Family',
        'Gym',
        'Deep work',
        'Lunch',
        'Meetings',
        'Family',
      ]);
      final deepWork = snap.windows.firstWhere((w) => w.block == 'Deep work');
      expect(deepWork.on, {'com.example.notes'});
      expect(deepWork.off, {'com.example.video', 'com.example.social'});
      expect(snap.windows.firstWhere((w) => w.block == 'Lunch').anyApp, isTrue);
      expect(snap.writtenAtMs, testNow.millisecondsSinceEpoch);
      expect((snap.nudgeAfterMin, snap.repeatMin), (5, 15));
      expect((snap.quietStartMin, snap.quietEndMin), (22 * 60, 7 * 60));
      expect(snap.colors['accent'], '#E6EAF2');
    });

    test('the decision on a built snapshot nudges for YouTube in Deep work', () async {
      await seedSampleDay(s, testNow);
      final tuesday10 = DateTime(2026, 10, 20, 10, 0);
      final snap = await buildNudgeSnapshot(s, settings, DriftColors.of(ThemeId.mono));
      final d = decideNudge(
        snap,
        nowMs: tuesday10.millisecondsSinceEpoch,
        nowLocalMin: 600,
        pkg: 'com.example.video',
        category: 'video',
        continuousMs: 6 * 60000,
      );
      expect(d, isA<Nudge>());
      expect((d as Nudge).block, 'Deep work');
      expect(d.minutesLeft, 120);
    });

    test('sync writes the file and starts the service when nudges are on', () async {
      await seedSampleDay(s, testNow);
      await syncNudges(s, settings, DriftColors.of(ThemeId.mono), directory: () async => dir);

      final json = jsonDecode(File('${dir.path}/$nudgeSnapshotFile').readAsStringSync());
      expect(json['v'], 1);
      expect(json['enabled'], isTrue);
      expect(File('${dir.path}/$nudgeSnapshotFile.tmp').existsSync(), isFalse);
      expect(nudges.starts, 1);
      expect(nudges.stops, 0);
    });

    test('with nudges off the service keeps running for the Today notifications', () async {
      await settings.setNudgesEnabled(false);
      await syncNudges(s, settings, DriftColors.of(ThemeId.mono), directory: () async => dir);
      expect(nudges.starts, 1);
      expect(nudges.stops, 0);
      final json = jsonDecode(File('${dir.path}/$nudgeSnapshotFile').readAsStringSync());
      expect(json['enabled'], isFalse);
      expect(json['status'], isTrue);
      expect(json['reminders'], isTrue);
    });

    test('reminders alone keep the service running', () async {
      await settings.setNudgesEnabled(false);
      await settings.setTodayNotifications(false);
      await syncNudges(s, settings, DriftColors.of(ThemeId.mono), directory: () async => dir);
      expect(nudges.starts, 1);
      final json = jsonDecode(File('${dir.path}/$nudgeSnapshotFile').readAsStringSync());
      expect(json['status'], isFalse);
      expect(json['reminders'], isTrue);
    });

    test('sync stops the service once nudges, notifications and reminders are all off', () async {
      await settings.setNudgesEnabled(false);
      await settings.setTodayNotifications(false);
      await settings.setBlockReminders(false);
      await syncNudges(s, settings, DriftColors.of(ThemeId.mono), directory: () async => dir);
      expect(nudges.stops, 1);
      expect(nudges.starts, 0);
    });

    test('the snapshot carries the distracting rule sets and the bar colour', () async {
      await seedSampleDay(s, testNow);
      final snap = await buildNudgeSnapshot(s, settings, DriftColors.of(ThemeId.mono));
      // The sample rules: Notes and Zoom on track, YouTube and Instagram off.
      expect(snap.offApps, {'com.example.video', 'com.example.social'});
      expect(snap.onApps, {'com.example.notes', 'com.example.meet'});
      expect(snap.colors['offTrack'], '#FF6B6B');
      final again = NudgeSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>,
      );
      expect(again.offApps, snap.offApps);
      expect(again.onApps, snap.onApps);
      expect(again.status, isTrue);
    });

    test('sync stops the service without usage access', () async {
      await s.db.close();
      s = await testServices(nudges: nudges, usage: FakeUsageSource(usageAccess: false));
      await syncNudges(s, settings, DriftColors.of(ThemeId.mono), directory: () async => dir);
      expect(nudges.starts, 0);
      expect(nudges.stops, 1);
    });
  });

  group('settings', () {
    test('nudge settings default as planned and survive a restart', () async {
      expect(settings.nudgesEnabled, isTrue);
      expect((settings.nudgeAfterMin, settings.nudgeRepeatMin), (5, 15));
      await settings.setNudgeAfterMin(10);
      await settings.setNudgeRepeatMin(30);
      await settings.setQuietHours(23 * 60, 6 * 60);
      await settings.skipSetup('overlay');
      final again = SettingsProvider();
      await again.load();
      expect((again.nudgeAfterMin, again.nudgeRepeatMin), (10, 30));
      expect((again.quietStartMin, again.quietEndMin), (23 * 60, 6 * 60));
      expect(again.skippedSetup, {'overlay'});
    });

    test('quiet hours read as a range, or Off', () {
      expect(quietHoursLabel(22 * 60, 7 * 60), '22:00 to 07:00');
      expect(quietHoursLabel(0, 0), 'Off');
    });

    testWidgets('the Nudges group hides its details when switched off', (tester) async {
      await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('First nudge after'), findsOneWidget);
      expect(find.text('22:00 to 07:00'), findsOneWidget);

      await tester.tap(find.text('Live nudges'));
      await tester.pumpAndSettle();
      expect(settings.nudgesEnabled, isFalse);
      expect(find.text('First nudge after'), findsNothing);
      expect(find.text('Learned rules'), findsOneWidget);
    });

    testWidgets('picking a new threshold saves it', (tester) async {
      await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First nudge after'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 min'));
      await tester.pumpAndSettle();
      expect(settings.nudgeAfterMin, 10);
    });
  });

  group('setup pages', () {
    testWidgets('optional pages offer Not now and remember it', (tester) async {
      final usage = FakeUsageSource();
      final skipped = <String>[];
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDriftTheme(ThemeId.mono),
          home: OnboardingScreen(
            steps: setupSteps(usage, nudges),
            onSkip: (k) async => skipped.add(k),
            onDone: () => done = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Let Drift tap you on the shoulder'), findsOneWidget);
      expect(find.text('Step 3 of 4'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Nudge right on top of the app'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(skipped, ['notifications', 'overlay']);
      expect(done, isTrue);
    });

    test('skipped optional steps no longer count as missing', () async {
      final steps = setupSteps(FakeUsageSource(), nudges);
      expect((await missingSteps(steps)).map((s) => s.key), ['notifications', 'overlay']);
      expect(await missingSteps(steps, skipped: {'notifications', 'overlay'}), isEmpty);
      expect(
        (await missingSteps(setupSteps(FakeUsageSource(usageAccess: false), nudges),
                skipped: {'usage_access'}))
            .map((s) => s.key),
        contains('usage_access'),
        reason: 'required steps cannot be skipped',
      );
    });
  });
}
