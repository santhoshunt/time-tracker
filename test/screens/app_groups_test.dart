import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/app_groups.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/app_groups_screen.dart';
import 'package:drift_time/screens/block_editor_screen.dart';
import 'package:drift_time/screens/today_screen.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/day_start_strip.dart';
import 'package:drift_time/widgets/group_style.dart';
import 'package:drift_time/widgets/score_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices s;
  late SettingsProvider settings;

  setUp(() async {
    s = await testServices(
      usage: FakeUsageSource(
        apps: [for (final a in sampleApps) {'p': a.p, 'label': a.label, 'category': a.category}],
      ),
    );
    await s.apps.upsertAll(sampleApps, testNow);
    settings = await testSettings();
  });

  tearDown(() => s.db.close());

  void phone(WidgetTester tester) {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
  }

  const work = AppGroup(
    name: 'Work apps',
    emoji: '💼',
    colorIdx: 0,
    kind: GroupKind.productive,
    apps: {'com.example.notes', 'com.example.meet'},
  );

  group('App groups page and editor', () {
    Future<void> openList(WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(withApp(s, settings, const AppGroupsScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('a new group needs a name and an app', (tester) async {
      await openList(tester);
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      expect(find.text('Pick at least one app'), findsOneWidget);
      expect(await s.groups.all(), isEmpty);
    });

    testWidgets('makes a group with an emoji, colour, kind and apps', (tester) async {
      await openList(tester);
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Time sinks');
      await tester.tap(find.byKey(const ValueKey('groupEmojiTile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-🎮')));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Coral colour'));
      await tester.tap(find.text('Distracting'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Choose apps'));
      await tester.tap(find.text('Choose apps'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('YouTube'));
      await tester.tap(find.text('Instagram'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Apps (2)'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final g = (await s.groups.all()).single;
      expect(g.name, 'Time sinks');
      expect(g.emoji, '🎮');
      expect(g.colorIdx, groupColorNames.indexOf('Coral'));
      expect(g.kind, GroupKind.distracting);
      expect(g.apps, {'com.example.video', 'com.example.social'});
      // Back on the list, as a card.
      expect(find.text('Time sinks'), findsOneWidget);
      expect(find.textContaining('2 apps'), findsOneWidget);
    });

    testWidgets('any one emoji can be typed, but not two or none', (tester) async {
      await openList(tester);
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('groupEmojiTile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ownEmoji')), '🦄🦄');
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
      expect(find.text('Type one emoji'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('ownEmoji')), '🦄');
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
      expect(find.text('🦄'), findsOneWidget);
    });

    testWidgets('a group is edited and deleted from its card', (tester) async {
      await s.groups.save(work);
      await openList(tester);
      await tester.tap(find.text('Work apps'));
      await tester.pumpAndSettle();
      expect(find.text('Edit group'), findsOneWidget);
      expect(find.text('Apps (2)'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Deep tools');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((await s.groups.all()).single.name, 'Deep tools');

      await tester.tap(find.text('Deep tools'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete group'));
      await tester.tap(find.text('Delete group'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await s.groups.all(), isEmpty);
      expect(find.text('Deep tools'), findsNothing);
    });
  });

  group('groups in the block editor', () {
    Future<void> open(WidgetTester tester, {PlanBlock? block}) async {
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDriftTheme(ThemeId.mono),
          home: BlockEditorScreen(services: s, block: block, date: testNow, startMin: 540, endMin: 720),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openPicker(WidgetTester tester, int which) async {
      final add = find.text('Add').at(which);
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
    }

    testWidgets('picking a group links it, and its apps say so', (tester) async {
      final id = await s.groups.save(work);
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'Deep work');
      await openPicker(tester, 0);
      await tester.tap(find.descendant(of: find.byType(GroupChip), matching: find.text('Work apps')));
      await tester.pumpAndSettle();
      expect(find.text('Via Work apps'), findsNWidgets(2));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // The group shows as a chip in the Allowed section.
      expect(find.widgetWithText(GroupChip, 'Work apps'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await s.groups.forBlock('Deep work'), {id: Verdict.onTrack});
      // Linked: no per-app rules were written.
      expect(await s.rules.allRules(), isEmpty);
    });

    testWidgets('a group picked as off track leaves the allowed list', (tester) async {
      final id = await s.groups.save(work);
      await s.plans.insertBlock(const PlanBlock(name: 'Deep work', startMin: 540, endMin: 720, date: '2026-10-19'));
      await s.groups.setForBlock('Deep work', {id: Verdict.onTrack});
      final block = (await s.plans.allBlocks()).single;
      await open(tester, block: block);
      await openPicker(tester, 1);
      // The sheet's chip; the block's own Allowed chip sits behind it.
      await tester.tap(find.descendant(of: find.byType(GroupChip), matching: find.text('Work apps')).last);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await s.groups.forBlock('Deep work'), {id: Verdict.offTrack});
    });

    testWidgets('a rename takes the group links along', (tester) async {
      final id = await s.groups.save(work);
      await s.plans.insertBlock(const PlanBlock(name: 'Focus', startMin: 540, endMin: 720, date: '2026-10-19'));
      await s.groups.setForBlock('Focus', {id: Verdict.onTrack});
      final block = (await s.plans.allBlocks()).single;
      await open(tester, block: block);
      await tester.enterText(find.byType(TextField).first, 'Deep work');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await s.groups.forBlock('Deep work'), {id: Verdict.onTrack});
      expect(await s.groups.forBlock('Focus'), isEmpty);
    });

    testWidgets("a new block with another block's name keeps that block's links", (tester) async {
      final id = await s.groups.save(work);
      await s.groups.setForBlock('Deep work', {id: Verdict.onTrack});
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'Deep work');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await s.groups.forBlock('Deep work'), {id: Verdict.onTrack});
    });
  });

  group('Today before the first block', () {
    Future<void> today(WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(withApp(s, settings, const Scaffold(body: TodayScreen())));
      await tester.pumpAndSettle();
    }

    testWidgets('a day planned for later shows the strip, not "Nothing planned"', (tester) async {
      // testNow is 13:30.
      await s.plans.insertBlock(const PlanBlock(name: 'Reading', startMin: 15 * 60, endMin: 16 * 60, date: '2026-10-19'));
      await s.plans.insertBlock(const PlanBlock(name: 'Gym', startMin: 18 * 60, endMin: 19 * 60, date: '2026-10-19'));
      await today(tester);
      expect(find.text('Your day starts at 15:00 with Reading'), findsOneWidget);
      expect(find.text('Nothing planned yet'), findsNothing);
      // Full width, like the lanes under it.
      expect(find.byType(DayStartStrip), findsOneWidget);
      expect(tester.getSize(find.byType(DayCard)).width, greaterThan(350));
    });

    testWidgets('a day with no blocks still invites planning, full width', (tester) async {
      await today(tester);
      expect(find.text('Nothing planned yet'), findsOneWidget);
      expect(find.byType(DayStartStrip), findsNothing);
      expect(find.byType(ScoreSummary), findsOneWidget);
      expect(tester.getSize(find.byType(DayCard)).width, greaterThan(350));
    });

    testWidgets('once a block has started the score shows', (tester) async {
      await seedSampleDay(s, testNow);
      await today(tester);
      expect(find.byType(DayStartStrip), findsNothing);
      expect(find.text('On track'), findsOneWidget);
    });

    test('firstBlockAhead picks the earliest block, and only before any starts', () {
      DateTime at(int h) => DateTime(2026, 10, 19, h);
      final later = [
        ResolvedBlock(name: 'B', start: at(18), end: at(19)),
        ResolvedBlock(name: 'A', start: at(15), end: at(16)),
      ];
      expect(firstBlockAhead(later, null, at(13))!.name, 'A');
      expect(firstBlockAhead(later, null, at(15)), isNull);
      expect(firstBlockAhead(const [], null, at(13)), isNull);
      expect(
        firstBlockAhead(later, const DayScore(plannedMin: 1, offMin: 0, idleMin: 0, noDataMin: 0, percent: 100), at(13)),
        isNull,
      );
    });
  });
}
