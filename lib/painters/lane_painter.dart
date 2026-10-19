import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme/drift_theme.dart';
import '../widgets/verdict_style.dart';

/// One piece of the actual lane as drawn: a single segment, or neighbours
/// merged for drawing. The data is untouched; [members] keeps every
/// segment the piece covers, and [primary] is the longest of them, which
/// gives the piece its verdict and label and is what a tap opens.
class LanePiece {
  const LanePiece({
    required this.start,
    required this.end,
    required this.primary,
    required this.members,
  });

  final DateTime start;
  final DateTime end;
  final Segment primary;
  final List<Segment> members;

  Verdict get verdict => primary.verdict;
  String? get p => primary.p;
  Duration get duration => end.difference(start);

  @override
  String toString() =>
      'LanePiece(${verdict.name}, $p, $start, $end, ${members.length})';
}

/// A drawn piece with everything paint needs, computed once per layout.
class LaneShape {
  const LaneShape({
    required this.piece,
    required this.name,
    required this.rect,
    required this.rrect,
    required this.fill,
    this.outline,
    this.outlineColor,
    this.hatch,
    this.hatchColor,
    this.label,
    this.labelOffset = Offset.zero,
    this.labelClip,
  });

  final LanePiece piece;

  /// The app label, or the verdict's words when there is no app.
  final String name;
  final Rect rect;
  final RRect rrect;
  final Color fill;

  /// Every dash of the dashed outline, as one path.
  final Path? outline;
  final Color? outlineColor;

  /// The no-data stripes, clipped to [rect] when painted.
  final Path? hatch;
  final Color? hatchColor;

  final TextPainter? label;
  final Offset labelOffset;

  /// Set when the label is taller than the piece, as a Text widget clips.
  final Rect? labelClip;

  /// What a screen reader says for the piece.
  String get semanticsLabel => '$name, ${verdictLabel(piece.verdict)}';
}

/// The geometry of the whole actual lane. Built when the pieces, colours,
/// text style or text scale change; painting only replays it.
class LaneLayout {
  LaneLayout._(this.shapes);

  static const minHeight = 2.0;
  static const labelMinHeight = 15.0;
  static const radius = 4.0;
  static const _padding = 4.0;
  static const _dash = 3.0;
  static const _gap = 3.0;
  static const _hatchStep = 7.0;

