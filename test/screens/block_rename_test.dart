import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/plan_resolver.dart';
import 'package:drift_time/screens/block_editor_screen.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/services/unsorted_loader.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// Renaming a block on every day must keep the answers of the days that
/// already ended, which look the block up by the name they were frozen
/// with.
void main() {
  late AppServices s;
  final friday = DateTime(2026, 10, 16);

  setUp(() async {
    s = await testServices();
    await s.apps.upsertAll(sampleApps, testNow);
    await s.plans.insertBlock(
      const PlanBlock(name: 'Focus', startMin: 9 * 60, endMin: 12 * 60, repeatMask: PlanBlock.weekdays),
    );
    await s.plans.freezePlan(friday, encodeFrozenPlan(activeBlocks(friday, await s.plans.allBlocks())));
    await s.sessions.replaceDay(
      friday,
      DateTime(2026, 10, 17),
      [Session(p: 'com.example.video', start: DateTime(2026, 10, 16, 10), end: DateTime(2026, 10, 16, 10, 30))],
      const [],
    );
    await s.rules.upsertRule('Focus', 'com.example.video', Verdict.offTrack, testNow);
  });

  tearDown(() => s.db.close());

  Future<void> rename(WidgetTester tester, String name, {required bool everyDay}) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    final block = (await s.plans.allBlocks()).single;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDriftTheme(ThemeId.mono),
        home: BlockEditorScreen(services: s, block: block, date: testNow, startMin: 540, endMin: 720),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, name);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.tap(
      everyDay
          ? find.descendant(of: dialog, matching: find.byType(FilledButton))
          : find.descendant(of: dialog, matching: find.text('This day only')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a rename on every day carries the answers into the past days', (tester) async {
    expect(await loadUnsorted(s), isEmpty);

    await rename(tester, 'Deep work', everyDay: true);

    final day = await loadDay(s, friday);
    expect(day.blocks.single.name, 'Deep work');
    expect(day.segments.where((x) => x.p == 'com.example.video').single.verdict, Verdict.offTrack);
    expect(await loadUnsorted(s), isEmpty);
    final rules = await s.rules.allRules();
    expect(rules[('deep work', 'com.example.video')], Verdict.offTrack);
    expect(rules.containsKey(('focus', 'com.example.video')), isFalse);
  });

  testWidgets('"This day only" leaves the past days and their answers alone', (tester) async {
    await rename(tester, 'Deep work', everyDay: false);

    final day = await loadDay(s, friday);
    expect(day.blocks.single.name, 'Focus');
    expect(day.segments.where((x) => x.p == 'com.example.video').single.verdict, Verdict.offTrack);
    expect((await s.rules.allRules())[('focus', 'com.example.video')], Verdict.offTrack);
  });

  testWidgets('a save keeps the neutral answers the editor has no list for', (tester) async {
    await s.rules.upsertRule('Focus', 'com.example.chat', Verdict.neutral, testNow);
    // A rename on every day goes through the same write as a plain save,
    // and moves the neutral answer with the block.
    await rename(tester, 'Deep work', everyDay: true);
    final rules = await s.rules.allRules();
    expect(rules[('deep work', 'com.example.chat')], Verdict.neutral);
    expect(rules[('deep work', 'com.example.video')], Verdict.offTrack);
    expect(rules.containsKey(('focus', 'com.example.chat')), isFalse);
  });

  test('renameInFrozen changes only the block with that id and old name', () async {
    final focus = (await s.plans.allBlocks()).single;
    final other = PlanBlock(id: focus.id! + 1, name: 'Focus', startMin: 13 * 60, endMin: 14 * 60);
    final thursday = DateTime(2026, 10, 15);
    await s.plans.freezePlan(thursday, encodeFrozenPlan([focus, other]));
    // A deleted block's history under a reused id keeps its own name.
    final wednesday = DateTime(2026, 10, 14);
    await s.plans.freezePlan(
      wednesday,
      encodeFrozenPlan([PlanBlock(id: focus.id, name: 'Reading', startMin: 9 * 60, endMin: 10 * 60)]),
    );

    await s.plans.renameInFrozen(focus.id!, 'focus ', 'Deep work');

    List<String> names(String? json) => [for (final b in decodeFrozenPlan(json!)!) b.name];
    expect(names(await s.plans.frozenPlan(thursday)), ['Deep work', 'Focus']);
    expect(names(await s.plans.frozenPlan(friday)), ['Deep work']);
    expect(names(await s.plans.frozenPlan(wednesday)), ['Reading']);
  });
}
