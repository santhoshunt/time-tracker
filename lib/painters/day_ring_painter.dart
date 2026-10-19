import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme/drift_theme.dart';
import '../widgets/verdict_style.dart';

/// Today option B: the whole day as a clock face. The outer ring is the
/// plan, the inner ring is what happened, midnight at the top and noon at
/// the bottom.
class DayRingPainter extends CustomPainter {
  const DayRingPainter({
    required this.day,
    required this.blocks,
    required this.segments,
    required this.now,
    required this.colors,
  });

  final DateTime day;
  final List<ResolvedBlock> blocks;
  final List<Segment> segments;
  final DateTime now;
  final DriftColors colors;

  double _angle(DateTime t) {
    final mins = t.difference(day).inMinutes.clamp(0, 1440);
    return -math.pi / 2 + mins / 1440 * 2 * math.pi;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final center = size.center(Offset.zero);
    final outerR = size.shortestSide / 2 - 10;
    final innerR = outerR - 18;
    const outerW = 12.0;
    const innerW = 8.0;

    Paint stroke(Color color, double w) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.butt;

    canvas.drawCircle(center, outerR, stroke(c.line, outerW));
    canvas.drawCircle(center, innerR, stroke(c.line.withValues(alpha: 0.6), innerW));

    void arc(double r, DateTime a, DateTime b, Paint p, {double gap = 0}) {
      final start = _angle(a) + gap;
      final sweep = _angle(b) - _angle(a) - 2 * gap;
      if (sweep <= 0) return;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start,
        sweep,
        false,
        p,
      );
    }

    for (final b in blocks) {
      arc(outerR, b.start, b.end, stroke(c.accent.withValues(alpha: 0.85), outerW), gap: 0.006);
    }
    for (final s in segments) {
      if (s.verdict == Verdict.unplanned && s.p == null) continue;
      arc(innerR, s.start, s.end, stroke(verdictColor(c, s.verdict), innerW));
    }

    // Hour ticks at 0, 6, 12 and 18.
    final tick = Paint()
      ..color = c.textSecondary
      ..strokeWidth = 1.5;
    for (var h = 0; h < 24; h += 6) {
      final a = -math.pi / 2 + h / 24 * 2 * math.pi;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * (outerR + 7),
        center + dir * (outerR + 11),
        tick,
      );
    }

    // The now hand: a short line from the inner ring to the outer edge.
    if (now.isAfter(day) && now.difference(day).inMinutes < 1440) {
      final a = _angle(now);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * (innerR - 8),
        center + dir * (outerR + 8),
        Paint()
          ..color = c.offTrack
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(DayRingPainter old) =>
      old.blocks != blocks ||
      old.segments != segments ||
      old.now != now ||
      old.colors != colors ||
      old.day != day;
}
