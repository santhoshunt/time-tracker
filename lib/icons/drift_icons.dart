import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The six launcher icons. Each one is an `<activity-alias>` in the
/// manifest, and [aliasName] is the alias's class name, so it is frozen for
/// the life of the app. Melting clock is the default.
enum DriftIcon {
  meltingClock('IconMeltingClock', 'Melting clock', Color(0xFF101214)),
  timeRiver('IconTimeRiver', 'Time river', Color(0xFF0B1426)),
  slidingDay('IconSlidingDay', 'Sliding day', Color(0xFFFBF7F2)),
  needle('IconNeedle', 'Needle', Color(0xFF000000)),
  wanderer('IconWanderer', 'Wanderer', Color(0xFF4A90E2)),
  escape('IconEscape', 'Escape', Color(0xFF101214));

  const DriftIcon(this.aliasName, this.label, this.background);

  /// The activity-alias name that `drift/icon` enables.
  final String aliasName;

  /// The name shown under the tile in the icon picker.
  final String label;

  /// The tile colour behind the art, also the adaptive-icon background.
  final Color background;

  /// The icon for an alias name from `IconSwitcher.current()`. An unknown
  /// name falls back to the default rather than failing.
  static DriftIcon fromAlias(String alias) => DriftIcon.values.firstWhere(
    (i) => i.aliasName == alias,
    orElse: () => DriftIcon.meltingClock,
  );
}

/// The two launcher mask shapes the icon picker previews.
enum IconMask {
  circle,

  /// A rounded square with a corner radius of 30/96 of the side.
  squircle;

  /// The outline of this mask over a box of [size].
  Path pathFor(Size size) {
    final rect = Offset.zero & size;
    return switch (this) {
      IconMask.circle => Path()..addOval(rect),
      IconMask.squircle => Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(size.shortestSide * 30 / 96),
          ),
        ),
    };
  }
}

/// Paints the art of [icon] only, with no background. The art is drawn on a
/// 96-unit square fitted to the paint size, then scaled by [artScale] about
/// the centre. 0.72 keeps the art inside the launcher safe zone under both
/// masks.
class DriftIconPainter extends CustomPainter {
  const DriftIconPainter(this.icon, {this.artScale = 0.72});

  final DriftIcon icon;
  final double artScale;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / 96;
    canvas.save();
    canvas.translate(
      (size.width - 96 * unit) / 2,
      (size.height - 96 * unit) / 2,
    );
    canvas.scale(unit);
    canvas.translate(48, 48);
    canvas.scale(artScale);
    canvas.translate(-48, -48);
    switch (icon) {
      case DriftIcon.meltingClock:
        _meltingClock(canvas);
      case DriftIcon.timeRiver:
        _timeRiver(canvas);
      case DriftIcon.slidingDay:
        _slidingDay(canvas);
      case DriftIcon.needle:
        _needle(canvas);
      case DriftIcon.wanderer:
        _wanderer(canvas);
      case DriftIcon.escape:
        _escape(canvas);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DriftIconPainter oldDelegate) =>
      oldDelegate.icon != icon || oldDelegate.artScale != artScale;
}

/// Clips to [mask], fills the icon's background colour and paints the art.
/// The icon picker and the legacy launcher PNGs both draw through this.
class DriftIconTilePainter extends CustomPainter {
  const DriftIconTilePainter(
    this.icon, {
    this.mask = IconMask.squircle,
    this.artScale = 0.72,
  });

  final DriftIcon icon;
  final IconMask mask;
  final double artScale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipPath(mask.pathFor(size));
    canvas.drawRect(Offset.zero & size, Paint()..color = icon.background);
    DriftIconPainter(icon, artScale: artScale).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DriftIconTilePainter oldDelegate) =>
      oldDelegate.icon != icon ||
      oldDelegate.mask != mask ||
      oldDelegate.artScale != artScale;
}

/// A square icon preview of [size] logical pixels, as the launcher would
/// show it under [mask].
class DriftIconTile extends StatelessWidget {
  const DriftIconTile(
    this.icon,
    this.size, {
    super.key,
    this.mask = IconMask.squircle,
  });

  final DriftIcon icon;
  final double size;
  final IconMask mask;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: DriftIconTilePainter(icon, mask: mask)),
  );
}

// The art below is a line-for-line port of the round-3 SVG mockups on a
// 96 by 96 viewBox. Strokes use butt caps unless the SVG asks for round.

Paint _fill(Color color) => Paint()..color = color;

