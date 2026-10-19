import 'package:flutter/material.dart';

import '../services/review_summary.dart';
import '../theme/drift_theme.dart';

/// Month review option A, second chart: daily scores this month as a
/// solid on-track line against last month as a dashed secondary line,
/// over a 0 to 100% scale with a guide at 75%. Days without a score are
/// skipped and the line joins the scored days on either side.
class TrendPainter extends CustomPainter {
  const TrendPainter({
    required this.current,
    required this.previous,
    required this.colors,
    required this.labelStyle,
    required this.textScaler,
  });

  /// Scores by day of month, day 1 first; null for no score.
  final List<int?> current;
  final List<int?> previous;
  final DriftColors colors;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  TextPainter _tp(String s) => TextPainter(
    text: TextSpan(text: s, style: labelStyle),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final slots = current.length > previous.length
        ? current.length
        : previous.length;
    if (slots < 2) return;

    final yLabels = {for (final v in [0, 50, 75, 100]) v: _tp('$v%')};
    final labelW = yLabels.values
        .map((t) => t.width)
        .reduce((a, b) => a > b ? a : b);
    final xLabelH = _tp('1').height;
    final plot = Rect.fromLTRB(
      labelW + 10,
      yLabels[100]!.height / 2 + 2,
      size.width - 6,
      size.height - xLabelH - 8,
    );
    double y(int v) => plot.bottom - v / 100 * plot.height;
    double x(int i) => plot.left + i / (slots - 1) * plot.width;

    // Scale.
    for (final v in [0, 50, 100]) {
      canvas.drawLine(
        Offset(plot.left, y(v)),
        Offset(plot.right, y(v)),
        Paint()
          ..color = c.line
          ..strokeWidth = 1,
      );
    }
    canvas.drawLine(
      Offset(plot.left, y(goodPercent)),
      Offset(plot.right, y(goodPercent)),
      Paint()
        ..color = c.onTrack.withValues(alpha: 0.45)
        ..strokeWidth = 1,
    );
    for (final e in yLabels.entries) {
      final tp = e.value;
      tp.paint(canvas, Offset(labelW - tp.width, y(e.key) - tp.height / 2));
    }

    // Day labels under the plot.
    final ticks = <int>{0, 7, 14, 21, current.length - 1};
    for (final i in ticks) {
      if (i < 0 || i >= slots) continue;
      final tp = _tp('${i + 1}');
      final cx = x(i).clamp(plot.left + tp.width / 2, plot.right - tp.width / 2);
      tp.paint(canvas, Offset(cx - tp.width / 2, plot.bottom + 6));
    }

    Path line(List<int?> values) {
      final path = Path();
      var started = false;
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        if (v == null) continue;
        final o = Offset(x(i), y(v));
        if (started) {
          path.lineTo(o.dx, o.dy);
        } else {
          path.moveTo(o.dx, o.dy);
          started = true;
        }
      }
      return path;
    }

    // Last month, dashed.
    final prevPaint = Paint()
      ..color = c.textSecondary.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final m in line(previous).computeMetrics()) {
      for (double d = 0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 3.5), prevPaint);
      }
    }

    // This month, solid with dots.
    canvas.drawPath(
      line(current),
      Paint()
        ..color = c.onTrack
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < current.length; i++) {
      final v = current[i];
      if (v == null) continue;
      final o = Offset(x(i), y(v));
      canvas.drawCircle(o, 3.2, Paint()..color = c.card);
      canvas.drawCircle(o, 2.4, Paint()..color = c.onTrack);
    }
  }

  @override
  bool shouldRepaint(TrendPainter old) =>
      old.current != current ||
      old.previous != previous ||
      old.colors != colors ||
      old.textScaler != textScaler;
}

/// A short line sample for the trend legend: solid or dashed.
class LineSwatchPainter extends CustomPainter {
  const LineSwatchPainter({
    required this.color,
    this.dashed = false,
    this.thin = false,
  });

  final Color color;
  final bool dashed;

  /// The 1-pixel weight of the guide line.
  final bool thin;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thin ? 1.2 : (dashed ? 1.5 : 2.2)
      ..strokeCap = StrokeCap.round;
    final yMid = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(1, yMid), Offset(size.width - 1, yMid), paint);
      return;
    }
    for (double x = 1; x < size.width - 1; x += 7) {
      final end = x + 3.5 < size.width - 1 ? x + 3.5 : size.width - 1;
      canvas.drawLine(Offset(x, yMid), Offset(end, yMid), paint);
    }
  }

  @override
  bool shouldRepaint(LineSwatchPainter old) =>
      old.color != color || old.dashed != dashed || old.thin != thin;
}
