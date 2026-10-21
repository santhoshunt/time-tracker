import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/review_summary.dart';
import '../services/streak_loader.dart';
import '../theme/drift_theme.dart';

/// "5-day streak", "1-day streak", or "No streak yet".
String streakLabel(int days) =>
    days <= 0 ? 'No streak yet' : '$days-day streak';

/// The week as one row at the bottom of Today's DayCard: one dot per day
/// coloured by its score, then the week's score against the weekly target
/// (when one is set) over the run of good days.
class WeekRow extends StatelessWidget {
  const WeekRow({
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
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Row(
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
        ),
        const SizedBox(width: 12),
        // A fixed share, so large text wraps instead of pushing the dots
        // off, and the words sit against the card's right edge.
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (target > 0 && percent != null)
                Text(
                  '$percent% of $target% target',
                  textAlign: TextAlign.end,
                  style: text.bodySmall?.copyWith(color: c.text),
                ),
              Text(
                streakLabel(progress.streak),
                textAlign: TextAlign.end,
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      ],
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
