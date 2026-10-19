import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../painters/lane_painter.dart';
import '../services/day_loader.dart';
import '../theme/drift_theme.dart';

/// Today option A: the plan as blocks across the day, with a narrow lane of
/// what actually happened laid over the right edge of each block.
///
/// The hour grid, the block outlines and the actual lane are painted, so
/// the widget count does not grow with the number of segments. Each drawn
/// piece gets one Semantics box for screen readers and finders; taps go
/// through one GestureDetector over the lane and are resolved by y.
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

/// Pieces shorter than this fold into a neighbour when drawn.
const _foldBelow = Duration(minutes: 2);

/// Pieces further apart than this never merge or fold together.
const _joinGap = Duration(minutes: 2);

/// The pieces the actual lane draws for [segments]. Drawing only: the
/// segments themselves are untouched.
///
/// - Unplanned idle time is dropped; an empty evening is not news.
/// - Neighbours in the same block, less than 2 minutes apart, with the same
///   verdict and package, merge.
/// - A piece shorter than 2 minutes folds into the previous piece in the
///   same block, or into the next one when it comes first.
/// - A merged piece takes the verdict and label of its longest member,
///   and a tap on it opens that member.
@visibleForTesting
List<LanePiece> drawnLanePieces(List<Segment> segments) {
  final visible = [
    for (final s in segments)
      if (_visible(s)) s,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final out = <_PieceBuilder>[];
  for (final s in visible) {
    final last = out.isEmpty ? null : out.last;
    if (last != null &&
        last.joins(s) &&
        (last.sameKind(s) ||
            s.duration < _foldBelow ||
            last.duration < _foldBelow)) {
      last.add(s);
      continue;
    }
    out.add(_PieceBuilder(s));
  }
  return [for (final b in out) b.build()];
}

bool _visible(Segment s) =>
    !(s.verdict == Verdict.unplanned && s.p == null) && s.end.isAfter(s.start);

class _PieceBuilder {
  _PieceBuilder(Segment s) : start = s.start, end = s.end, primary = s {
    members.add(s);
  }

  final DateTime start;
  DateTime end;
  Segment primary;
  final members = <Segment>[];

  Duration get duration => end.difference(start);

  bool joins(Segment s) =>
      s.blockName == primary.blockName && s.start.difference(end) < _joinGap;

  bool sameKind(Segment s) => s.verdict == primary.verdict && s.p == primary.p;

  void add(Segment s) {
    members.add(s);
    if (s.end.isAfter(end)) end = s.end;
    if (s.duration > primary.duration) primary = s;
  }

  LanePiece build() => LanePiece(
    start: start,
    end: end,
    primary: primary,
    members: List.unmodifiable(members),
  );
}

class _TimelineLanesState extends State<TimelineLanes> {
  late final ScrollController _scroll;
  late List<LanePiece> _pieces;
  late int _start;
  LaneLayout? _layout;
  Object? _layoutKey;

  /// The hour gutter at normal text size; it widens with large text so
  /// "12:00" stays on one line.
  static const _minGutter = 46.0;
  static const _laneWidth = 76.0;

  /// The view starts at 06:00, or earlier when something happened before.
  int _startHourOf(DayData data) {
    var h = 6;
    for (final b in data.blocks) {
      if (_sameDay(b.start)) h = math.min(h, b.start.hour);
    }
    for (final s in data.segments) {
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
    final hours =
        t.difference(widget.data.day).inMicroseconds / Duration.microsecondsPerHour;
    return (hours - _start) * widget.hourHeight;
  }

  @override
  void initState() {
    super.initState();
    _pieces = drawnLanePieces(widget.data.segments);
    _start = _startHourOf(widget.data);
    final now = widget.data.now;
    final offset = _sameDay(now)
        ? math.max(0.0, _y(now) - widget.hourHeight * 1.5)
        : math.max(0.0, (8 - _start) * widget.hourHeight);
    _scroll = ScrollController(initialScrollOffset: offset);
  }

  @override
  void didUpdateWidget(TimelineLanes old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _pieces = drawnLanePieces(widget.data.segments);
      _start = _startHourOf(widget.data);
    }
  }

  @override
  void dispose() {
    _layout?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The lane geometry, rebuilt only when something it depends on changes.
  LaneLayout _laneLayout(DriftColors c, TextStyle labelStyle, TextScaler scaler) {
    final key = (
      _pieces,
      _start,
      widget.hourHeight,
      c.onTrack,
      c.offTrack,
      c.guessed,
      c.line,
      c.text,
      c.textSecondary,
      c.bg,
      labelStyle,
      scaler,
    );
    final current = _layout;
    if (current != null && key == _layoutKey) return current;
    final next = LaneLayout.build(
      pieces: _pieces,
      labelOf: widget.data.labelOf,
      yOf: _y,
      left: 6,
      width: _laneWidth - 12,
      colors: c,
      labelStyle: labelStyle,
      textScaler: scaler,
    );
    _layout = next;
    _layoutKey = key;
    // The old layout's labels may still be in this frame's paint; release
    // them once it is done.
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    // The same style a Text widget would resolve here.
    var base = DefaultTextStyle.of(context).style;
    if (MediaQuery.boldTextOf(context)) {
      base = base.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final labelSmall = base.merge(text.labelSmall);
    final hourStyle = labelSmall.copyWith(color: c.textSecondary);
    // DayGridPainter lays hour labels out in gutter - 8.
    final hourWidth = (TextPainter(
      text: TextSpan(text: '00:00', style: hourStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout()).width;
    final gutter = math.max(_minGutter, hourWidth.ceilToDouble() + 10);
    final start = _start;
    final height = (24 - start) * widget.hourHeight;
    final now = widget.data.now;
    final showNow = _sameDay(now);
    final layout = _laneLayout(c, labelSmall, scaler);
    final onTap = widget.onSegmentTap;

    final blocks = [
      for (final b in widget.data.blocks)
        (_y(b.start) + 1, math.max(18.0, _y(b.end) - _y(b.start) - 2)),
    ];

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 24, top: 8),
      child: RepaintBoundary(
        child: SizedBox(
          height: height + 8,
          child: CustomPaint(
            painter: DayGridPainter(
              startHour: start,
              hourHeight: widget.hourHeight,
              gutter: gutter,
              blocks: blocks,
              lineColor: c.line.withValues(alpha: 0.6),
              planFill: c.planFill,
              planBorder: c.planBorder,
              hourStyle: hourStyle,
              textScaler: scaler,
            ),
            foregroundPainter: showNow
                ? NowLinePainter(y: _y(now), gutter: gutter, color: c.offTrack)
                : null,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Inside the 1 px border, then padded 10, 4, lane width, 4.
                for (var i = 0; i < blocks.length; i++)
                  Positioned(
                    left: gutter + 4 + 1 + 10,
                    right: _laneWidth + 1,
                    top: blocks[i].$1 + 1 + 4,
                    height: blocks[i].$2 - 2 - 8,
                    child: Text(
                      widget.data.blocks[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                        color: c.accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: _laneWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTapUp: onTap == null
                        ? null
                        : (d) {
                            final piece = layout.pieceAt(d.localPosition.dy);
                            if (piece != null) onTap(piece.primary);
                          },
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: LanePainter(layout),
                        child: Stack(
                          children: [
                            for (final s in layout.shapes)
                              Positioned.fromRect(
                                rect: s.rect,
                                child: Semantics(
                                  container: true,
                                  label: s.semanticsLabel,
                                  button: onTap != null,
                                  onTap: onTap == null
                                      ? null
                                      : () => onTap(s.piece.primary),
                                  child: const MetaData(
                                    behavior: HitTestBehavior.opaque,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
