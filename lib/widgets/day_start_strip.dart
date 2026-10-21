import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/models.dart';
import '../theme/drift_theme.dart';

/// Today before the first block starts, the top of DayCard: one line
/// saying when the day begins, so a planned morning never reads as
/// "Nothing planned yet" and the lanes keep their room.
class DayStartStrip extends StatelessWidget {
  const DayStartStrip({super.key, required this.first});

  /// The day's first block that has not started yet.
  final ResolvedBlock first;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final at = DateFormat('HH:mm').format(first.start);
    return Row(
      children: [
        Icon(Icons.schedule, size: 18, color: c.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Your day starts at $at with ${first.name}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(color: c.text),
          ),
        ),
      ],
    );
  }
}

/// The block the strip names: the earliest that starts after [now], when
/// none has started yet and nothing planned has been scored. Null means
/// show the score card (or its empty state) instead.
ResolvedBlock? firstBlockAhead(List<ResolvedBlock> blocks, DayScore? score, DateTime now) {
  if (score != null || blocks.isEmpty) return null;
  if (blocks.any((b) => !b.start.isAfter(now))) return null;
  final ahead = [...blocks]..sort((a, b) => a.start.compareTo(b.start));
  return ahead.first;
}
