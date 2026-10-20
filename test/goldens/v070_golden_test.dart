@Tags(['golden'])
library;

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/app_groups.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/screens/app_groups_screen.dart';
import 'package:drift_time/screens/block_editor_screen.dart';
import 'package:drift_time/screens/group_editor_screen.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// Golden images bundle only Roboto, so a real emoji would draw as a box;
/// these groups use a letter in the emoji's place. The phone draws emoji.
const _groups = [
  AppGroup(name: 'Work apps', emoji: 'W', colorIdx: 0, kind: GroupKind.productive, apps: {'com.example.notes', 'com.example.meet'}),
  AppGroup(name: 'Time sinks', emoji: 'T', colorIdx: 4, kind: GroupKind.distracting, apps: {'com.example.video', 'com.example.social', 'com.example.chat'}),
  AppGroup(name: 'Study', emoji: 'S', colorIdx: 2, kind: GroupKind.productive, apps: {'com.example.notes'}),
];

Future<AppServices> _withGroups() async {
  final s = await testServices();
  await s.apps.upsertAll(sampleApps, testNow);
  for (final g in _groups) {
    await s.groups.save(g);
  }
  return s;
}

void main() {
  setUpAll(loadDriftFonts);

  for (final theme in [ThemeId.mono, ThemeId.blackCyan]) {
    testWidgets('app groups list, ${theme.key}', (tester) async {
      final s = await _withGroups();
      final settings = await testSettings(theme: theme);
      await pumpGolden(tester, withProviders(s, settings, const AppGroupsScreen()), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/app_groups_${theme.key}.png'));
      await s.db.close();
    });
  }

  testWidgets('group editor, mono', (tester) async {
    final s = await _withGroups();
    final settings = await testSettings();
    final group = (await s.groups.all()).firstWhere((g) => g.name == 'Time sinks');
    await pumpGolden(tester, withProviders(s, settings, GroupEditorScreen(group: group)));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/group_editor_mono.png'));
    await s.db.close();
  });

  testWidgets('app picker with groups, blackCyan', (tester) async {
    final s = await _withGroups();
    final settings = await testSettings(theme: ThemeId.blackCyan);
    final groups = await s.groups.all();
    await pumpGolden(
      tester,
      withProviders(
        s,
        settings,
        Scaffold(
          body: AppPickerSheet(
            title: 'Allowed apps',
            apps: sampleApps,
            selected: const {'com.example.music'},
            otherSelected: const {},
            otherLabel: 'In off-track apps',
            iconFor: (_) async => null,
            onChanged: (_, _) {},
            groups: groups,
            selectedGroups: {groups.first.id!},
          ),
        ),
      ),
      theme: ThemeId.blackCyan,
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/app_picker_groups_blackCyan.png'));
    await s.db.close();
  });

  for (final theme in [ThemeId.mono, ThemeId.blackCyan]) {
    testWidgets('today before the first block, ${theme.key}', (tester) async {
      final s = await testServices();
      for (final b in const [
        PlanBlock(name: 'Work', startMin: 15 * 60, endMin: 17 * 60, date: '2026-10-19'),
        PlanBlock(name: 'Break', startMin: 17 * 60, endMin: 18 * 60, date: '2026-10-19'),
      ]) {
        await s.plans.insertBlock(b);
      }
      final settings = await testSettings(theme: theme);
      await pumpGolden(tester, withProviders(s, settings, const Scaffold(body: TodayScreen())), theme: theme);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/today_before_first_${theme.key}.png'));
      await s.db.close();
    });
  }
}
