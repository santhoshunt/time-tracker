import 'package:flutter/material.dart';

import '../services/review_summary.dart';
import '../theme/drift_theme.dart';
import '../widgets/score_bucket_style.dart';

/// The geometry of a month calendar: a weekday header, then rows of seven
/// square cells. Shared by the painter, the widget that sizes it and the
/// tap handler, so all three agree on where a day is.
class HeatmapLayout {
  HeatmapLayout({
    required this.width,
    required this.leading,
    required this.days,
    required this.headerHeight,
    this.gap = 6,
    this.maxCell = 46,
  });

  final double width;

  /// Blank cells before day 1.
  final int leading;

  /// Days in the month.
  final int days;
  final double headerHeight;
  final double gap;
  final double maxCell;

  double get cell {
    final fit = (width - 6 * gap) / 7;
    return fit < maxCell ? fit : maxCell;
  }

  /// Left edge of the grid; a capped cell size leaves the grid centred.
  double get left => (width - (7 * cell + 6 * gap)) / 2;

  int get rows => ((leading + days) / 7).ceil();

  double get height => headerHeight + rows * cell + (rows - 1) * gap;

  Rect cellRect(int index) {
    final row = index ~/ 7, col = index % 7;
    return Rect.fromLTWH(
      left + col * (cell + gap),
      headerHeight + row * (cell + gap),
      cell,
      cell,
    );
  }

  double columnCentre(int col) => left + col * (cell + gap) + cell / 2;

  /// The day of the month (1-based) under [p], or null.
  int? dayAt(Offset p) {
    for (var d = 1; d <= days; d++) {
      if (cellRect(leading + d - 1).inflate(gap / 2).contains(p)) return d;
    }
    return null;
  }
}

/// Month review option A: the month as a calendar heatmap. Each day is a
/// rounded cell shaded by its score bucket with its date inside; today
/// gets a ring.
class MonthHeatmapPainter extends CustomPainter {
  const MonthHeatmapPainter({
    required this.layout,
    required this.points,
    required this.today,
    required this.weekdayLetters,
    required this.colors,
    required this.numberStyle,
    required this.headerStyle,
    required this.textScaler,
  });

  final HeatmapLayout layout;

  /// One point per day of the month, day 1 first.
  final List<DayPoint> points;

  /// Local midnight of today.
  final DateTime today;

  /// Seven header letters, starting on the week's first day.
  final List<String> weekdayLetters;
  final DriftColors colors;
  final TextStyle numberStyle;
  final TextStyle headerStyle;
  final TextScaler textScaler;

  void _text(Canvas canvas, String s, TextStyle style, Offset centre) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final l = layout;
    for (var col = 0; col < 7; col++) {
      _text(
        canvas,
        weekdayLetters[col],
        headerStyle,
        Offset(l.columnCentre(col), (l.headerHeight - 6) / 2),
      );
    }

    final radius = Radius.circular(l.cell * 0.26);
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final rect = l.cellRect(l.leading + i);
      final rr = RRect.fromRectAndRadius(rect, radius);
      final future = p.day.isAfter(today);
      final bucket = future ? ScoreBucket.none : bucketOf(p.percent);
      canvas.drawRRect(rr, Paint()..color = bucketFill(c, bucket));
      if (bucket == ScoreBucket.none) {
        canvas.drawRRect(
          rr.deflate(0.5),
          Paint()
            ..color = c.line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      if (p.day == today) {
        canvas.drawRRect(
          rr.inflate(2.5),
          Paint()
            ..color = c.text
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      _text(
        canvas,
        '${i + 1}',
        numberStyle.copyWith(color: bucketInk(c, bucket)),
        rect.center,
      );
    }
  }

  @override
  bool shouldRepaint(MonthHeatmapPainter old) =>
      old.points != points ||
      old.today != today ||
      old.colors != colors ||
      old.layout.width != layout.width ||
      old.layout.headerHeight != layout.headerHeight ||
      old.textScaler != textScaler;
}