Paint _stroke(Color color, double width, {StrokeCap cap = StrokeCap.butt}) =>
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = cap;

RRect _rrect(double x, double y, double w, double h, double r) =>
    RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));

/// An SVG `stroke-dasharray` on a straight line: dashes start at [a].
void _dashedLine(
  Canvas canvas,
  Offset a,
  Offset b,
  double dash,
  double gap,
  Paint paint,
) {
  final total = (b - a).distance;
  final dir = (b - a) / total;
  for (var d = 0.0; d < total; d += dash + gap) {
    final end = math.min(d + dash, total);
    canvas.drawLine(a + dir * d, a + dir * end, paint);
  }
}

/// An SVG `stroke-dasharray` on a circle: like the SVG, the path starts at
/// 3 o'clock and runs clockwise.
void _dashedCircle(
  Canvas canvas,
  Offset centre,
  double r,
  double dash,
  double gap,
  Paint paint,
) {
  final rect = Rect.fromCircle(center: centre, radius: r);
  final total = 2 * math.pi * r;
  for (var d = 0.0; d < total; d += dash + gap) {
    final end = math.min(d + dash, total);
    canvas.drawArc(rect, d / r, (end - d) / r, false, paint);
  }
}

const _ink = Color(0xFFE6EAF2);
const _coral = Color(0xFFFF6B6B);
const _cyan = Color(0xFF38BDF8);

void _meltingClock(Canvas canvas) {
  const dark = Color(0xFF101214);
  canvas.drawRRect(_rrect(12, 58, 54, 24, 5), _fill(const Color(0xFF272B30)));
  final body = Path()
    ..moveTo(18, 58)
    ..cubicTo(18, 32, 62, 28, 66, 50)
    ..cubicTo(68, 58, 71, 64, 73, 74)
    ..cubicTo(75, 84, 66, 86, 66, 78)
    ..cubicTo(66, 70, 62, 62, 56, 58)
    ..close();
  canvas.drawPath(body, _fill(_ink));
  canvas.drawCircle(const Offset(69, 88), 3, _fill(_ink));
  for (final p in const [Offset(40, 36), Offset(26, 48), Offset(56, 46)]) {
    canvas.drawCircle(p, 1.8, _fill(dark));
  }
  canvas.drawLine(const Offset(40, 48), const Offset(40, 39), _stroke(dark, 3));
  canvas.drawLine(
    const Offset(40, 48),
    const Offset(52, 54),
    _stroke(_coral, 3),
  );
}

void _timeRiver(Canvas canvas) {
  const river = Color(0xFFFF7A59);
  const centre = Offset(42, 44);
  canvas.drawCircle(centre, 26, _fill(const Color(0xFF16233F)));
  canvas.drawCircle(centre, 26, _stroke(_cyan, 5));
  final tick = _stroke(_cyan.withValues(alpha: 0.6), 3);
  canvas.drawLine(const Offset(42, 23), const Offset(42, 27), tick);
  canvas.drawLine(const Offset(63, 44), const Offset(59, 44), tick);
  canvas.drawLine(const Offset(42, 65), const Offset(42, 61), tick);
  canvas.drawLine(const Offset(21, 44), const Offset(25, 44), tick);
  canvas.drawLine(centre, const Offset(42, 30), _stroke(_ink, 5));
  // `S 84 77, 80 85`: the first control point mirrors (62, 68) about
  // (72, 69), which gives (82, 70).
  final flow = Path()
    ..moveTo(42, 44)
    ..lineTo(55, 52)
    ..cubicTo(63, 57, 62, 68, 72, 69)
    ..cubicTo(82, 70, 84, 77, 80, 85);
  canvas.drawPath(flow, _stroke(river, 5));
  canvas.drawCircle(const Offset(80, 85), 4, _fill(river));
  canvas.drawCircle(centre, 4, _fill(_ink));
}

void _slidingDay(Canvas canvas) {
  const ink = Color(0xFF2B2420);
  const orange = Color(0xFFD9733B);
  canvas.drawRRect(_rrect(20, 18, 46, 12, 6), _fill(ink));
  canvas.drawRRect(_rrect(20, 34, 46, 12, 6), _fill(const Color(0xFFB9A48F)));
  canvas.drawRRect(_rrect(40, 53, 46, 12, 6), _fill(const Color(0xFFA85A2C)));
  canvas.drawRRect(_rrect(38, 50, 46, 12, 6), _fill(orange));
  final speed = _stroke(orange.withValues(alpha: 0.55), 3);
  canvas.drawLine(const Offset(18, 52), const Offset(31, 52), speed);
  canvas.drawLine(const Offset(23, 56), const Offset(33, 56), speed);
  canvas.drawLine(const Offset(18, 60), const Offset(31, 60), speed);
  canvas.drawRRect(_rrect(20, 68, 46, 12, 6), _fill(ink));
}

