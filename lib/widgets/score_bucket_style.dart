import 'package:flutter/material.dart';

import '../services/review_summary.dart';
import '../theme/drift_theme.dart';

/// How strongly the fair and poor buckets tint their cell.
const _lowStrength = 0.30;

/// The fill for a heatmap cell or year tile. Opaque, so the text colour
/// from [bucketInk] reads the same on every card.
///
/// - good (75% and up): solid on-track.
/// - fair (60 to 74%): on-track at low strength.
/// - poor (under 60%): off-track at low strength.
/// - none (no data, nothing planned, still ahead): the card itself.
Color bucketFill(DriftColors c, ScoreBucket b) => switch (b) {
  ScoreBucket.good => c.onTrack,
  ScoreBucket.fair =>
    Color.alphaBlend(c.onTrack.withValues(alpha: _lowStrength), c.card),
  ScoreBucket.poor =>
    Color.alphaBlend(c.offTrack.withValues(alpha: _lowStrength), c.card),
  ScoreBucket.none => c.card,
};

/// Text on a [bucketFill]: the background colour on the solid fill, the
/// text colour on the tinted ones, secondary text on the bare card. Never
/// a coloured token, so no coloured text sits on a coloured fill.
Color bucketInk(DriftColors c, ScoreBucket b) => switch (b) {
  ScoreBucket.good => c.bg,
  ScoreBucket.fair || ScoreBucket.poor => c.text,
  ScoreBucket.none => c.textSecondary,
};

/// The colour a score change is written in: on-track when it went up,
/// off-track when it went down, secondary when equal or unknown. Only for
/// text on the neutral card.
Color deltaColor(DriftColors c, int? delta) {
  if (delta == null || delta == 0) return c.textSecondary;
  return delta > 0 ? c.onTrack : c.offTrack;
}

/// One legend entry: a small rounded swatch and its words.
class LegendItem {
  const LegendItem(this.label, this.fill, {this.border});

  final String label;
  final Color fill;
  final Color? border;
}

/// A wrapping row of [LegendItem]s in secondary text.
class ReviewLegend extends StatelessWidget {
  const ReviewLegend({super.key, required this.items});

  final List<LegendItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: c.textSecondary);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final item in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: item.fill,
                  borderRadius: BorderRadius.circular(3),
                  border: item.border == null
                      ? null
                      : Border.all(color: item.border!),
                ),
              ),
              const SizedBox(width: 6),
              Text(item.label, style: style),
            ],
          ),
      ],
    );
  }
}
