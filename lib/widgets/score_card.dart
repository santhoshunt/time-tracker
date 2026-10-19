import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme/drift_theme.dart';

/// Minutes as "1 h 25 min", "45 min" or "2 h".
String formatMinutes(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The day's verdict in one card: the on-track share, how much drifted
/// and how much was planned. With nothing planned it invites planning.
class ScoreCard extends StatelessWidget {
  const ScoreCard({super.key, required this.score, this.onPlan});

  final DayScore? score;

  /// Opens the Plan tab; shown only when nothing is planned.
  final VoidCallback? onPlan;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final s = score;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: s == null
            ? Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Nothing planned yet', style: text.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          'Lay out your day to see where it drifts.',
                          style: text.bodySmall?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onPlan != null)
                    FilledButton(
                      onPressed: onPlan,
                      child: const Text('Plan today'),
                    ),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'On track',
                        style: text.bodySmall?.copyWith(color: c.textSecondary),
                      ),
                      Text(
                        '${s.percent}%',
                        style: text.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  // Flexible so large text wraps instead of overflowing on
                  // narrow phones.
                  Expanded(
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _Pill(
                        text: s.offMin == 0
                            ? 'No drift'
                            : '${formatMinutes(s.offMin)} drift',
                        color: s.offMin == 0 ? c.onTrack : c.offTrack,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'of ${formatMinutes(s.plannedMin)} planned so far',
                        textAlign: TextAlign.end,
                        style: text.bodySmall?.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// An outlined pill: coloured border and text on the card, never coloured
/// text on a coloured fill.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.6)),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
    ),
  );
}
