import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Usage tab's ring: one arc per category, sized by its share of the
/// period's time, starting at the top and running clockwise in list order.
/// An empty [parts] list draws the track alone.
class CategoryRingPainter extends CustomPainter {
  const CategoryRingPainter({
    required this.parts,
    required this.track,
    this.width = 16,
  });

  /// (colour, milliseconds) per category, largest first.
  final List<(Color, int)> parts;
  final Color track;
  final double width;

  /// The gap between two arcs, in radians, so neighbours stay apart.
  static const gap = 0.025;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2 - width / 2;
    final rect = Rect.fromCircle(center: center, radius: r);
    Paint stroke(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.butt;

    canvas.drawCircle(center, r, stroke(track));
    final total = parts.fold<int>(0, (sum, p) => sum + p.$2);
    if (total <= 0) return;
    final drawn = [
      for (final p in parts)
        if (p.$2 > 0) p,
    ];
    final gaps = drawn.length > 1 ? gap : 0.0;
    var start = -math.pi / 2;
    for (final (color, ms) in drawn) {
      final sweep = ms / total * 2 * math.pi;
      // A sliver too thin to survive its gaps still shows as a hairline.
      final visible = math.max(sweep - gaps, 0.01);
      canvas.drawArc(rect, start + gaps / 2, visible, false, stroke(color));
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(CategoryRingPainter old) =>
      old.track != track ||
      old.width != width ||
      old.parts.length != parts.length ||
      Iterable<int>.generate(parts.length).any((i) => old.parts[i] != parts[i]);
}