  /// Lays out [pieces] in a lane column [left] to [left] + [width], with
  /// [yOf] giving the vertical position of a moment.
  factory LaneLayout.build({
    required List<LanePiece> pieces,
    required String Function(String? p) labelOf,
    required double Function(DateTime t) yOf,
    required double left,
    required double width,
    required DriftColors colors,
    required TextStyle labelStyle,
    required TextScaler textScaler,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final c = colors;
    final shapes = <LaneShape>[];
    for (final piece in pieces) {
      final v = piece.verdict;
      final top = yOf(piece.start);
      final height = math.max(minHeight, yOf(piece.end) - top);
      final rect = Rect.fromLTWH(left, top, width, height);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(radius));
      final base = verdictColor(c, v);
      final fill = v == Verdict.guessedOn || v == Verdict.guessedOff
          ? base.withValues(alpha: 0.28)
          : base;
      final appLabel = labelOf(piece.p);

      Path? outline;
      Color? outlineColor;
      Path? hatch;
      Color? hatchColor;
      if (v == Verdict.noData) {
        hatch = _hatchPath(rect);
        hatchColor = c.textSecondary.withValues(alpha: 0.5);
      } else if (verdictDashed(v)) {
        outline = _dashedPath(
          RRect.fromRectAndRadius(rect.deflate(0.75), const Radius.circular(radius)),
        );
        outlineColor = v == Verdict.idle ? c.onTrack : c.guessed;
      }

      TextPainter? label;
      var labelOffset = Offset.zero;
      Rect? labelClip;
      if (height >= labelMinHeight && (appLabel.isNotEmpty || v == Verdict.idle)) {
        final solid = v == Verdict.onTrack || v == Verdict.offTrack;
        label = TextPainter(
          text: TextSpan(
            text: v == Verdict.idle ? 'idle' : appLabel,
            style: labelStyle.copyWith(color: solid ? c.bg : c.text),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout(maxWidth: math.max(0, width - 2 * _padding));
        final boxHeight = math.min(label.height, height);
        labelOffset = Offset(left + _padding, top + (height - boxHeight) / 2);
        if (label.height > height) {
          labelClip = labelOffset & Size(label.width, boxHeight);
        }
      }

      shapes.add(
        LaneShape(
          piece: piece,
          name: appLabel.isEmpty ? verdictLabel(v) : appLabel,
          rect: rect,
          rrect: rrect,
          fill: fill,
          outline: outline,
          outlineColor: outlineColor,
          hatch: hatch,
          hatchColor: hatchColor,
          label: label,
          labelOffset: labelOffset,
          labelClip: labelClip,
        ),
      );
    }
    return LaneLayout._(shapes);
  }

  final List<LaneShape> shapes;

  /// The piece drawn at [y], the topmost one where pieces overlap.
  LanePiece? pieceAt(double y) {
    for (var i = shapes.length - 1; i >= 0; i--) {
      final r = shapes[i].rect;
      if (y >= r.top && y < r.bottom) return shapes[i].piece;
    }
    return null;
  }

  /// Releases the laid-out labels.
  void dispose() {
    for (final s in shapes) {
      s.label?.dispose();
    }
  }

  static Path _dashedPath(RRect rrect) {
    final source = Path()..addRRect(rrect);
    final out = Path();
    for (final metric in source.computeMetrics()) {
      for (double d = 0; d < metric.length; d += _dash + _gap) {
        out.addPath(metric.extractPath(d, d + _dash), Offset.zero);
      }
    }
    return out;
  }

  static Path _hatchPath(Rect rect) {
    final out = Path();
    final h = rect.height;
    for (double x = -h; x < rect.width; x += _hatchStep) {
      out
        ..moveTo(rect.left + x, rect.bottom)
        ..lineTo(rect.left + x + h, rect.top);
    }
    return out;
  }
}

/// Paints the actual lane from a [LaneLayout]: fills, labels, dashed
/// outlines and no-data stripes. It repaints only when the layout changes.
class LanePainter extends CustomPainter {
  const LanePainter(this.layout);

  final LaneLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint();
    final stroke = Paint()..style = PaintingStyle.stroke;
    for (final s in layout.shapes) {
      canvas.drawRRect(s.rrect, fill..color = s.fill);
      final label = s.label;
      if (label != null) {
        final clip = s.labelClip;
        if (clip != null) {
          canvas.save();
          canvas.clipRect(clip);
        }
        label.paint(canvas, s.labelOffset);
        if (clip != null) canvas.restore();
      }
      if (s.hatch != null) {
        canvas.save();
        canvas.clipRect(s.rect);
        canvas.drawPath(
          s.hatch!,
          stroke
            ..color = s.hatchColor!
            ..strokeWidth = 1.5,
        );
        canvas.restore();
      }
      if (s.outline != null) {
        canvas.drawPath(
          s.outline!,
          stroke
            ..color = s.outlineColor!
            ..strokeWidth = 1.2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(LanePainter old) => !identical(old.layout, layout);
}

/// The plan side of the timeline: hour lines and labels, and the fill and
/// border of each plan block. Block names stay Text widgets on top.
class DayGridPainter extends CustomPainter {
  const DayGridPainter({
    required this.startHour,
    required this.hourHeight,
    required this.gutter,
    required this.blocks,
    required this.lineColor,
    required this.planFill,
    required this.planBorder,
    required this.hourStyle,
    required this.textScaler,
  });

  final int startHour;
  final double hourHeight;
  final double gutter;

  /// Top and height of each plan block; they span from the gutter to the
  /// right edge.
  final List<(double, double)> blocks;
  final Color lineColor;
  final Color planFill;
  final Color planBorder;
  final TextStyle hourStyle;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = lineColor;
    final labelWidth = gutter - 8;
    for (var h = startHour; h <= 24; h++) {
      final y = (h - startHour) * hourHeight;
      canvas.drawRect(Rect.fromLTRB(gutter, y, size.width, y + 1), line);
      final tp = TextPainter(
        text: TextSpan(
          text: '${(h % 24).toString().padLeft(2, '0')}:00',
          style: hourStyle,
        ),
        textAlign: TextAlign.right,
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout(minWidth: labelWidth, maxWidth: labelWidth);
      tp.paint(canvas, Offset(0, y - 7));
      tp.dispose();
    }

    final fill = Paint()..color = planFill;
    final border = Paint()..color = planBorder;
    for (final (top, height) in blocks) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(gutter + 4, top, size.width - gutter - 4, height),
        const Radius.circular(8),
      );
      canvas.drawRRect(rrect, fill);
      canvas.drawDRRect(rrect, rrect.deflate(1), border);
    }
  }

  @override
  bool shouldRepaint(DayGridPainter old) =>
      old.startHour != startHour ||
      old.hourHeight != hourHeight ||
      old.gutter != gutter ||
      !_sameBlocks(old.blocks, blocks) ||
      old.lineColor != lineColor ||
      old.planFill != planFill ||
      old.planBorder != planBorder ||
      old.hourStyle != hourStyle ||
      old.textScaler != textScaler;

  static bool _sameBlocks(List<(double, double)> a, List<(double, double)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The red line and dot at the current time, over everything else.
class NowLinePainter extends CustomPainter {
  const NowLinePainter({required this.y, required this.gutter, required this.color});

  final double y;
  final double gutter;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    canvas.drawRect(Rect.fromLTRB(gutter - 4, y - 0.75, size.width, y + 0.75), paint);
    canvas.drawCircle(Offset(gutter - 4, y), 4, paint);
  }

  @override
  bool shouldRepaint(NowLinePainter old) =>
      old.y != y || old.gutter != gutter || old.color != color;
}
