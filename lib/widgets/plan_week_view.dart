import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../theme/drift_theme.dart';
import 'plan_timeline.dart' show blockColor, formatRange;

/// "Mon 19 Oct", the day wording of the week view's sheets and toasts.
String shortDayLabel(DateTime day) => DateFormat('EEE d MMM').format(day);

/// The first day of the week holding [day], on [firstWeekday]
/// ([DateTime.monday] to [DateTime.sunday]), as the Review tab counts
/// weeks.
DateTime planWeekStart(DateTime day, int firstWeekday) {
  final back = (day.weekday - firstWeekday + 7) % 7;
  return DateTime(day.year, day.month, day.day - back);
}

/// "12 to 18 Oct", "26 Oct to 1 Nov", or "28 Dec 2026 to 3 Jan 2027" for
/// the week starting [start], worded as the Review tab words weeks. The
/// year is added when the week is outside [today]'s year.
String planWeekLabel(DateTime start, DateTime today) {
  final end = DateTime(start.year, start.month, start.day + 6);
  if (start.year != end.year) {
    final dmy = DateFormat('d MMM yyyy');
    return '${dmy.format(start)} to ${dmy.format(end)}';
  }
  final dm = DateFormat('d MMM');
  final year = end.year == today.year ? '' : ' ${end.year}';
  if (start.month == end.month) return '${start.day} to ${dm.format(end)}$year';
  return '${dm.format(start)} to ${dm.format(end)}$year';
}

/// The Plan tab's week: seven mini columns, one per day, each drawing that
/// day's live blocks ([activeBlocks]) as small tiles placed by time.
///
/// Every column shares one time axis, from 06:00 (or the hour of the
/// week's earliest block, when that is earlier) to 24:00, so the same time
/// lines up across the week. A day with no blocks is a dashed outline.
/// Tapping a day goes to [onDayTap]; holding it goes to [onDayLongPress].
class PlanWeekView extends StatelessWidget {
  const PlanWeekView({
    super.key,
    required this.days,
    required this.blocks,
    required this.today,
    this.nowMinute,
    this.onDayTap,
    this.onDayLongPress,
  });

  /// The seven days shown, in order.
  final List<DateTime> days;

  /// Every live block; each column picks its own with [activeBlocks].
  final List<PlanBlock> blocks;

  /// Local midnight today, for the highlighted column.
  final DateTime today;

  /// Minute of the day for the "now" line on today's column, if shown.
  final int? nowMinute;

  final ValueChanged<DateTime>? onDayTap;
  final ValueChanged<DateTime>? onDayLongPress;

  /// The key of [day]'s column, for tests.
  static ValueKey<String> dayKey(DateTime day) =>
      ValueKey('planWeekDay${dateKey(day)}');

  /// Where the axis starts when no block is earlier: 06:00.
  static const defaultStartMin = 6 * 60;

  /// The first minute every column shows: [defaultStartMin], or the whole
  /// hour holding the earliest block's start when that is earlier.
  static int axisStart(Iterable<PlanBlock> blocks) {
    var start = defaultStartMin;
    for (final b in blocks) {
      if (b.endMin > b.startMin && b.startMin < start) {
        start = b.startMin ~/ 60 * 60;
      }
    }
    return start;
  }

  /// The labelled minutes on the axis: every three hours up to 24:00, plus
  /// the start when it is not one of those and has room for its label.
  static List<int> axisMarks(int start) {
    final first = (start + 179) ~/ 180 * 180;
    return [
      if (first != start && first - start >= 90) start,
      for (var m = first; m <= 1440; m += 180) m,
    ];
  }

