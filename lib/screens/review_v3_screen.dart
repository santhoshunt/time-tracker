import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../painters/day_strip_painter.dart';
import '../painters/month_heatmap_painter.dart';
import '../painters/trend_painter.dart';
import '../painters/week_bars_painter.dart';
import '../providers/settings_provider.dart';
import '../services/day_loader.dart';
import '../services/period_loader.dart';
import '../services/review_summary.dart';
import '../theme/drift_theme.dart';
import '../widgets/score_bucket_style.dart';
import '../widgets/score_card.dart' show formatMinutes;

/// The Review tab for v0.3: underlined Day / Week / Month / Year tabs over
/// a pager per tab. Swiping right goes back one period and left goes
/// forward, never past the current one; the chevrons do the same, and a
/// "Back to this week" pill returns to the current period.
class ReviewV3Screen extends StatefulWidget {
  const ReviewV3Screen({
    super.key,
    this.firstWeekday = DateTime.monday,
    this.openDay,
  });

  /// The day weeks start on, [DateTime.monday] to [DateTime.sunday].
  final int firstWeekday;

  /// Set by the home shell when an evening summary is tapped: the screen
  /// opens that day in the Day view.
  final ValueListenable<DateTime?>? openDay;

  @override
  State<ReviewV3Screen> createState() => _ReviewV3ScreenState();
}

/// How far back each pager goes: about ten years.
const _maxBack = {
  ReviewPeriod.day: 3660,
  ReviewPeriod.week: 522,
  ReviewPeriod.month: 120,
  ReviewPeriod.year: 10,
};

/// Loaded periods kept for swiping back and forth.
const _cacheSize = 24;

String _noun(ReviewPeriod p) => switch (p) {
  ReviewPeriod.day => 'day',
  ReviewPeriod.week => 'week',
  ReviewPeriod.month => 'month',
  ReviewPeriod.year => 'year',
};

String _tabName(ReviewPeriod p) => switch (p) {
  ReviewPeriod.day => 'Day',
  ReviewPeriod.week => 'Week',
  ReviewPeriod.month => 'Month',
  ReviewPeriod.year => 'Year',
};

String _backLabel(ReviewPeriod p) =>
    p == ReviewPeriod.day ? 'Back to today' : 'Back to this ${_noun(p)}';

/// The centred label for the period starting at [anchor]: "Today",
/// "Sun 18 Oct", "12 to 18 Oct", "October 2026" or "2026". The year is
/// added to days and weeks outside the current year.
String reviewPeriodLabel(
  ReviewPeriod p,
  DateTime anchor,
  DateTime today, {
  int firstWeekday = DateTime.monday,
}) {
  switch (p) {
    case ReviewPeriod.day:
      if (anchor == today) return 'Today';
      return DateFormat(
        anchor.year == today.year ? 'EEE d MMM' : 'EEE d MMM yyyy',
      ).format(anchor);
    case ReviewPeriod.week:
      final r = weekOf(anchor, firstWeekday: firstWeekday);
      final a = r.start, b = r.end;
      final dm = DateFormat('d MMM');
      if (a.year != b.year) {
        final dmy = DateFormat('d MMM yyyy');
        return '${dmy.format(a)} to ${dmy.format(b)}';
      }
      final year = b.year == today.year ? '' : ' ${b.year}';
      if (a.month == b.month) return '${a.day} to ${dm.format(b)}$year';
      return '${dm.format(a)} to ${dm.format(b)}$year';
    case ReviewPeriod.month:
      return DateFormat('MMMM yyyy').format(anchor);
    case ReviewPeriod.year:
      return '${anchor.year}';
  }
}

/// One loaded period with the one before it, for the change and trend.
class _PeriodData {
  _PeriodData({
    required this.period,
    required this.range,
    required this.days,
    required this.prevDays,
  });

  final ReviewPeriod period;
  final DateTimeRange range;
  final List<DayData> days;
  final List<DayData> prevDays;

