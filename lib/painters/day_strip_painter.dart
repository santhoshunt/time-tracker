import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../theme/drift_theme.dart';
import '../widgets/verdict_style.dart';

/// Day review option B: the whole day, midnight to midnight, as one strip.
/// A thin row on top marks the planned blocks; the strip below is
/// coloured by verdict, and a line marks now on today.
class DayStripPainter extends CustomPainter {
  const DayStripPainter({
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

  static const planHeight = 4.0;
  static const planGap = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final frame = DayFrame.local(day);
    final startMs = frame.start.millisecondsSinceEpoch;
    final lenMs = frame.end.millisecondsSinceEpoch - startMs;
    double x(DateTime t) {
      final f = (t.millisecondsSinceEpoch - startMs) / lenMs;
      return f.clamp(0.0, 1.0) * size.width;
    }

    // The plan row.
    final planRow = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, planHeight),
      const Radius.circular(planHeight / 2),
    );
    canvas.drawRRect(planRow, Paint()..color = c.line.withValues(alpha: 0.5));
    final planPaint = Paint()..color = c.planBorder;
    for (final b in blocks) {
      final a = x(b.start), e = x(b.end);
      if (e - a < 0.5) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(a + 0.5, 0, e - 0.5, planHeight),
          const Radius.circular(planHeight / 2),
        ),
        planPaint,
      );
    }

    // The strip.
    const top = planHeight + planGap;
    final strip = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, size.height - top),
      const Radius.circular(5),
    );
    canvas.save();
    canvas.clipRRect(strip);
    canvas.drawRRect(strip, Paint()..color = c.line.withValues(alpha: 0.55));
    for (final s in segments) {
      if (s.verdict == Verdict.unplanned && s.p == null) continue;
      final a = x(s.start), e = x(s.end);
      if (e <= a) continue;
      canvas.drawRect(
        Rect.fromLTRB(a, top, e, size.height),
        Paint()..color = verdictColor(c, s.verdict),
      );
    }
    canvas.restore();

    // Now, on today only.
    if (now.isAfter(frame.start) && now.isBefore(frame.end)) {
      final nx = x(now);
      canvas.drawLine(
        Offset(nx, 0),
        Offset(nx, size.height),
        Paint()
          ..color = c.text
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(DayStripPainter old) =>
      old.day != day ||
      old.blocks != blocks ||
      old.segments != segments ||
      old.now != now ||
      old.colors != colors;
}