  /// Space between a column's header and its body.
  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final perDay = [
      for (final d in days)
        [
          for (final b in activeBlocks(d, blocks))
            if (b.endMin > b.startMin) b,
        ],
    ];
    final start = axisStart(perDay.expand((l) => l));
    final marks = axisMarks(start);
    final labelStyle = text.labelSmall!.copyWith(color: c.textSecondary);
    final gutter =
        (TextPainter(
              text: TextSpan(text: '00', style: labelStyle),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
            )..layout())
            .width +
        6;
    final headerHeight = _DayHeader.heightFor(scaler);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: gutter,
                  child: Padding(
                    padding: EdgeInsets.only(top: headerHeight + _gap),
                    child: CustomPaint(
                      painter: _AxisLabelPainter(
                        start: start,
                        marks: marks,
                        style: labelStyle,
                        textScaler: scaler,
                      ),
                    ),
                  ),
                ),
                for (var i = 0; i < days.length; i++)
                  Expanded(
                    child: _DayColumn(
                      key: dayKey(days[i]),
                      day: days[i],
                      blocks: perDay[i],
                      isToday: days[i] == today,
                      isPast: days[i].isBefore(today),
                      start: start,
                      marks: marks,
                      headerHeight: headerHeight,
                      nowMinute: days[i] == today ? nowMinute : null,
                      onTap: onDayTap == null
                          ? null
                          : () => onDayTap!(days[i]),
                      onLongPress: onDayLongPress == null
                          ? null
                          : () => onDayLongPress!(days[i]),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 0, 12),
            child: Text(
              'Tap to open a day. Hold to copy it.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day: its header over its body, tappable as a whole.
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.day,
    required this.blocks,
    required this.isToday,
    required this.isPast,
    required this.start,
    required this.marks,
    required this.headerHeight,
    this.nowMinute,
    this.onTap,
    this.onLongPress,
  });

  final DateTime day;
  final List<PlanBlock> blocks;
  final bool isToday;
  final bool isPast;
  final int start;
  final List<int> marks;
  final double headerHeight;
  final int? nowMinute;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final count = switch (blocks.length) {
      0 => 'no blocks',
      1 => '1 block',
      final n => '$n blocks',
    };
    return Semantics(
      button: true,
      label: '${DateFormat('EEEE d MMMM').format(day)}, $count',
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressHint: 'Copy to other days',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: headerHeight,
                  child: _DayHeader(day: day, isToday: isToday, isPast: isPast),
                ),
                const SizedBox(height: PlanWeekView._gap),
                Expanded(
                  child: _DayBody(
                    blocks: blocks,
                    isToday: isToday,
                    start: start,
                    marks: marks,
                    nowMinute: nowMinute,
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

/// The weekday letter over the date. Today's date sits in an accent disc
/// with on-accent text; past dates are in the secondary colour.
class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.isToday,
    required this.isPast,
  });

  final DateTime day;
  final bool isToday;
  final bool isPast;

  static double _letterHeight(TextScaler s) => s.scale(11) * 16 / 11;

  static double _discSize(TextScaler s) => s.scale(14) * 20 / 14 + 8;

  /// The header's height at [scaler]; every column and the axis gutter use
  /// it, so the bodies line up with the axis labels.
  static double heightFor(TextScaler scaler) =>
      _letterHeight(scaler) + 3 + _discSize(scaler);

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final disc = _discSize(scaler);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            DateFormat('EEEEE').format(day),
            style: text.labelSmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 3),
          Container(
            width: disc,
            height: disc,
            alignment: Alignment.center,
            decoration: isToday
                ? BoxDecoration(color: c.accent, shape: BoxShape.circle)
                : null,
            child: Text(
              '${day.day}',
              style: text.titleSmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: isToday
                    ? c.onAccent
                    : (isPast ? c.textSecondary : c.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A day's time column: a card with faint three-hour lines and the day's
/// blocks, or a dashed outline when the day has none.
class _DayBody extends StatelessWidget {
  const _DayBody({
    required this.blocks,
    required this.isToday,
    required this.start,
    required this.marks,
    this.nowMinute,
  });

  final List<PlanBlock> blocks;
  final bool isToday;
  final int start;
  final List<int> marks;
  final int? nowMinute;

  static const _radius = 8.0;

  /// Space between a tile and the column's sides.
  static const _inset = 2.0;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final edge = isToday ? c.accent.withValues(alpha: 0.6) : c.line;
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight;
        final inner = math.max(0.0, box.maxWidth - _inset * 2);
        double y(int minute) => (minute - start) / (1440 - start) * h;
        final now = nowMinute;
        final showNow = now != null && now >= start && now <= 1440;

        if (blocks.isEmpty) {
          return CustomPaint(
            painter: _DashedOutlinePainter(
              color: isToday ? edge : c.textSecondary.withValues(alpha: 0.45),
              radius: _radius,
            ),
            child: showNow
                ? Stack(children: [_nowLine(c.accent, y(now))])
                : const SizedBox.expand(),
          );
        }

        return DecoratedBox(
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: edge),
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ColumnGridPainter(
                    ys: [
                      for (final m in marks)
                        if (m > start && m < 1440) y(m),
                    ],
                    color: c.line,
                  ),
                ),
              ),
              for (final p in layoutWeekBlocks(blocks))
                Positioned(
                  left: _inset + inner * p.column / p.columns,
                  width:
                      inner / p.columns - (p.column < p.columns - 1 ? 1 : 0),
                  top: y(p.block.startMin) + 1,
                  height: math.max(
                    3.0,
                    y(p.block.endMin) - y(p.block.startMin) - 2,
                  ),
                  child: _MiniBlock(
                    name: p.block.name,
                    color: blockColor(context, p.block.colorIdx),
                  ),
                ),
              if (showNow) _nowLine(c.accent, y(now)),
            ],
          ),
        );
      },
    );
  }

  static Widget _nowLine(Color color, double y) => Positioned(
    left: 0,
    right: 0,
    top: y - 3,
    height: 6,
    child: IgnorePointer(
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(child: Container(height: 1.5, color: color)),
        ],
      ),
    ),
  );
}

