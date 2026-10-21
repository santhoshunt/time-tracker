@Tags(['golden'])
library;

import 'package:drift_time/services/review_summary.dart';
import 'package:drift_time/services/streak_loader.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/score_card.dart';
import 'package:drift_time/widgets/week_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';

/// Today with nothing planned for today but a plan earlier in the week:
/// the plan invitation and the week share one card.
void main() {
  setUpAll(loadDriftFonts);

  final wednesday = DateTime(2026, 10, 21);
  DayPoint point(int day, int? percent) => DayPoint(
    day: DateTime(2026, 10, day),
    percent: percent,
    plannedMin: percent == null ? 0 : 300,
    fullPlannedMin: percent == null ? 0 : 300,
    onMin: percent == null ? 0 : 3 * percent,
    idleMin: 0,
    offMin: percent == null ? 0 : 300 - 3 * percent,
    noDataMin: 0,
  );
  final week = WeekProgress(
    week: [point(19, null), point(20, 83), for (var d = 21; d <= 25; d++) point(d, null)],
    weekPercent: 83,
    streak: 1,
  );

  for (final theme in [ThemeId.mono, ThemeId.cleanLight]) {
    testWidgets('day card, nothing planned today, ${theme.key}', (tester) async {
      await pumpGolden(
        tester,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: DayCard(
              top: ScoreSummary(score: null, onPlan: () {}),
              week: WeekRow(progress: week, target: 80, today: wednesday),
            ),
          ),
        ),
        theme: theme,
        size: const Size(393, 200),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/day_card_unplanned_${theme.key}.png'),
      );
    });
  }
}
