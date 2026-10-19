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

/// Two system-ish apps the phone flips between for a second at a time.
const _sliverApps = [
  AppInfo(p: 'com.example.keyboard', label: 'Keyboard', category: 'undefined'),
  AppInfo(p: 'com.example.launcher', label: 'Launcher', category: 'social'),
];

void main() {
  setUpAll(loadDriftFonts);

  testWidgets('today lanes with 300 one-second slivers, mono', (tester) async {
    // 12:20, so the view opens at 10:50 and shows the slivers at 11:10.
    final now = DateTime(2026, 10, 19, 12, 20);
    final s = await testServices(now: now);
    final settings = await testSettings(theme: ThemeId.mono);
    final d = DateTime(now.year, now.month, now.day);
    DateTime at(int h, int m, [int sec = 0]) =>
        DateTime(d.year, d.month, d.day, h, m, sec);

    await s.apps.upsertAll([...sampleApps, ..._sliverApps], d);
    for (final b in samplePlan) {
      await s.plans.insertBlock(b);
    }
    await s.rules.upsertRule('Deep work', 'com.example.notes', Verdict.onTrack, d);
    await s.rules.upsertRule('Deep work', 'com.example.video', Verdict.offTrack, d);
    await s.rules.upsertRule('Deep work', 'com.example.social', Verdict.offTrack, d);

    // The sample morning, with 300 back-to-back one-second sessions
    // between Notes and YouTube, 11:10:00 to 11:15:00.
    await s.sessions.replaceDay(
      d,
      DateTime(d.year, d.month, d.day + 1),
      [
        Session(p: 'com.example.music', start: at(8, 10), end: at(8, 50)),
        Session(p: 'com.example.notes', start: at(9, 5), end: at(9, 35)),
        Session(p: 'com.example.social', start: at(9, 40), end: at(10, 5)),
        Session(p: 'com.example.chat', start: at(10, 15), end: at(10, 24)),
        Session(p: 'com.example.notes', start: at(10, 30), end: at(11, 10)),
        for (var i = 0; i < 300; i++)
          Session(
            p: _sliverApps[i % 2].p,
            start: at(11, 10, i),
            end: at(11, 10, i + 1),
          ),
        Session(p: 'com.example.video', start: at(11, 15), end: at(11, 50)),
        Session(p: 'com.example.video', start: at(12, 10), end: at(12, 40)),
      ],
      [
        IdleSpan(at(7, 0), at(8, 10), IdleKind.screenOff),
        IdleSpan(at(11, 50), at(12, 10), IdleKind.locked),
      ],
    );

    await pumpGolden(
      tester,
      withProviders(
        s,
        settings,
        Scaffold(
          body: const TodayScreen(),
          bottomNavigationBar: NavigationBar(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.schedule_outlined), label: 'Today'),
              NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Plan'),
              NavigationDestination(icon: Icon(Icons.bar_chart_outlined), label: 'Review'),
              NavigationDestination(icon: Icon(Icons.donut_large_outlined), label: 'Usage'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
            ],
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/today_lanes_slivers_mono.png'),
    );
    await s.db.close();
  });
}