/// A block as a small tile: the day timeline's look (a soft fill and
/// outline in the block's colour with a solid leading stripe) and the name
/// in the theme's text colour when there is room for it.
class _MiniBlock extends StatelessWidget {
  const _MiniBlock({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    // No extra letter spacing: in a tile this narrow it costs a letter.
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(
      color: c.text,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final lineHeight = scaler.scale(11) * 16 / 11;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.16), c.card),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 2, color: color),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                // Room for the text after the padding below. Under about
                // two letters a name is noise, so the tile goes without.
                final width = box.maxWidth - 4;
                if (box.maxHeight < lineHeight + 2 || width < 22) {
                  return const SizedBox.shrink();
                }
                final lines = ((box.maxHeight - 2) / lineHeight).floor().clamp(
                  1,
                  3,
                );
                // Wrapping only between words: a word wider than the tile
                // would otherwise be split mid-word ("Famil / y"), so then
                // the name stays on one line and ends in an ellipsis.
                final wraps =
                    lines > 1 &&
                    name.split(' ').every(
                      (word) =>
                          (TextPainter(
                                text: TextSpan(text: word, style: style),
                                textDirection: TextDirection.ltr,
                                textScaler: scaler,
                                maxLines: 1,
                              )..layout())
                              .width <=
                          width,
                    );
                return Padding(
                  padding: const EdgeInsets.fromLTRB(3, 1, 1, 0),
                  child: Text(
                    name,
                    style: style,
                    maxLines: wraps ? lines : 1,
                    softWrap: wraps,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A block with its side-by-side slot among the blocks it overlaps.
class WeekPlacedBlock {
  const WeekPlacedBlock(this.block, this.column, this.columns);

  final PlanBlock block;
  final int column;
  final int columns;
}

/// Puts overlapping blocks side by side, as the day timeline does: in
/// start order, each block takes the first slot free at its start, and
/// every block in a run of overlaps shares that run's slot count.
List<WeekPlacedBlock> layoutWeekBlocks(List<PlanBlock> blocks) {
  final sorted = [
    for (final b in blocks)
      if (b.endMin > b.startMin) b,
  ]..sort((a, b) {
      final byStart = a.startMin.compareTo(b.startMin);
      return byStart != 0 ? byStart : b.endMin.compareTo(a.endMin);
    });
  final result = <WeekPlacedBlock>[];
  var run = <(PlanBlock, int)>[];
  var slotEnds = <int>[];
  var runEnd = -1;

  void flush() {
    for (final (b, slot) in run) {
      result.add(WeekPlacedBlock(b, slot, slotEnds.length));
    }
    run = [];
    slotEnds = [];
  }

  for (final b in sorted) {
    if (b.startMin >= runEnd) flush();
    var slot = slotEnds.indexWhere((end) => end <= b.startMin);
    if (slot < 0) {
      slot = slotEnds.length;
      slotEnds.add(b.endMin);
    } else {
      slotEnds[slot] = b.endMin;
    }
    run.add((b, slot));
    runEnd = math.max(runEnd, b.endMin);
  }
  flush();
  return result;
}

/// The hour labels left of the columns ("06", "09" ... "24"), centred on
/// their lines and kept inside the gutter at the ends.
class _AxisLabelPainter extends CustomPainter {
  const _AxisLabelPainter({
    required this.start,
    required this.marks,
    required this.style,
    required this.textScaler,
  });

  final int start;
  final List<int> marks;
  final TextStyle style;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    for (final m in marks) {
      final label = TextPainter(
        text: TextSpan(
          text: (m ~/ 60).toString().padLeft(2, '0'),
          style: style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      final y = (m - start) / (1440 - start) * size.height;
      final top = (y - label.height / 2)
          .clamp(0.0, math.max(0.0, size.height - label.height))
          .toDouble();
      label.paint(canvas, Offset(size.width - 4 - label.width, top));
    }
  }

  @override
  bool shouldRepaint(_AxisLabelPainter old) =>
      old.start != start ||
      old.style != style ||
      old.textScaler != textScaler ||
      old.marks.length != marks.length;
}

/// Faint lines across a column at the axis marks.
class _ColumnGridPainter extends CustomPainter {
  const _ColumnGridPainter({required this.ys, required this.color});

  final List<double> ys;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final y in ys) {
      canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
    }
  }

  @override
  bool shouldRepaint(_ColumnGridPainter old) =>
      old.color != color ||
      old.ys.length != ys.length ||
      Iterable<int>.generate(ys.length).any((i) => old.ys[i] != ys[i]);
}

/// The dashed rounded outline of a day with no blocks.
class _DashedOutlinePainter extends CustomPainter {
  const _DashedOutlinePainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.6),
          Radius.circular(radius),
        ),
      );
    const dash = 4.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutlinePainter old) =>
      old.color != color || old.radius != radius;
}

