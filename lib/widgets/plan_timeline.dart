import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../theme/drift_theme.dart';

/// "09:00" for a minute of the day. 1440 reads "24:00" rather than
/// "00:00", so a block that runs to midnight says so.
String formatMinute(int minute) {
  final h = minute ~/ 60;
  final m = minute % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// "09:00 to 12:00", the range wording every plan surface uses.
String formatRange(int startMin, int endMin) =>
    '${formatMinute(startMin)} to ${formatMinute(endMin)}';

/// Names for the six block colours, in [PlanBlock.colorIdx] order. Read
/// out by screen readers on the editor's swatches.
const blockColorNames = ['Theme', 'Blue', 'Violet', 'Teal', 'Pink', 'Sand'];

const _darkBlockColors = [
  Color(0xFF74A7FF),
  Color(0xFFB59CFF),
  Color(0xFF4CC9C0),
  Color(0xFFF28CB8),
  Color(0xFFD9B98C),
];

const _lightBlockColors = [
  Color(0xFF3B6FD8),
  Color(0xFF7A5AE0),
  Color(0xFF13998C),
  Color(0xFFD04F8C),
  Color(0xFFA07A40),
];

/// The colour of a block with [colorIdx]. Index 0 is the theme accent;
/// the other five are fixed hues, darker on the light themes so the
/// border still reads on white. None of them reuse the on-track, off-track
/// or guessed tokens, because those colours mean verdicts on Today.
Color blockColor(BuildContext context, int colorIdx) {
  if (colorIdx <= 0 || colorIdx > 5) return context.drift.accent;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return (dark ? _darkBlockColors : _lightBlockColors)[colorIdx - 1];
}

/// The Plan tab's day: hour rows from 00:00 to 24:00 with the day's blocks
/// drawn on top, opening at [initialMinute] (06:00) so the night hours sit
/// above the fold but stay one scroll away.
///
/// Long-press on empty time and drag to draw a block; the range snaps to
/// [snapMinutes] and goes to [onCreate]. A long-press that is released
/// without moving proposes one hour. Blocks that overlap share the width
/// side by side, so both stay tappable.
class PlanTimeline extends StatefulWidget {
  const PlanTimeline({
    super.key,
    required this.blocks,
    this.nowMinute,
    this.hint,
    this.onBlockTap,
    this.onCreate,
    this.onHintTap,
    this.initialMinute = 6 * 60,
    this.bottomPadding = 0,
    this.suggestions = const [],
    this.onKeepSuggestion,
  });

  final List<PlanBlock> blocks;

  /// Blocks Drift suggests from past weeks, drawn dashed and faded under
  /// the real ones; a tap goes to [onKeepSuggestion]. While any show, the
  /// "Drag to add a block" hint does not.
  final List<PlanBlock> suggestions;
  final ValueChanged<PlanBlock>? onKeepSuggestion;

  /// Minute of the day for the "now" line, or null on other days.
  final int? nowMinute;

  /// A free range to mark with the dashed "Drag to add a block" target.
  final (int, int)? hint;

  final ValueChanged<PlanBlock>? onBlockTap;
  final void Function(int startMin, int endMin)? onCreate;
  final void Function(int startMin, int endMin)? onHintTap;

  /// The minute shown at the top when the timeline first builds.
  final int initialMinute;

  /// Extra space under 24:00 so the floating add button never covers the
  /// last hour.
  final double bottomPadding;

  static const hourHeight = 48.0;

  /// Space above 00:00 and below 24:00, so their labels are not clipped.
  static const verticalPadding = 12.0;

  static const snapMinutes = 15;

  /// Key of the scrolled content box. Tests read its position to turn a
  /// minute into a screen offset with [offsetOf].
  static const contentKey = ValueKey<String>('planTimelineContent');

  /// Vertical offset of [minute] inside the content box.
  static double offsetOf(int minute) =>
      verticalPadding + minute / 60 * hourHeight;

  @override
  State<PlanTimeline> createState() => _PlanTimelineState();
}

class _PlanTimelineState extends State<PlanTimeline> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.initialMinute / 60 * PlanTimeline.hourHeight,
  );

  /// The 15-minute cell the long-press started in, while drawing.
  int? _anchor;

  /// The snapped minute under the finger, once it has moved.
  int? _current;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _minuteAt(double y) =>
      ((y - PlanTimeline.verticalPadding) / PlanTimeline.hourHeight * 60)
          .clamp(0, 1440)
          .toDouble();

  int _snapDown(double y) {
    const s = PlanTimeline.snapMinutes;
    return math.min((_minuteAt(y) ~/ s) * s, 1440 - s);
  }

  int _snapRound(double y) {
    const s = PlanTimeline.snapMinutes;
    return ((_minuteAt(y) / s).round() * s).clamp(0, 1440);
  }

  /// The range being drawn: one hour from the anchor until the finger
  /// moves, then anchor to finger in either direction, never under one
  /// snap step.
  (int, int)? get _draft {
    final anchor = _anchor;
    if (anchor == null) return null;
    final current = _current;
    if (current == null) {
      return (anchor, math.min(anchor + 60, 1440));
    }
    const s = PlanTimeline.snapMinutes;
    if (current > anchor) return (anchor, math.max(current, anchor + s));
    return (math.min(current, anchor), anchor + s);
  }

  bool _onBlock(double minute) => widget.blocks.any(
    (b) => minute >= b.startMin && minute < b.endMin,
  );

  void _start(LongPressStartDetails d) {
    if (widget.onCreate == null) return;
    if (_onBlock(_minuteAt(d.localPosition.dy))) return;
    HapticFeedback.selectionClick();
    setState(() {
      _anchor = _snapDown(d.localPosition.dy);
      _current = null;
    });
  }

  void _move(LongPressMoveUpdateDetails d) {
    if (_anchor == null) return;
    // Small finger wobble keeps the one-hour proposal.
    if (_current == null && d.offsetFromOrigin.distance < 8) return;
    final next = _snapRound(d.localPosition.dy);
    if (next != _current) setState(() => _current = next);
  }

  void _end(LongPressEndDetails d) {
    final draft = _draft;
    setState(() {
      _anchor = null;
      _current = null;
    });
    if (draft != null) widget.onCreate?.call(draft.$1, draft.$2);
  }

  void _cancel() => setState(() {
    _anchor = null;
    _current = null;
  });

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final labelStyle = text.labelSmall!.copyWith(color: c.textSecondary);
    final labelWidth = (TextPainter(
      text: TextSpan(text: '00:00', style: labelStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout()).width;
    final gutter = labelWidth + 20;
    final height =
        PlanTimeline.verticalPadding * 2 +
        24 * PlanTimeline.hourHeight +
        widget.bottomPadding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final left = gutter + 4;
        final width = math.max(0.0, constraints.maxWidth - left - 12);
        final placed = _layout(widget.blocks);
        final draft = _draft;
        final hint = widget.hint;
        return SingleChildScrollView(
          controller: _scroll,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: _start,
            onLongPressMoveUpdate: _move,
            onLongPressEnd: _end,
            onLongPressCancel: _cancel,
            child: SizedBox(
              key: PlanTimeline.contentKey,
              height: height,
              width: constraints.maxWidth,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GridPainter(
                        line: c.line,
                        labelStyle: labelStyle,
                        gutter: gutter,
                        textScaler: scaler,
                      ),
                    ),
                  ),
                  for (final g in widget.suggestions)
                    if (g.endMin > g.startMin)
                      Positioned(
                        left: left,
                        width: width,
                        top: PlanTimeline.offsetOf(g.startMin) + 1,
                        height: _span(g.startMin, g.endMin) - 2,
                        child: GhostBlockTile(
                          block: g,
                          color: blockColor(context, g.colorIdx),
                          onTap: widget.onKeepSuggestion == null
                              ? null
                              : () => widget.onKeepSuggestion!(g),
                        ),
                      ),
                  if (hint != null && draft == null && widget.suggestions.isEmpty)
                    Positioned(
                      left: left,
                      width: width,
                      top: PlanTimeline.offsetOf(hint.$1) + 1,
                      height: _span(hint.$1, hint.$2) - 2,
                      child: _AddHint(
                        onTap: widget.onHintTap == null
                            ? null
                            : () => widget.onHintTap!(hint.$1, hint.$2),
                      ),
                    ),
                  for (final p in placed)
                    Positioned(
                      left: left + width * p.column / p.columns,
                      width: width / p.columns,
                      top: PlanTimeline.offsetOf(p.block.startMin) + 1,
                      height: _span(p.block.startMin, p.block.endMin) - 2,
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: p.column < p.columns - 1 ? 3 : 0,
                        ),
                        child: PlanBlockTile(
                          name: p.block.name,
                          startMin: p.block.startMin,
                          endMin: p.block.endMin,
                          color: blockColor(context, p.block.colorIdx),
                          onTap: widget.onBlockTap == null
                              ? null
                              : () => widget.onBlockTap!(p.block),
                        ),
                      ),
                    ),
                  if (widget.nowMinute case final now?)
                    Positioned(
                      left: gutter - 4,
                      right: 0,
                      top: PlanTimeline.offsetOf(now) - 4,
                      height: 8,
                      child: IgnorePointer(child: _NowLine(color: c.accent)),
                    ),
                  if (draft != null)
                    Positioned(
                      left: left,
                      width: width,
                      top: PlanTimeline.offsetOf(draft.$1) + 1,
                      height: _span(draft.$1, draft.$2) - 2,
                      child: IgnorePointer(
                        child: PlanBlockTile(
                          name: 'New block',
                          startMin: draft.$1,
                          endMin: draft.$2,
                          color: c.accent,
                          emphasised: true,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static double _span(int startMin, int endMin) =>
      (endMin - startMin) / 60 * PlanTimeline.hourHeight;

  /// Assigns overlapping blocks to side-by-side columns. Blocks are taken
  /// in start order; each goes into the first column that is free at its
  /// start, and every block in a run of overlaps gets that run's column
  /// count, so widths line up.
  static List<_Placed> _layout(List<PlanBlock> blocks) {
    final sorted = [
      for (final b in blocks)
        if (b.endMin > b.startMin) b,
    ]..sort((a, b) {
        final byStart = a.startMin.compareTo(b.startMin);
        return byStart != 0 ? byStart : b.endMin.compareTo(a.endMin);
      });
    final result = <_Placed>[];
    var cluster = <_Placed>[];
    var columnEnds = <int>[];
    var clusterEnd = -1;

    void flush() {
      final count = columnEnds.length;
      for (final p in cluster) {
        result.add(_Placed(p.block, p.column, count));
      }
      cluster = [];
      columnEnds = [];
    }

    for (final b in sorted) {
      if (b.startMin >= clusterEnd) flush();
      var column = columnEnds.indexWhere((end) => end <= b.startMin);
      if (column < 0) {
        column = columnEnds.length;
        columnEnds.add(b.endMin);
      } else {
        columnEnds[column] = b.endMin;
      }
      cluster.add(_Placed(b, column, 0));
      clusterEnd = math.max(clusterEnd, b.endMin);
    }
    flush();
    return result;
  }
}

class _Placed {
  const _Placed(this.block, this.column, this.columns);

  final PlanBlock block;
  final int column;
  final int columns;
}

/// One block on the timeline: a soft fill and outline in the block's
/// colour, a solid stripe on the leading edge, the name and the time.
///
/// The words stay in the theme's text colours, never the block colour,
/// because the fill is itself tinted (the rule in DriftColors). How much
/// text shows depends on the height: two lines, one line, or none for a
/// sliver, so a short block never overflows.
class PlanBlockTile extends StatelessWidget {
  const PlanBlockTile({
    super.key,
    required this.name,
    required this.startMin,
    required this.endMin,
    required this.color,
    this.onTap,
    this.emphasised = false,
  });

  final String name;
  final int startMin;
  final int endMin;
  final Color color;
  final VoidCallback? onTap;

  /// The block being drawn: a stronger fill so it reads as live.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final nameStyle = text.titleSmall!.copyWith(
      color: c.text,
      fontWeight: FontWeight.w500,
    );
    final timeStyle = text.bodySmall!.copyWith(color: c.textSecondary);
    final nameHeight = scaler.scale(14) * 20 / 14;
    final timeHeight = scaler.scale(12) * 16 / 12;
    final fill = Color.alphaBlend(
      color.withValues(alpha: emphasised ? 0.26 : 0.13),
      c.bg,
    );

    return Semantics(
      button: onTap != null,
      label: '$name, ${formatRange(startMin, endMin)}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(
              color: color.withValues(alpha: emphasised ? 0.9 : 0.45),
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: color),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final h = box.maxHeight;
                    if (h >= nameHeight + timeHeight + 12) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(9, 5, 8, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: nameStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              formatRange(startMin, endMin),
                              style: timeStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      );
                    }
                    if (h >= nameHeight + 2) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        child: Row(
                          children: [
                            Flexible(
                              flex: 3,
                              child: Text(
                                name,
                                style: nameStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              flex: 2,
                              child: Text(
                                formatRange(startMin, endMin),
                                style: timeStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A suggested block (plan from history, option B): a dashed outline in
/// the block's colour, the name and range in secondary text, and a + to
/// keep it. Shorter blocks drop the range, then the words, as
/// [PlanBlockTile] does.
class GhostBlockTile extends StatelessWidget {
  const GhostBlockTile({
    super.key,
    required this.block,
    required this.color,
    this.onTap,
  });

  final PlanBlock block;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final nameStyle = text.titleSmall!.copyWith(
      color: c.textSecondary,
      fontWeight: FontWeight.w500,
    );
    final timeStyle = text.bodySmall!.copyWith(color: c.textSecondary);
    final nameHeight = scaler.scale(14) * 20 / 14;
    final timeHeight = scaler.scale(12) * 16 / 12;
    final range = formatRange(block.startMin, block.endMin);
    return Semantics(
      button: onTap != null,
      label: 'Suggested: ${block.name}, $range. Add it',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: DashedBorderPainter(color: color.withValues(alpha: 0.6)),
          child: LayoutBuilder(
            builder: (context, box) {
              final h = box.maxHeight;
              final plus = Icon(Icons.add, size: 18, color: c.textSecondary);
              if (h >= nameHeight + timeHeight + 12) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 5, 8, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(block.name, style: nameStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(range, style: timeStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      plus,
                    ],
                  ),
                );
              }
              if (h >= nameHeight + 2) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(block.name, style: nameStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      plus,
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }
}

/// The dashed "Drag to add a block" target in a free hour. Tapping it
/// adds a block for that hour, for people who never find the long-press.
class _AddHint extends StatelessWidget {
  const _AddHint({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final style = Theme.of(
      context,
    ).textTheme.labelLarge!.copyWith(color: c.textSecondary);
    return Semantics(
      button: true,
      label: 'Drag to add a block',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: DashedBorderPainter(
            color: c.textSecondary.withValues(alpha: 0.55),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 18, color: c.textSecondary),
                    const SizedBox(width: 6),
                    Text('Drag to add a block', style: style),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.6),
      const Radius.circular(10),
    );
    final path = Path()..addRRect(rrect);
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) => old.color != color;
}

class _NowLine extends StatelessWidget {
  const _NowLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Expanded(child: Container(height: 1.5, color: color)),
      ],
    );
  }
}

/// Hour lines across the day with "hh:00" labels in the left gutter, and
/// fainter half-hour lines so a 30-minute block lines up by eye.
class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.line,
    required this.labelStyle,
    required this.gutter,
    required this.textScaler,
  });

  final Color line;
  final TextStyle labelStyle;
  final double gutter;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final hourPaint = Paint()
      ..color = line
      ..strokeWidth = 1;
    final halfPaint = Paint()
      ..color = line.withValues(alpha: line.a * 0.5)
      ..strokeWidth = 1;
    for (var h = 0; h <= 24; h++) {
      final y = PlanTimeline.offsetOf(h * 60);
      canvas.drawLine(Offset(gutter, y), Offset(size.width, y), hourPaint);
      if (h < 24) {
        final half = PlanTimeline.offsetOf(h * 60 + 30);
        canvas.drawLine(
          Offset(gutter + 8, half),
          Offset(size.width, half),
          halfPaint,
        );
      }
      final label = TextPainter(
        text: TextSpan(text: formatMinute(h * 60), style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      label.paint(
        canvas,
        Offset(gutter - 10 - label.width, y - label.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.line != line ||
      old.labelStyle != labelStyle ||
      old.gutter != gutter ||
      old.textScaler != textScaler;
}
