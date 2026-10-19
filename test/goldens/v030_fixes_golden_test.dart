@Tags(['golden'])
library;

import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/score_card.dart';
import 'package:drift_time/widgets/time_wheel.dart';
import 'package:drift_time/widgets/undo_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';

void main() {
  setUpAll(loadDriftFonts);

  for (final theme in [ThemeId.mono, ThemeId.blackCyan, ThemeId.cleanLight]) {
    testWidgets('toast, ${theme.key}', (tester) async {
      await pumpGolden(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showAppToast(
                  context,
                  "You're on the latest version (v0.3.0).",
                  tone: AppToastTone.success,
                  icon: Icons.verified_outlined,
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
        theme: theme,
        size: const Size(393, 300),
      );
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/toast_${theme.key}.png'));
    });
  }

  testWidgets('empty score card, small screen with large text', (tester) async {
    await pumpGolden(
      tester,
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ScoreCard(score: null, onPlan: () {}),
        ),
      ),
      size: const Size(320, 260),
      textScale: 1.3,
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/score_card_empty_mono_small_1_3.png'));
  });

  testWidgets('quiet hours sheet', (tester) async {
    await pumpGolden(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showQuietHoursSheet(context, start: 22 * 60, end: 7 * 60),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
      theme: ThemeId.blackCyan,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/quiet_hours_sheet_blackCyan.png'));
  });
}
