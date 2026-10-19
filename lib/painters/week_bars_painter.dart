import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/review_summary.dart';
import '../theme/drift_theme.dart';

/// Week review option A: one bar per day, each the day's whole plan. From
/// the bottom: on track, idle, off track; whatever is left (time still
/// ahead, or no data) stays the bare track. Days with nothing planned get
/// a short stub, days still ahead an empty track, and today an outline.
class WeekBarsPainter extends CustomPainter {
  const WeekBarsPainter({
    required this.points,
    required this.today,
    required this.colors,
  });

  final List<DayPoint> points;

  /// Local midnight of today.
  final DateTime today;
  final DriftColors colors;

  /// The column a horizontal position falls in.
  static int columnAt(double x, double width, int count) =>
      (x / (width / count)).floor().clamp(0, count - 1);

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final n = points.length;
    if (n == 0) return;
    final colW = size.width / n;
    final barW = math.min(colW * 0.52, 30.0);
    final radius = Radius.circular(math.min(7.0, barW / 2));

    for (var i = 0; i < n; i++) {
      final p = points[i];
      final cx = colW * (i + 0.5);
      final rect = Rect.fromLTWH(cx - barW / 2, 0, barW, size.height);
      final rr = RRect.fromRectAndRadius(rect, radius);
      final future = p.day.isAfter(today);

      if (p.day == today) {
        canvas.drawRRect(
          rr.inflate(3),
          Paint()
            ..color = c.text
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (future) {
        canvas.drawRRect(
          rr.deflate(0.5),
          Paint()
            ..color = c.line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        continue;
      }
      if (!p.hasPlan) {
        const stub = 4.0;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.left, size.height - stub, barW, stub),
            const Radius.circular(2),
          ),
          Paint()..color = c.line,
        );
        continue;
      }

      canvas.drawRRect(rr, Paint()..color = c.line.withValues(alpha: 0.6));
      canvas.save();
      canvas.clipRRect(rr);
      final total = p.fullPlannedMin.toDouble();
      var y = size.height;
      for (final (mins, color) in [
        (p.onMin, c.onTrack),
        (p.idleMin, c.idleFill),
        (p.offMin, c.offTrack),
      ]) {
        if (mins <= 0) continue;
        final h = size.height * (mins / total).clamp(0.0, 1.0);
        canvas.drawRect(
          Rect.fromLTRB(rect.left, y - h, rect.right, y),
          Paint()..color = color,
        );
        y -= h;
        // A hairline in the card colour between pieces keeps them crisp.
        if (y > 0) {
          canvas.drawRect(
            Rect.fromLTRB(rect.left, y - 1, rect.right, y),
            Paint()..color = c.card,
          );
          y -= 1;
        }
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(WeekBarsPainter old) =>
      old.points != points || old.today != today || old.colors != colors;
}