  late final PeriodSummary summary = summarize(days);
  late final PeriodSummary prev = summarize(prevDays);
  int? get delta => deltaPercent(summary, prev);
}

class _ReviewV3ScreenState extends State<ReviewV3Screen>
    with SingleTickerProviderStateMixin {
  late final AppServices _services;
  late final TabController _tabs;
  final _controllers = [for (final _ in ReviewPeriod.values) PageController()];
  final _offsets = List<int>.filled(ReviewPeriod.values.length, 0);

  /// Tabs opened at least once; only those build a pager, so the year
  /// does not load until it is asked for.
  final _visited = <int>{0};
  final _cache = <String, Future<_PeriodData>>{};

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _tabs = TabController(length: ReviewPeriod.values.length, vsync: this)
      ..addListener(_onTab);
    _services.revision.addListener(_onRevision);
    widget.openDay?.addListener(_onOpenDay);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onOpenDay());
  }

  void _onOpenDay() {
    final day = widget.openDay?.value;
    if (!mounted || day == null) return;
    _tabs.index = ReviewPeriod.day.index;
    _open(ReviewPeriod.day, day);
  }

  @override
  void dispose() {
    widget.openDay?.removeListener(_onOpenDay);
    _services.revision.removeListener(_onRevision);
    _tabs.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTab() {
    if (!mounted) return;
    setState(() => _visited.add(_tabs.index));
  }

  void _onRevision() {
    if (!mounted) return;
    setState(_cache.clear);
  }

  ReviewPeriod get _period => ReviewPeriod.values[_tabs.index];

  DateTime get _today {
    final n = _services.clock.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime _anchor(ReviewPeriod p, int offset) =>
      stepPeriod(p, _today, -offset, firstWeekday: widget.firstWeekday);

  Future<_PeriodData> _data(ReviewPeriod p, int offset) {
    final anchor = _anchor(p, offset);
    final key = '${p.name} ${dateKey(anchor)}';
    final hit = _cache[key];
    if (hit != null) return hit;
    while (_cache.length >= _cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return _cache[key] = _load(p, anchor);
  }

  Future<_PeriodData> _load(ReviewPeriod p, DateTime anchor) async {
    final fw = widget.firstWeekday;
    final range = periodOf(p, anchor, firstWeekday: fw);
    if (p == ReviewPeriod.day) {
      final days = await loadDays(_services, range.start, range.end);
      return _PeriodData(period: p, range: range, days: days, prevDays: const []);
    }
    final prevRange = periodOf(
      p,
      stepPeriod(p, anchor, -1, firstWeekday: fw),
      firstWeekday: fw,
    );
    final all = await loadDays(_services, prevRange.start, range.end);
    final split = all.indexWhere((d) => !d.day.isBefore(range.start));
    final cut = split < 0 ? all.length : split;
    return _PeriodData(
      period: p,
      range: range,
      days: all.sublist(cut),
      prevDays: all.sublist(0, cut),
    );
  }

  /// Where a chevron animation is heading, per tab, so taps made while
  /// one is still running add up instead of repeating the same step.
  final _targets = List<int?>.filled(ReviewPeriod.values.length, null);

  /// Moves the current tab [delta] periods: -1 is older, +1 newer.
  void _step(int delta) {
    final i = _tabs.index;
    final target = (_targets[i] ?? _offsets[i]) - delta;
    if (target < 0 || target > _maxBack[_period]!) return;
    _targets[i] = target;
    _controllers[i]
        .animateToPage(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (_targets[i] == target) _targets[i] = null;
        });
  }

  void _backToNow() {
    final i = _tabs.index;
    final c = _controllers[i];
    _targets[i] = null;
    if (_offsets[i] <= 1) {
      c.animateToPage(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      // Jumping skips loading every period in between.
      c.jumpToPage(0);
    }
  }

  /// Opens [p]'s tab at the period holding [day], from a tap on a day
  /// or month in a bigger view.
  void _open(ReviewPeriod p, DateTime day) {
    final i = p.index;
    final offset = periodsBetween(
      p,
      day,
      _today,
      firstWeekday: widget.firstWeekday,
    ).clamp(0, _maxBack[p]!);
    setState(() {
      _offsets[i] = offset;
      _targets[i] = null;
      if (_controllers[i].hasClients) {
        _controllers[i].jumpToPage(offset);
      } else {
        _controllers[i].dispose();
        _controllers[i] = PageController(initialPage: offset);
      }
      _visited.add(i);
    });
    _tabs.animateTo(i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final p = _period;
    final offset = _offsets[p.index];
    final label = reviewPeriodLabel(
      p,
      _anchor(p, offset),
      _today,
      firstWeekday: widget.firstWeekday,
    );
    final tabStyle = text.titleSmall?.copyWith(fontWeight: FontWeight.w500);

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Review', style: text.headlineSmall),
          ),
          TabBar(
            controller: _tabs,
            labelColor: c.text,
            unselectedLabelColor: c.textSecondary,
            labelStyle: tabStyle,
            unselectedLabelStyle: tabStyle,
            indicatorColor: c.accent,
            indicatorWeight: 2.5,
            dividerColor: c.line,
            // Narrow padding keeps "Month" whole at large text on 320 dp.
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              for (final q in ReviewPeriod.values) Tab(text: _tabName(q)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous ${_noun(p)}',
                  onPressed: offset < _maxBack[p]! ? () => _step(-1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      key: const ValueKey('review-period-label'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next ${_noun(p)}',
                  onPressed: offset > 0 ? () => _step(1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: p.index,
                    sizing: StackFit.expand,
                    children: [
                      for (final q in ReviewPeriod.values)
                        _visited.contains(q.index)
                            ? _pager(q)
                            : const SizedBox.shrink(),
                    ],
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: ScaleTransition(
                          scale: Tween(begin: 0.9, end: 1.0).animate(a),
                          child: child,
                        ),
                      ),
                      child: offset == 0
                          ? const SizedBox.shrink(key: ValueKey('no-pill'))
                          : _BackPill(
                              key: ValueKey('pill-${p.name}'),
                              label: _backLabel(p),
                              onTap: _backToNow,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pager(ReviewPeriod q) => PageView.builder(
    key: PageStorageKey('review-pager-${q.name}'),
    controller: _controllers[q.index],
    reverse: true,
    itemCount: _maxBack[q]! + 1,
    onPageChanged: (o) => setState(() => _offsets[q.index] = o),
    itemBuilder: (context, o) => _Loaded<_PeriodData>(
      future: _data(q, o),
      builder: (context, data) => switch (q) {
        ReviewPeriod.day => _DayView(data: data, today: _today),
        ReviewPeriod.week => _WeekView(
          data: data,
          today: _today,
          onOpenDay: (d) => _open(ReviewPeriod.day, d),
        ),
        ReviewPeriod.month => _MonthView(
          data: data,
          today: _today,
          firstWeekday: widget.firstWeekday,
          onOpenDay: (d) => _open(ReviewPeriod.day, d),
        ),
        ReviewPeriod.year => _YearView(
          data: data,
          today: _today,
          onOpenMonth: (d) => _open(ReviewPeriod.month, d),
        ),
      },
    ),
  );
}

/// Shows [builder]'s view once [future] completes. A new future keeps the
/// old view on screen until it lands, so a reload never flashes empty.
class _Loaded<T> extends StatefulWidget {
  const _Loaded({super.key, required this.future, required this.builder});

  final Future<T> future;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<_Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<_Loaded<T>> {
  T? _value;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _listen(widget.future);
  }

  @override
  void didUpdateWidget(_Loaded<T> old) {
    super.didUpdateWidget(old);
    if (!identical(old.future, widget.future)) _listen(widget.future);
  }

  void _listen(Future<T> f) {
    f.then(
      (v) {
        if (mounted && identical(f, widget.future)) {
          setState(() {
            _value = v;
            _failed = false;
          });
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('Review load failed: $e\n$st');
        if (mounted && identical(f, widget.future)) {
          setState(() => _failed = true);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    if (v == null && _failed) {
      return Center(
        child: Text(
          'Could not load this period',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: context.drift.textSecondary,
          ),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: v == null
          ? const SizedBox.expand(key: ValueKey('loading'))
          : KeyedSubtree(
              key: const ValueKey('loaded'),
              child: widget.builder(context, v),
            ),
    );
  }
}

// Shared pieces.

/// The scrolling body of one period; the bottom gap keeps the last card
/// clear of the Back pill.
class _Body extends StatelessWidget {
  const _Body({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
    children: children,
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: context.drift.textSecondary,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

/// An outlined pill: coloured border and text on the card, never coloured
/// text on a coloured fill.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color, this.border});

  final String text;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: border ?? color.withValues(alpha: 0.6)),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: color,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

/// The big on-track percent on the left, a pill and a caption on the right.
class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.percent, this.pill, this.caption});

  final int? percent;
  final Widget? pill;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final p = percent;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'On track',
              style: text.bodySmall?.copyWith(color: c.textSecondary),
            ),
            Text(
              p == null ? 'No score yet' : '$p%',
              style: p == null
                  ? text.titleLarge?.copyWith(fontWeight: FontWeight.w500)
                  : text.headlineMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ?pill,
              if (pill != null && caption != null) const SizedBox(height: 6),
              if (caption != null)
                Text(
                  caption!,
                  textAlign: TextAlign.end,
                  style: text.bodySmall?.copyWith(color: c.textSecondary),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The change against the previous period as a pill: on-track when
/// better, off-track when worse, plain when equal or unknown.
Widget _deltaPill(BuildContext context, _PeriodData d) {
  final c = context.drift;
  final noun = _noun(d.period);
  final delta = d.delta;
  final String words;
  if (delta == null) {
    words = 'No score last $noun';
  } else if (delta == 0) {
    words = 'Same as last $noun';
  } else {
    words = '${delta > 0 ? '+' : '−'}${delta.abs()} vs last $noun';
  }
  final color = deltaColor(c, delta);
  return _Pill(
    text: words,
    color: color,
    border: delta == null || delta == 0 ? c.line : null,
  );
}

String _plannedCaption(int minutes, bool current) =>
    'of ${formatMinutes(minutes)} planned${current ? ' so far' : ''}';

/// The period's score card for week, month and year.
class _PeriodScore extends StatelessWidget {
  const _PeriodScore({required this.data, required this.today});

  final _PeriodData data;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final s = data.summary;
    final current = !today.isBefore(data.range.start) &&
        !today.isAfter(data.range.end);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: _ScoreRow(
          percent: s.percent,
          pill: s.percent == null ? null : _deltaPill(context, data),
          caption: s.plannedMin == 0
              ? null
              : _plannedCaption(s.plannedMin, current),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.title, required this.body, this.icon});

  final String title;
  final String body;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
        child: Column(
          children: [
            Icon(
              icon ?? Icons.event_busy_outlined,
              size: 32,
              color: c.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label on the left and a value on the right, for the summary rows.
class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Text(label, style: text.bodyLarge),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: text.bodyMedium?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _RowsCard extends StatelessWidget {
  const _RowsCard(this.rows);

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, indent: 16, color: context.drift.line),
          rows[i],
        ],
      ],
    ),
  );
}

/// "Top drift apps": up to five apps with their off-track minutes.
List<Widget> _topDrift(
  BuildContext context,
  List<(String, int)> apps,
  String Function(String) labelOf,
) {
  if (apps.isEmpty) return const [];
  final c = context.drift;
  final text = Theme.of(context).textTheme;
  final shown = apps.take(5).toList();
  return [
    const _Heading('Top drift apps'),
    Card(
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, color: c.line),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(labelOf(shown[i].$1), style: text.bodyLarge),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    formatMinutes(shown[i].$2),
                    style: text.bodyMedium?.copyWith(color: c.offTrack),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  ];
}

class _BackPill extends StatelessWidget {
  const _BackPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Material(
      color: c.accent,
      shape: const StadiumBorder(),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.today, size: 18, color: c.onAccent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: c.onAccent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Day: option B.

class _DayView extends StatelessWidget {
  const _DayView({required this.data, required this.today});

  final _PeriodData data;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final day = data.days.single;
    final isToday = day.day == today;

    if (day.blocks.isEmpty) {
      return _Body(
        children: [
          _EmptyCard(
            title: isToday ? 'Nothing planned today' : 'Nothing planned this day',
            body: 'Days with plan blocks get a score here.',
          ),
        ],
      );
    }
    if (day.segments.isEmpty) {
      return _Body(
        children: [
          _EmptyCard(
            icon: Icons.hourglass_empty,
            title: isToday ? 'No data yet today' : 'No data for this day',
            body: isToday
                ? 'App use shows up here once Drift has read it.'
                : 'Drift was not tracking yet, so this day has no score.',
          ),
        ],
      );
    }

    final s = day.score;
    final hourStyle = text.bodySmall?.copyWith(color: c.textSecondary);
    return _Body(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ScoreRow(
                  percent: s?.percent,
                  pill: s == null
                      ? null
                      : _Pill(
                          text: s.offMin == 0
                              ? 'No drift'
                              : '${formatMinutes(s.offMin)} drift',
                          color: s.offMin == 0 ? c.onTrack : c.offTrack,
                        ),
                  caption: s == null
                      ? null
                      : _plannedCaption(s.plannedMin, isToday),
                ),
                const SizedBox(height: 16),
                Semantics(
                  label: 'The day from midnight to midnight, by verdict',
                  child: SizedBox(
                    height: 26,
                    child: CustomPaint(
                      painter: DayStripPainter(
                        day: day.day,
                        blocks: day.blocks,
                        segments: day.segments,
                        now: day.now,
                        colors: c,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Stack(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('0', style: hourStyle),
                    ),
                    Align(
                      alignment: Alignment.center,
                      child: Text('12', style: hourStyle),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text('24', style: hourStyle),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const _Heading('Block by block'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final b in day.blocks) _BlockBar(data: day, block: b),
                const SizedBox(height: 2),
                ReviewLegend(
                  items: [
                    LegendItem('On track', c.onTrack),
                    // Only on a day that has some, as few answers are neutral.
                    if (day.segments.any((s) => s.verdict == Verdict.neutral))
                      LegendItem('Neutral', c.neutral),
                    LegendItem('Idle', c.idleFill),
                    LegendItem('Off track', c.offTrack),
                    LegendItem('Not reached', c.line),
                  ],
                ),
              ],
            ),
          ),
        ),
        ..._topDrift(context, day.topDrift, day.labelOf),
      ],
    );
  }
}

/// One block's planned time split into on track, idle and off track; the
/// rest (still ahead, or no data) stays the bare track.
class _BlockBar extends StatelessWidget {
  const _BlockBar({required this.data, required this.block});

  final DayData data;
  final ResolvedBlock block;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    var on = 0, neutral = 0, idle = 0, off = 0;
    for (final s in data.segments) {
      if (s.blockName != block.name) continue;
      if (!s.end.isAfter(block.start) || !s.start.isBefore(block.end)) continue;
      final a = s.start.isBefore(block.start) ? block.start : s.start;
      final b = s.end.isAfter(block.end) ? block.end : s.end;
      final secs = b.difference(a).inSeconds;
      switch (s.verdict) {
        case Verdict.offTrack || Verdict.guessedOff:
          off += secs;
        case Verdict.idle:
          idle += secs;
        case Verdict.onTrack || Verdict.guessedOn:
          on += secs;
        case Verdict.neutral:
          neutral += secs;
        case Verdict.unplanned || Verdict.noData:
          break;
      }
    }
    final planned = block.end.difference(block.start).inSeconds;
    final total = planned == 0 ? 1 : planned;
    int flex(int v) => (v * 1000 ~/ total).clamp(0, 1000);
    final rest =
        (1000 - flex(on) - flex(neutral) - flex(idle) - flex(off)).clamp(0, 1000);
    final time = DateFormat('HH:mm');
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: block.name, style: text.bodyLarge),
                      TextSpan(
                        text:
                            '  ${time.format(block.start)} to ${time.format(block.end)}',
                        style: text.bodySmall?.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                off > 0
                    ? '${formatMinutes(off ~/ 60)} drift'
                    : block.start.isBefore(data.now)
                        ? 'No drift'
                        : 'Not started',
                style: text.bodySmall?.copyWith(
                  color: off == 0 ? c.textSecondary : c.offTrack,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              // Stretch, because a ColoredBox without a child takes the
              // smallest height it is allowed, which is zero otherwise.
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (flex(on) > 0)
                    Expanded(flex: flex(on), child: ColoredBox(color: c.onTrack)),
                  if (flex(neutral) > 0)
                    Expanded(flex: flex(neutral), child: ColoredBox(color: c.neutral)),
                  if (flex(idle) > 0)
                    Expanded(flex: flex(idle), child: ColoredBox(color: c.idleFill)),
                  if (flex(off) > 0)
                    Expanded(flex: flex(off), child: ColoredBox(color: c.offTrack)),
                  if (rest > 0)
                    Expanded(flex: rest, child: ColoredBox(color: c.line)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Week: option A.

class _WeekView extends StatelessWidget {
  const _WeekView({
    required this.data,
    required this.today,
    required this.onOpenDay,
  });

  final _PeriodData data;
  final DateTime today;
  final ValueChanged<DateTime> onOpenDay;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final s = data.summary;
    if (!s.hasPlan) {
      return const _Body(
        children: [
          _EmptyCard(
            title: 'Nothing planned this week',
            body: 'Weeks with plan blocks get a score here.',
          ),
        ],
      );
    }
    final points = s.days;
    final worst = s.worstDay;
    final small = text.labelSmall?.copyWith(color: c.textSecondary);

    return _Body(
      children: [
        _PeriodScore(data: data, today: today),
        const _Heading('Day by day'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    for (final p in points)
                      Expanded(
                        child: Text(
                          p.percent == null || p.day.isAfter(today)
                              ? ''
                              : '${p.percent}',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: small,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, box) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (e) {
                      final i = WeekBarsPainter.columnAt(
                        e.localPosition.dx,
                        box.maxWidth,
                        points.length,
                      );
                      if (!points[i].day.isAfter(today)) onOpenDay(points[i].day);
                    },
                    child: SizedBox(
                      height: 128,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: WeekBarsPainter(
                          points: points,
                          today: today,
                          colors: c,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final p in points)
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              DateFormat('EEEEE').format(p.day),
                              maxLines: 1,
                              style: text.labelMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: p.day == today ? c.text : c.textSecondary,
                              ),
                            ),
                            Text('${p.day.day}', maxLines: 1, style: small),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ReviewLegend(
                    items: [
                      LegendItem('On track', c.onTrack),
                      LegendItem('Idle', c.idleFill),
                      LegendItem('Off track', c.offTrack),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _RowsCard([
          _InfoRow(
            'Worst day',
            worst == null
                ? 'None yet'
                : '${DateFormat('EEE d MMM').format(worst.day)}, ${worst.percent}%',
          ),
          _InfoRow(
            'Drift total',
            s.offMin == 0 ? 'No drift' : formatMinutes(s.offMin),
          ),
          _InfoRow(
            'Weekly target',
            weeklyTargetLabel(
              s.percent,
              context.watch<SettingsProvider>().weeklyTarget,
            ),
          ),
        ]),
        ..._topDrift(context, s.topDrift, s.labelOf),
      ],
    );
  }
}

/// "81% of 80%, met", "72% of 80%, not met", "No score yet" or "Off".
String weeklyTargetLabel(int? percent, int target) {
  if (target <= 0) return 'Off';
  if (percent == null) return 'No score yet';
  return '$percent% of $target%, ${percent >= target ? 'met' : 'not met'}';
}

// Month: option A.

class _MonthView extends StatelessWidget {
  const _MonthView({
    required this.data,
    required this.today,
    required this.firstWeekday,
    required this.onOpenDay,
  });

  final _PeriodData data;
  final DateTime today;
  final int firstWeekday;
  final ValueChanged<DateTime> onOpenDay;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final s = data.summary;
    if (!s.hasPlan) {
      return const _Body(
        children: [
          _EmptyCard(
            title: 'Nothing planned this month',
            body: 'Months with plan blocks get a score here.',
          ),
        ],
      );
    }
    final scaler = MediaQuery.textScalerOf(context);
    final start = data.range.start;
    final leading = (start.weekday - firstWeekday + 7) % 7;
    // 1 January 2024 was a Monday, so day n of that month is weekday n.
    final letters = [
      for (var i = 0; i < 7; i++)
        DateFormat('EEEEE').format(DateTime(2024, 1, (firstWeekday - 1 + i) % 7 + 1)),
    ];
    final headerStyle = text.labelSmall!.copyWith(
      color: c.textSecondary,
      fontWeight: FontWeight.w500,
    );
    final numberStyle = text.labelMedium!.copyWith(fontWeight: FontWeight.w500);
    final headerHeight = scaler.scale(headerStyle.fontSize ?? 11) * 1.5 + 8;
    final prevMonth = DateFormat('MMMM').format(data.prev.days.isEmpty
        ? DateTime(start.year, start.month - 1)
        : data.prev.days.first.day);
    final thisMonth = DateFormat('MMMM').format(start);
    final streak = s.bestStreak;

    return _Body(
      children: [
        _PeriodScore(data: data, today: today),
        const _Heading('Day by day'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, box) {
                    final layout = HeatmapLayout(
                      width: box.maxWidth,
                      leading: leading,
                      days: s.days.length,
                      headerHeight: headerHeight,
                    );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (e) {
                        final d = layout.dayAt(e.localPosition);
                        if (d == null) return;
                        final day = DateTime(start.year, start.month, d);
                        if (!day.isAfter(today)) onOpenDay(day);
                      },
                      child: SizedBox(
                        height: layout.height,
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: MonthHeatmapPainter(
                            layout: layout,
                            points: s.days,
                            today: today,
                            weekdayLetters: letters,
                            colors: c,
                            numberStyle: numberStyle,
                            headerStyle: headerStyle,
                            textScaler: scaler,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 14),
                ReviewLegend(
                  items: [
                    LegendItem('75% and up', bucketFill(c, ScoreBucket.good)),
                    LegendItem('60 to 74%', bucketFill(c, ScoreBucket.fair)),
                    LegendItem('Under 60%', bucketFill(c, ScoreBucket.poor)),
                    LegendItem(
                      'No data',
                      bucketFill(c, ScoreBucket.none),
                      border: c.line,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const _Heading('Trend'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 156,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: TrendPainter(
                      current: [
                        for (final p in s.days)
                          p.day.isAfter(today) ? null : p.percent,
                      ],
                      previous: data.prev.dayScores,
                      colors: c,
                      labelStyle: text.labelSmall!.copyWith(
                        color: c.textSecondary,
                      ),
                      textScaler: scaler,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _LineKey(label: thisMonth, color: c.onTrack),
                    _LineKey(
                      label: prevMonth,
                      color: c.textSecondary,
                      dashed: true,
                    ),
                    _LineKey(
                      label: '75% goal',
                      color: c.onTrack.withValues(alpha: 0.45),
                      thin: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        ..._topDrift(context, s.topDrift, s.labelOf),
        const SizedBox(height: 12),
        _RowsCard([
          _InfoRow(
            'Best streak',
            streak == 0
                ? 'None yet'
                : '${streak == 1 ? '1 day' : '$streak days'} at 75% or more',
          ),
        ]),
      ],
    );
  }
}

class _LineKey extends StatelessWidget {
  const _LineKey({
    required this.label,
    required this.color,
    this.dashed = false,
    this.thin = false,
  });

  final String label;
  final Color color;
  final bool dashed;
  final bool thin;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 18,
        height: 10,
        child: CustomPaint(
          painter: LineSwatchPainter(color: color, dashed: dashed, thin: thin),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: context.drift.textSecondary,
        ),
      ),
    ],
  );
}

// Year: option B.

class _YearView extends StatelessWidget {
  const _YearView({
    required this.data,
    required this.today,
    required this.onOpenMonth,
  });

  final _PeriodData data;
  final DateTime today;
  final ValueChanged<DateTime> onOpenMonth;

  @override
  Widget build(BuildContext context) {
    final s = data.summary;
    if (!s.hasPlan) {
      return const _Body(
        children: [
          _EmptyCard(
            title: 'Nothing planned this year',
            body: 'Years with plan blocks get a score here.',
          ),
        ],
      );
    }
    final year = data.range.start.year;
    final byMonth = {
      for (final (m, summary) in summarizeByMonth(data.days)) m.month: summary,
    };
    (int, int)? best, worst;
    for (final e in byMonth.entries) {
      final v = e.value.percent;
      if (v == null) continue;
      if (best == null || v > best.$2) best = (e.key, v);
      if (worst == null || v < worst.$2) worst = (e.key, v);
    }
    String monthWords((int, int)? m) => m == null
        ? 'None yet'
        : '${DateFormat('MMMM').format(DateTime(year, m.$1))}, ${m.$2}%';

    return _Body(
      children: [
        _PeriodScore(data: data, today: today),
        const _Heading('Month by month'),
        for (var row = 0; row < 4; row++)
          Padding(
            padding: EdgeInsets.only(bottom: row == 3 ? 0 : 8),
            child: Row(
              children: [
                for (var col = 0; col < 3; col++) ...[
                  if (col > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _MonthTile(
                      month: DateTime(year, row * 3 + col + 1),
                      percent: byMonth[row * 3 + col + 1]?.percent,
                      today: today,
                      onTap: onOpenMonth,
                    ),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 12),
        _RowsCard([
          _InfoRow('Best month', monthWords(best)),
          _InfoRow('Worst month', monthWords(worst)),
        ]),
      ],
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({
    required this.month,
    required this.percent,
    required this.today,
    required this.onTap,
  });

  final DateTime month;
  final int? percent;
  final DateTime today;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final future = month.isAfter(today);
    final bucket = future ? ScoreBucket.none : bucketOf(percent);
    final ink = bucketInk(c, bucket);
    final current = month.year == today.year && month.month == today.month;
    final name = DateFormat('MMM').format(month);
    final valueStyle = text.titleLarge?.copyWith(
      fontWeight: FontWeight.w500,
      color: ink,
    );
    final shown = future ? null : percent;
    return Semantics(
      button: !future,
      label: shown == null
          ? '${DateFormat('MMMM').format(month)}, no score'
          : '${DateFormat('MMMM').format(month)}, $shown%',
      excludeSemantics: true,
      child: Material(
        color: bucketFill(c, bucket),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: current
              ? BorderSide(color: c.text, width: 1.5)
              : bucket == ScoreBucket.none
                  ? BorderSide(color: c.line)
                  : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: future ? null : () => onTap(month),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  style: text.labelLarge?.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Stack(
                  children: [
                    // Holds the row height, so tiles with a dash line up
                    // with tiles that show a score.
                    Opacity(
                      opacity: shown == null ? 0 : 1,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          shown == null ? '100%' : '$shown%',
                          maxLines: 1,
                          style: valueStyle,
                        ),
                      ),
                    ),
                    if (shown == null)
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 14,
                            height: 2.5,
                            decoration: BoxDecoration(
                              color: c.textSecondary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
