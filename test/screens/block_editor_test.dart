import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/screens/block_editor_screen.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// Monday 2026-10-19.
final _monday = DateTime(2026, 10, 19);

Future<void> _open(
  WidgetTester tester,
  AppServices s, {
  PlanBlock? block,
  int? startMin,
  int? endMin,
  DateTime? date,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(393, 851) * 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDriftTheme(ThemeId.mono),
      home: BlockEditorScreen(
        services: s,
        block: block,
        date: date ?? _monday,
        startMin: startMin,
        endMin: endMin,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

/// Opens the app picker under the [which]th "Add" chip (0 allowed, 1 off
/// track), ticks [labels] and closes it.
Future<void> _pick(WidgetTester tester, int which, List<String> labels) async {
  final add = find.text('Add').at(which);
  await tester.ensureVisible(add);
  await tester.pumpAndSettle();
  await tester.tap(add);
  await tester.pumpAndSettle();
  for (final l in labels) {
    await tester.tap(find.descendant(of: find.byType(ListTile), matching: find.text(l)));
    await tester.pump();
  }
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

void main() {
  late AppServices s;

  setUp(() async {
    s = await testServices(
      usage: FakeUsageSource(
        apps: [
          for (final a in sampleApps) {'p': a.p, 'label': a.label, 'category': a.category},
        ],
      ),
    );
    await s.apps.upsertAll(sampleApps, _monday);
  });

  tearDown(() => s.db.close());

  testWidgets('a name is required', (tester) async {
    await _open(tester, s);
    await _save(tester);
    expect(find.text('Enter a name'), findsOneWidget);
    expect(await s.plans.allBlocks(), isEmpty);
  });

  testWidgets('the end must come after the start', (tester) async {
    await _open(tester, s, startMin: 600, endMin: 540);
    await tester.enterText(find.byType(TextField).first, 'Reading');
    await _save(tester);
    expect(find.text('End must be after start'), findsOneWidget);
    expect(await s.plans.allBlocks(), isEmpty);
  });

  testWidgets('an overlap warns but still saves', (tester) async {
    await s.plans.insertBlock(
      const PlanBlock(name: 'Deep work', startMin: 540, endMin: 720, date: '2026-10-19'),
    );
    await _open(tester, s, startMin: 600, endMin: 660);
    expect(find.textContaining('Overlaps'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Call');
    await _save(tester);
    expect((await s.plans.allBlocks()).map((b) => b.name), containsAll(['Deep work', 'Call']));
  });

  testWidgets('no repeat days makes a one-off on the shown day', (tester) async {
    await _open(tester, s, startMin: 1200, endMin: 1260);
    await tester.enterText(find.byType(TextField).first, 'Reading');
    await _save(tester);
    final b = (await s.plans.allBlocks()).single;
    expect((b.repeatMask, b.date, b.startMin, b.endMin), (0, '2026-10-19', 1200, 1260));
  });

  testWidgets('repeat days build the weekday mask', (tester) async {
    await _open(tester, s, startMin: 480, endMin: 540);
    await tester.enterText(find.byType(TextField).first, 'Gym');
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(ValueKey('repeatDay$i')));
      await tester.pump();
    }
    await _save(tester);
    final b = (await s.plans.allBlocks()).single;
    expect(b.repeatMask, PlanBlock.weekdays);
    expect(b.date, isNull);
  });

  testWidgets('allowed and off-track apps become rules for the block', (tester) async {
    await _open(tester, s, startMin: 540, endMin: 720);
    await tester.enterText(find.byType(TextField).first, 'Deep work');
    await _pick(tester, 0, ['Notes']);
    await _pick(tester, 1, ['YouTube', 'Instagram']);
    await _save(tester);
    final rules = await s.rules.allRules();
    expect(rules[('deep work', 'com.example.notes')], Verdict.onTrack);
    expect(rules[('deep work', 'com.example.video')], Verdict.offTrack);
    expect(rules[('deep work', 'com.example.social')], Verdict.offTrack);
  });

  testWidgets('renaming a block moves its rules to the new name', (tester) async {
    final id = await s.plans.insertBlock(
      const PlanBlock(name: 'Focus', startMin: 540, endMin: 720, date: '2026-10-19'),
    );
    await s.rules.upsertRule('Focus', 'com.example.video', Verdict.offTrack, _monday);
    final block = (await s.plans.allBlocks()).firstWhere((b) => b.id == id);
    await _open(tester, s, block: block);
    await tester.enterText(find.byType(TextField).first, 'Deep work');
    await _save(tester);
    final rules = await s.rules.allRules();
    expect(rules[('deep work', 'com.example.video')], Verdict.offTrack);
    expect(rules.containsKey(('focus', 'com.example.video')), isFalse);
  });

  testWidgets('"This day only" on a repeating block splits off one day', (tester) async {
    final id = await s.plans.insertBlock(
      const PlanBlock(name: 'Gym', startMin: 480, endMin: 540, repeatMask: PlanBlock.weekdays),
    );
    final block = (await s.plans.allBlocks()).firstWhere((b) => b.id == id);
    await _open(tester, s, block: block, date: DateTime(2026, 10, 20));
    await tester.enterText(find.byType(TextField).first, 'Run');
    await _save(tester);
    await tester.tap(find.text('This day only'));
    await tester.pumpAndSettle();

    final all = await s.plans.allBlocks();
    final original = all.firstWhere((b) => b.id == id);
    expect(original.name, 'Gym');
    expect(original.skipDates, ['2026-10-20']);
    final oneOff = all.firstWhere((b) => b.id != id);
    expect((oneOff.name, oneOff.repeatMask, oneOff.date), ('Run', 0, '2026-10-20'));
  });

  testWidgets('the app picker says so when no apps are known', (tester) async {
    await s.db.close();
    s = await testServices(usage: FakeUsageSource());
    await _open(tester, s);
    await tester.ensureVisible(find.text('Add').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add').first);
    await tester.pumpAndSettle();
    expect(find.text('No apps found. Check that Usage access is on.'), findsOneWidget);
  });
}