void _needle(Canvas canvas) {
  const centre = Offset(48, 48);
  const r = 28.0;
  final rect = Rect.fromCircle(center: centre, radius: r);
  canvas.drawCircle(centre, r, _stroke(const Color(0xFF1E2328), 10));
  // [colour, dash length, offset along the circumference], from 12 o'clock
  // clockwise.
  const segments = [
    (_cyan, 38.0, 0.0),
    (_ink, 32.0, 44.0),
    (_cyan, 32.0, 82.0),
    (_ink, 20.0, 150.0),
  ];
  for (final (color, length, offset) in segments) {
    canvas.drawArc(
      rect,
      -math.pi / 2 + offset / r,
      length / r,
      false,
      _stroke(color, 10),
    );
  }
  canvas.save();
  canvas.translate(48, 48);
  canvas.rotate(-84 * math.pi / 180);
  canvas.translate(-48, -48);
  canvas.drawPath(
    Path()
      ..moveTo(48, 18)
      ..lineTo(54, 48)
      ..lineTo(42, 48)
      ..close(),
    _fill(_coral),
  );
  canvas.drawPath(
    Path()
      ..moveTo(42, 48)
      ..lineTo(54, 48)
      ..lineTo(48, 64)
      ..close(),
    _fill(_ink),
  );
  canvas.restore();
  canvas.drawCircle(centre, 4, _fill(const Color(0xFF000000)));
}

void _wanderer(Canvas canvas) {
  const white = Color(0xFFFFFFFF);
  const gold = Color(0xFFFFD166);
  _dashedLine(
    canvas,
    const Offset(20, 76),
    const Offset(76, 20),
    1,
    8,
    _stroke(white, 4, cap: StrokeCap.round),
  );
  final trail = Path()
    ..moveTo(20, 76)
    ..cubicTo(30, 66, 30, 54, 40, 56)
    ..cubicTo(52, 58, 52, 42, 42, 42)
    ..cubicTo(32, 42, 38, 60, 56, 60)
    ..cubicTo(70, 60, 74, 70, 80, 72);
  canvas.drawPath(trail, _stroke(gold, 5));
  canvas.drawCircle(
    const Offset(80, 72),
    11,
    _stroke(gold.withValues(alpha: 0.45), 2),
  );
  canvas.drawCircle(const Offset(80, 72), 5, _fill(gold));
  canvas.drawCircle(const Offset(20, 76), 5, _fill(white));
}

void _escape(Canvas canvas) {
  final page = _rrect(14, 24, 54, 54, 9);
  canvas.drawRRect(page, _fill(const Color(0xFF181B1E)));
  canvas.drawRRect(page, _stroke(_cyan, 3));
  // `a9 9 0 0 1`: sweep flag 1 is clockwise on screen.
  final header = Path()
    ..moveTo(14, 33)
    ..arcToPoint(const Offset(23, 24), radius: const Radius.circular(9))
    ..lineTo(59, 24)
    ..arcToPoint(const Offset(68, 33), radius: const Radius.circular(9))
    ..lineTo(68, 37)
    ..lineTo(14, 37)
    ..close();
  canvas.drawPath(header, _fill(_cyan));
  canvas.drawRRect(_rrect(26, 17, 4, 12, 2), _fill(_ink));
  canvas.drawRRect(_rrect(52, 17, 4, 12, 2), _fill(_ink));
  for (final p in const [
    Offset(27, 48),
    Offset(41, 48),
    Offset(55, 48),
    Offset(27, 62),
    Offset(41, 62),
  ]) {
    canvas.drawCircle(p, 3.5, _fill(_ink));
  }
  _dashedCircle(canvas, const Offset(55, 62), 3.5, 2, 2, _stroke(_ink, 1.5));
  _dashedLine(
    canvas,
    const Offset(58, 59),
    const Offset(72, 44),
    2,
    4,
    _stroke(_coral, 2),
  );
  canvas.save();
  canvas.translate(78, 36);
  canvas.rotate(20 * math.pi / 180);
  canvas.translate(-78, -36);
  canvas.drawRRect(_rrect(72, 30, 13, 13, 3), _fill(_coral));
  canvas.restore();
}
