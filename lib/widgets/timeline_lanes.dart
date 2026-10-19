import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../services/day_loader.dart';
import '../theme/drift_theme.dart';
import 'verdict_style.dart';

/// Today option A: the plan as blocks across the day, with a narrow lane of
/// what actually happened laid over the right edge of each block.
class TimelineLanes extends StatefulWidget {
  const TimelineLanes({
    super.key,
    required this.data,
    this.onSegmentTap,
    this.hourHeight = 64,
  });

  final DayData data;
  final void Function(Segment segment)? onSegmentTap;
  final double hourHeight;

  @override
  State<TimelineLanes> createState() => _TimelineLanesState();
}

class _TimelineLanesState extends State<TimelineLanes> {
  late final ScrollController _scroll;

  static const _gutter = 46.0;
  static const _laneWidth = 76.0;

  /// The view starts at 06:00, or earlier when something happened before.
  int get _startHour {
    var h = 6;
    for (final b in widget.data.blocks) {
      if (_sameDay(b.start)) h = math.min(h, b.start.hour);
    }
    for (final s in widget.data.segments) {
      if (s.verdict == Verdict.unplanned && s.p == null) continue;
      if (_sameDay(s.start)) h = math.min(h, s.start.hour);
    }
    return h;
  }

  bool _sameDay(DateTime t) =>
      t.year == widget.data.day.year &&
      t.month == widget.data.day.month &&
      t.day == widget.data.day.day;

  double _y(DateTime t) {
    final mins = t.difference(widget.data.day).inMinutes;
    return (mins / 60 - _startHour) * widget.hourHeight;
  }

  @override
  void initState() {
    super.initState();
    final now = widget.data.now;
    final offset = _sameDay(now)
        ? math.max(0.0, _y(now) - widget.hourHeight * 1.5)
        : math.max(0.0, (8 - _startHour) * widget.hourHeight);
    _scroll = ScrollController(initialScrollOffset: offset);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final start = _startHour;
    final height = (24 - start) * widget.hourHeight;
    final now = widget.data.now;
    final showNow = _sameDay(now);

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 24, top: 8),
      child: SizedBox(
        height: height + 8,
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                for (var h = start; h <= 24; h++) ...[
                  Positioned(
                    left: _gutter,
                    right: 0,
                    top: (h - start) * widget.hourHeight,
                    child: Divider(height: 1, color: c.line.withValues(alpha: 0.6)),
                  ),
                  Positioned(
                    left: 0,
                    width: _gutter - 8,
                    top: (h - start) * widget.hourHeight - 7,
                    child: Text(
                      '${(h % 24).toString().padLeft(2, '0')}:00',
                      textAlign: TextAlign.right,
                      style: text.labelSmall?.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
                for (final b in widget.data.blocks)
                  Positioned(
                    left: _gutter + 4,
                    right: 0,
                    top: _y(b.start) + 1,
                    height: math.max(18, _y(b.end) - _y(b.start) - 2),
                    child: _PlanBlockBox(
                      name: b.name,
                      laneWidth: _laneWidth,
                    ),
                  ),
                for (final s in widget.data.segments)
                  if (_visible(s))
                    Positioned(
                      right: 6,
                      width: _laneWidth - 12,
                      top: _y(s.start),
                      height: math.max(2, _y(s.end) - _y(s.start)),
                      child: _SegmentBar(
                        segment: s,
                        label: widget.data.labelOf(s.p),
                        onTap: widget.onSegmentTap == null
                            ? null
                            : () => widget.onSegmentTap!(s),
                      ),
                    ),
                if (showNow) ...[
                  Positioned(
                    left: _gutter - 4,
                    width: width - _gutter + 4,
                    top: _y(now) - 0.75,
                    child: Container(height: 1.5, color: c.offTrack),
                  ),
                  Positioned(
                    left: _gutter - 8,
                    top: _y(now) - 4,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.offTrack,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Unplanned idle time draws nothing: an empty evening is not news.
  bool _visible(Segment s) =>
      !(s.verdict == Verdict.unplanned && s.p == null) &&
      s.end.isAfter(s.start);
}

class _PlanBlockBox extends StatelessWidget {
  const _PlanBlockBox({required this.name, required this.laneWidth});

  final String name;
  final double laneWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Container(
      decoration: BoxDecoration(
        color: c.planFill,
        border: Border.all(color: c.planBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: EdgeInsets.fromLTRB(10, 4, laneWidth, 4),
      alignment: Alignment.topLeft,
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: c.accent,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SegmentBar extends StatelessWidget {
  const _SegmentBar({required this.segment, required this.label, this.onTap});

  final Segment segment;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final v = segment.verdict;
    final fill = verdictColor(c, v);
    final solid = v == Verdict.onTrack || v == Verdict.offTrack;
    final textColor = switch (v) {
      Verdict.onTrack || Verdict.offTrack => c.bg,
      _ => c.text,
    };
    return Semantics(
      label: '${label.isEmpty ? verdictLabel(v) : label}, ${verdictLabel(v)}',
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, box) {
            final tall = box.maxHeight >= 15;
            return CustomPaint(
              foregroundPainter: v == Verdict.noData
                  ? HatchPainter(c.textSecondary.withValues(alpha: 0.5))
                  : verdictDashed(v)
                  ? DashedBorderPainter(
                      color: v == Verdict.idle ? c.onTrack : c.guessed,
                    )
                  : null,
              child: Container(
                decoration: BoxDecoration(
                  color: v == Verdict.guessedOn || v == Verdict.guessedOff
                      ? fill.withValues(alpha: 0.28)
                      : fill,
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.centerLeft,
                child: tall && (label.isNotEmpty || v == Verdict.idle)
                    ? Text(
                        v == Verdict.idle ? 'idle' : label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: solid ? textColor : c.text,
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }
}
