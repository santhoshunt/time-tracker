import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme/drift_theme.dart';

/// The fill for a slice of time, the same on every screen.
Color verdictColor(DriftColors c, Verdict v) => switch (v) {
  Verdict.onTrack => c.onTrack,
  Verdict.offTrack => c.offTrack,
  Verdict.neutral => c.neutral,
  Verdict.guessedOn || Verdict.guessedOff => c.guessed,
  Verdict.idle => c.idleFill,
  Verdict.unplanned => c.textSecondary.withValues(alpha: 0.35),
  Verdict.noData => c.line,
};

/// Words for a verdict, for sheets and screen readers.
String verdictLabel(Verdict v) => switch (v) {
  Verdict.onTrack => 'On track',
  Verdict.offTrack => 'Off track',
  Verdict.neutral => 'Neutral',
  Verdict.guessedOn => 'Guessed on track',
  Verdict.guessedOff => 'Guessed off track',
  Verdict.idle => 'Idle',
  Verdict.unplanned => 'Outside your plan',
  Verdict.noData => 'No data',
};

/// Guesses wait for an answer, so they get a dashed outline on top of the
/// amber fill; idle gets a dashed on-track outline.
bool verdictDashed(Verdict v) =>
    v == Verdict.guessedOn || v == Verdict.guessedOff || v == Verdict.idle;

/// Diagonal stripes for no-data time: nothing is known about it, so it
/// must not look like any verdict.
class HatchPainter extends CustomPainter {
  const HatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (double x = -size.height; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(HatchPainter old) => old.color != color;
}

/// A dashed rounded-rectangle outline.
class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter({required this.color, this.radius = 4});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 6) {
        canvas.drawPath(metric.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
