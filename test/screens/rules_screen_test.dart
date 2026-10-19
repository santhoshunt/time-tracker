import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/rules_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices s;
  late SettingsProvider settings;

  setUp(() async {
    s = await testServices();
    settings = await testSettings();
  });

  tearDown(() => s.db.close());

  Future<void> pumpRules(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(withApp(s, settings, const RulesScreen()));
    await tester.pumpAndSettle();
  }

  /// The tag text in the row of the app called [label].
  String tagOf(WidgetTester tester, String label) {
    final row = find.ancestor(of: find.text(label), matching: find.byType(Dismissible));
    final tags = find.descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (w) => w is Text && (w.data == 'On track' || w.data == 'Off track'),
      ),
    );
    return (tester.widget<Text>(tags).data)!;
  }

  testWidgets('groups rules by block name, sorted, with the block spelling', (tester) async {
    await seedSampleDay(s, testNow);
    // A key with no block left falls back to a capitalised key.
    await s.rules.upsertRule('reading', 'com.example.notes', Verdict.onTrack, testNow);
    await pumpRules(tester);

    expect(find.text('Learned rules'), findsOneWidget);
    final headers = ['Deep work', 'Meetings', 'Reading'];
    final ys = [for (final h in headers) tester.getTopLeft(find.text(h)).dy];
    expect(ys, orderedEquals([...ys]..sort()));

    // Rows inside Deep work are sorted by app label.
    final rows = ['Instagram', 'Notes', 'YouTube'];
    final rowYs = [
      for (final r in rows)
        tester.getTopLeft(find.text(r).first).dy,
    ];
    expect(rowYs, orderedEquals([...rowYs]..sort()));
    expect(rowYs.last, lessThan(tester.getTopLeft(find.text('Meetings')).dy));

    expect(tagOf(tester, 'Instagram'), 'Off track');
    expect(tagOf(tester, 'Zoom'), 'On track');
  });

  testWidgets('tapping a row switches it between on and off track', (tester) async {
    await seedSampleDay(s, testNow);
    var bumps = 0;
    s.revision.addListener(() => bumps++);
    await pumpRules(tester);

    await tester.tap(find.text('YouTube'));
    await tester.pumpAndSettle();
    expect(tagOf(tester, 'YouTube'), 'On track');
    expect((await s.rules.allRules())[('deep work', 'com.example.video')], Verdict.onTrack);

    await tester.tap(find.text('YouTube'));
    await tester.pumpAndSettle();
    expect(tagOf(tester, 'YouTube'), 'Off track');
    expect((await s.rules.allRules())[('deep work', 'com.example.video')], Verdict.offTrack);
    expect(bumps, 2);
  });

  testWidgets('swiping forgets a rule and Undo restores it', (tester) async {
    await seedSampleDay(s, testNow);
    await pumpRules(tester);

    await tester.drag(find.text('Zoom'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('Zoom'), findsNothing);
    // Meetings had only Zoom, so its group goes too.
    expect(find.text('Meetings'), findsNothing);
    expect((await s.rules.allRules()).containsKey(('meetings', 'com.example.meet')), isFalse);
    expect(find.text('Forgot Zoom in Meetings'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('Zoom'), findsOneWidget);
    expect(find.text('Meetings'), findsOneWidget);
    expect(tagOf(tester, 'Zoom'), 'On track');
    expect((await s.rules.allRules())[('meetings', 'com.example.meet')], Verdict.onTrack);
  });

  testWidgets('shows an empty state with no rules', (tester) async {
    await pumpRules(tester);

    expect(
      find.text(
        'Nothing learned yet. Answer a question on the Today tab, or add apps to a block.',
      ),
      findsOneWidget,
    );
    expect(find.byType(Dismissible), findsNothing);
  });
}
