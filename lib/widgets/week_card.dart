import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/review_summary.dart';
import '../services/streak_loader.dart';
import '../theme/drift_theme.dart';

/// "5-day streak", "1-day streak", or "No streak yet".
String streakLabel(int days) =>
    days <= 0 ? 'No streak yet' : '$days-day streak';

/// Today's "This week" card (streak option B, target option A): one dot
/// per day coloured by its score, the run of good days, and the week's
/// score against the weekly target when one is set.
class WeekCard extends StatelessWidget {
  const WeekCard({
    super.key,
    required this.progress,
    required this.target,
    required this.today,
  });

  final WeekProgress progress;

  /// The weekly target percent, or 0 when it is off.
  final int target;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final small = text.labelSmall?.copyWith(color: c.textSecondary);
    final percent = progress.weekPercent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('This week', style: text.titleSmall)),
                Text(
                  streakLabel(progress.streak),
                  style: text.bodySmall?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final p in progress.week)
                  Expanded(
                    child: Column(
                      children: [
                        _Dot(point: p, today: today),
                        const SizedBox(height: 2),
                        Text(
                          DateFormat('EEEEE').format(p.day),
                          maxLines: 1,
                          style: small?.copyWith(
                            color: p.day == today ? c.text : c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            // One line, the bar beside its words, so the card leaves the
            // lanes below as much room as it can.
            if (target > 0 && percent != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _TargetBar(percent: percent, target: target)),
                  const SizedBox(width: 12),
                  Text(
                    '$percent% of $target% target',
                    style: text.bodySmall?.copyWith(color: c.text),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.point, required this.today});

  final DayPoint point;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final ahead = point.day.isAfter(today);
    final fill = ahead
        ? c.line.withValues(alpha: 0.5)
        : switch (bucketOf(point.percent)) {
            ScoreBucket.good => c.onTrack,
            ScoreBucket.fair => c.guessed,
            ScoreBucket.poor => c.offTrack,
            ScoreBucket.none => c.line,
          };
    final isToday = point.day == today;
    final label = DateFormat('EEEE').format(point.day);
    return Semantics(
      label: ahead || point.percent == null
          ? '$label, no score'
          : '$label, ${point.percent}%',
      excludeSemantics: true,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isToday && point.percent == null ? null : fill,
          border: isToday ? Border.all(color: c.accent, width: 2) : null,
        ),
      ),
    );
  }
}

/// The week's score as a bar with a tick at the target: on-track once the
/// target is met, the guessed colour while short of it.
class _TargetBar extends StatelessWidget {
  const _TargetBar({required this.percent, required this.target});

  final int percent;
  final int target;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final met = percent >= target;
    return Semantics(
      label: met
          ? 'Weekly target met: $percent% of $target%'
          : 'Weekly target: $percent% of $target%',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          return SizedBox(
            height: 14,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 3,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.line,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  width: w * percent.clamp(0, 100) / 100,
                  top: 3,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: met ? c.onTrack : c.guessed,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned(
                  left: (w * target / 100 - 1).clamp(0.0, w - 2),
                  width: 2,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: c.text),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
