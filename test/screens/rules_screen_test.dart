import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/rules_screen.dart';
import 'package:drift_time/widgets/verdict_style.dart';
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
        (w) => w is Text && const {'On track', 'Neutral', 'Off track'}.contains(w.data),
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

  testWidgets('tapping a row moves it through on track, neutral and off track', (tester) async {
    await seedSampleDay(s, testNow);
    var bumps = 0;
    s.revision.addListener(() => bumps++);
    await pumpRules(tester);

    // YouTube starts off track in Deep work.
    for (final (tag, verdict) in const [
      ('On track', Verdict.onTrack),
      ('Neutral', Verdict.neutral),
      ('Off track', Verdict.offTrack),
    ]) {
      await tester.tap(find.text('YouTube'));
      await tester.pumpAndSettle();
      expect(tagOf(tester, 'YouTube'), tag);
      await tester.pump(const Duration(milliseconds: 500));
      expect((await s.rules.allRules())[('deep work', 'com.example.video')], verdict);
    }
    expect(bumps, 3);
  });

  testWidgets('quick taps bump once, after the last, and the tag never steps back', (tester) async {
    await seedSampleDay(s, testNow);
    var bumps = 0;
    s.revision.addListener(() => bumps++);
    await pumpRules(tester);

    for (final tag in const ['On track', 'Neutral', 'Off track', 'On track']) {
      // A load from elsewhere reads the rules just before the tap writes,
      // and lands after it; the tag keeps the tapped answer.
      s.bump();
      bumps--;
      await tester.tap(find.text('YouTube'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tagOf(tester, 'YouTube'), tag);
    }
    expect(bumps, 0);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(bumps, 1);
    expect(tagOf(tester, 'YouTube'), 'On track');
    expect((await s.rules.allRules())[('deep work', 'com.example.video')], Verdict.onTrack);
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

  group('Not sorted', () {
    /// The row of the guessed pair ([block], [p]) on the Not sorted tab.
    Finder unsortedRow(String block, String p) => find.byKey(ValueKey('unsorted|$block|$p'));

    Future<void> openNotSorted(WidgetTester tester) async {
      await tester.tap(find.textContaining('Not sorted'));
      await tester.pumpAndSettle();
    }

    /// The answer called [label] in [row].
    Finder answer(Finder row, String label) =>
        find.descendant(of: row, matching: find.widgetWithText(OutlinedButton, label));

    /// Friday 16 October, a weekday with the same blocks: WhatsApp again in
    /// Deep work (a pair today also has) and Spotify in Deep work (a pair
    /// only this day has).
    Future<void> seedFriday() async {
      final d = DateTime(2026, 10, 16);
      DateTime at(int h, int m) => DateTime(d.year, d.month, d.day, h, m);
      await s.sessions.replaceDay(
        d,
        DateTime(d.year, d.month, d.day + 1),
        [
          Session(p: 'com.example.music', start: at(9, 30), end: at(9, 45)),
          Session(p: 'com.example.chat', start: at(10, 0), end: at(10, 15)),
        ],
        const [],
      );
    }

    testWidgets('the tabs show with the count of guessed pairs', (tester) async {
      await seedSampleDay(s, testNow);
      await pumpRules(tester);

      expect(find.text('Sorted'), findsOneWidget);
      // WhatsApp in Deep work and Spotify in Gym have only a guess.
      expect(find.text('Not sorted (2)'), findsOneWidget);
    });

    testWidgets('On track writes an on rule, removes the row and lists it under Sorted', (tester) async {
      await seedSampleDay(s, testNow);
      var bumps = 0;
      s.revision.addListener(() => bumps++);
      await pumpRules(tester);
      await openNotSorted(tester);

      final row = unsortedRow('deep work', 'com.example.chat');
      expect(find.descendant(of: row, matching: find.text('Guessed off track')), findsOneWidget);
      // The guess, off track, is the dashed answer.
      bool dashed(String label) => find
          .ancestor(of: answer(row, label), matching: find.byType(CustomPaint))
          .evaluate()
          .any((e) => (e.widget as CustomPaint).foregroundPainter is DashedBorderPainter);
      expect(dashed('Off track'), isTrue);
      expect(dashed('On track'), isFalse);
      expect(dashed('Neutral'), isFalse);
      await tester.tap(answer(row, 'On track'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect((await s.rules.allRules())[('deep work', 'com.example.chat')], Verdict.onTrack);
      expect(bumps, 1);
      expect(row, findsNothing);
      expect(find.text('Not sorted (1)'), findsOneWidget);
      expect(find.text('WhatsApp counts as on track in Deep work'), findsOneWidget);

      await tester.tap(find.text('Sorted'));
      await tester.pumpAndSettle();
      expect(tagOf(tester, 'WhatsApp'), 'On track');
    });

    testWidgets('Off track writes an off rule', (tester) async {
      await seedSampleDay(s, testNow);
      await pumpRules(tester);
      await openNotSorted(tester);

      final row = unsortedRow('gym', 'com.example.music');
      await tester.tap(answer(row, 'Off track'));
      await tester.pumpAndSettle();

      expect((await s.rules.allRules())[('gym', 'com.example.music')], Verdict.offTrack);
      expect(row, findsNothing);
      expect(find.text('Spotify counts as off track in Gym'), findsOneWidget);
      expect(find.text('Not sorted (1)'), findsOneWidget);
    });

    testWidgets('Neutral writes a neutral rule that Sorted tags grey', (tester) async {
      await seedSampleDay(s, testNow);
      await pumpRules(tester);
      await openNotSorted(tester);

      await tester.tap(answer(unsortedRow('deep work', 'com.example.chat'), 'Neutral'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));

      expect((await s.rules.allRules())[('deep work', 'com.example.chat')], Verdict.neutral);
      expect(find.text('WhatsApp counts as neutral in Deep work'), findsOneWidget);
      await tester.tap(find.text('Sorted'));
      await tester.pumpAndSettle();
      expect(tagOf(tester, 'WhatsApp'), 'Neutral');
    });

    testWidgets('a pair used on several days shows once, under its block, newest first', (
      tester,
    ) async {
      await seedSampleDay(s, testNow);
      await seedFriday();
      await pumpRules(tester);

      expect(find.text('Not sorted (3)'), findsOneWidget);
      await openNotSorted(tester);

      expect(find.text('WhatsApp'), findsOneWidget);
      // Deep work was used last, so its heading comes first; Spotify from
      // Friday sits under it, above the Gym heading.
      final ys = [
        for (final r in [
          find.text('Deep work'),
          unsortedRow('deep work', 'com.example.chat'),
          unsortedRow('deep work', 'com.example.music'),
          find.text('Gym'),
          unsortedRow('gym', 'com.example.music'),
        ])
          tester.getTopLeft(r).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      // Spotify waits in two blocks, once under each heading.
      expect(find.text('Spotify'), findsNWidgets(2));
    });

    testWidgets('the count it shows is the one the Settings badge reads', (tester) async {
      await seedSampleDay(s, testNow);
      await seedFriday();
      await pumpRules(tester);
      expect(s.toSort.value, 3);

      await openNotSorted(tester);
      await tester.tap(answer(unsortedRow('gym', 'com.example.music'), 'Off track'));
      await tester.pumpAndSettle();
      expect(s.toSort.value, 2);
    });

    testWidgets('a rule stored elsewhere drops the row on the next revision', (tester) async {
      await seedSampleDay(s, testNow);
      await pumpRules(tester);
      await openNotSorted(tester);

      await s.rules.upsertRule('Gym', 'com.example.music', Verdict.onTrack, testNow);
      s.bump();
      await tester.pumpAndSettle();

      expect(unsortedRow('gym', 'com.example.music'), findsNothing);
      expect(find.text('Not sorted (1)'), findsOneWidget);
    });

    testWidgets('shows an empty state when nothing waits', (tester) async {
      await pumpRules(tester);

      expect(find.text('Not sorted'), findsOneWidget);
      await openNotSorted(tester);
      expect(
        find.text('Nothing waiting. Drift asks about new apps as you use them.'),
        findsOneWidget,
      );
    });
  });
}