/// Asks which saved template "Fill weekends" applies to [days] (the
/// week's Saturday and Sunday). Returns null when dismissed.
Future<PlanTemplate?> showFillWeekendsSheet(
  BuildContext context, {
  required List<PlanTemplate> templates,
  required List<DateTime> days,
}) => showModalBottomSheet<PlanTemplate>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text('Fill weekends with', style: text.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Replaces the one-off blocks on '
                '${days.map(shortDayLabel).join(' and ')}. '
                'Repeating blocks stay.',
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ),
            for (final t in templates)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.dashboard_customize_outlined),
                title: Text(t.name),
                subtitle: Text(_templateSummary(t)),
                onTap: () => Navigator.pop(context, t),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  },
);

/// "3 blocks, 08:00 to 21:00": how many blocks and the span they cover.
String _templateSummary(PlanTemplate t) {
  final blocks = t.blocks;
  if (blocks.isEmpty) return 'No blocks';
  final first = blocks.map((b) => b.startMin).reduce(math.min);
  final last = blocks.map((b) => b.endMin).reduce(math.max);
  final count = blocks.length == 1 ? '1 block' : '${blocks.length} blocks';
  return '$count, ${formatRange(first, last)}';
}

/// Asks which of [targets] to copy [source] to. Returns the picked days in
/// date order, or null when dismissed.
Future<List<DateTime>?> showCopyDaySheet(
  BuildContext context, {
  required DateTime source,
  required List<DateTime> targets,
}) => showModalBottomSheet<List<DateTime>>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => _CopyDaySheet(source: source, targets: targets),
);

class _CopyDaySheet extends StatefulWidget {
  const _CopyDaySheet({required this.source, required this.targets});

  final DateTime source;
  final List<DateTime> targets;

  @override
  State<_CopyDaySheet> createState() => _CopyDaySheetState();
}

class _CopyDaySheetState extends State<_CopyDaySheet> {
  final _picked = <DateTime>{};

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final all = _picked.length == widget.targets.length;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Copy ${shortDayLabel(widget.source)} to',
                      style: text.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (all) {
                        _picked.clear();
                      } else {
                        _picked.addAll(widget.targets);
                      }
                    }),
                    child: Text(all ? 'Clear' : 'Select all'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(
                'Replaces their one-off blocks. Repeating blocks stay.',
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ),
            for (final d in widget.targets)
              CheckboxListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(shortDayLabel(d)),
                value: _picked.contains(d),
                onChanged: (v) => setState(() {
                  if (v ?? false) {
                    _picked.add(d);
                  } else {
                    _picked.remove(d);
                  }
                }),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: FilledButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () => Navigator.pop(context, [
                        for (final d in widget.targets)
                          if (_picked.contains(d)) d,
                      ]),
                child: const Text('Copy'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
