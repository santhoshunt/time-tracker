import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../painters/category_ring_painter.dart';
import '../providers/settings_provider.dart';
import '../services/review_summary.dart';
import '../services/usage_summary.dart';
import '../theme/drift_theme.dart';
import '../widgets/category_style.dart';
import '../widgets/score_card.dart' show formatMinutes;
import 'app_usage_screen.dart';
import 'block_editor_screen.dart' show AppIcon;
import 'review_v3_screen.dart' show reviewPeriodLabel;

/// The periods the Usage tab offers, in switch order.
const usagePeriods = [ReviewPeriod.day, ReviewPeriod.week, ReviewPeriod.month];

/// The Usage tab, option A: where the phone time went in a day, week or
/// month, whatever the plan said. A ring of categories with the total in
/// the middle, then one row per category; a tap opens its apps in place,
/// and an app opens its own page.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late final AppServices _services = context.read<AppServices>();
  ReviewPeriod _period = ReviewPeriod.day;

  /// Periods back from the current one; 0 is today, this week or this month.
  int _offset = 0;

  /// The last summary loaded; kept on screen while the next one loads.
  UsageSummary? _shown;
  final _open = <String>{};
  final _iconCache = <String, Future<Uint8List?>>{};

  /// How far back the chevrons go, as on Review.
  static const _maxBack = {
    ReviewPeriod.day: 3660,
    ReviewPeriod.week: 522,
    ReviewPeriod.month: 120,
  };

  @override
  void initState() {
    super.initState();
    _services.revision.addListener(_reload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_generation == 0) _load();
  }

  @override
  void dispose() {
    _services.revision.removeListener(_reload);
    super.dispose();
  }

  DateTime get _today {
    final n = _services.clock.now();
    return DateTime(n.year, n.month, n.day);
  }

  int get _firstWeekday => context.read<SettingsProvider>().firstWeekday;

  DateTime get _anchor =>
      stepPeriod(_period, _today, -_offset, firstWeekday: _firstWeekday);

  DateTimeRange get _range =>
      periodOf(_period, _anchor, firstWeekday: _firstWeekday);

  /// Counts loads, so a slow one that lands after a newer one is dropped.
  int _generation = 0;

  Future<void> _load() async {
    final r = _range;
    final generation = ++_generation;
    final summary = await loadUsage(_services, r.start, r.end);
    if (mounted && generation == _generation) {
      setState(() => _shown = summary);
    }
  }

  void _reload() {
    if (mounted) _load();
  }

  void _setPeriod(ReviewPeriod p) {
    if (p == _period) return;
    setState(() {
      _period = p;
      _offset = 0;
      _open.clear();
    });
    _load();
  }

  void _step(int delta) {
    final next = _offset - delta;
    if (next < 0 || next > _maxBack[_period]!) return;
    setState(() => _offset = next);
    _load();
  }

  Future<Uint8List?> _iconFor(String p) => _iconCache.putIfAbsent(p, () async {
    try {
      final bytes = await _services.usage.appIcon(p);
      return bytes == null ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  });

  /// The app page's day: the period's last day, or today when the period
  /// is still running.
  DateTime get _detailDay {
    final end = _range.end;
    return end.isAfter(_today) ? _today : end;
  }

  void _openApp(AppUsage a) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppUsageScreen(package: a.p, day: _detailDay),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    // Rebuilds when the week start changes; the range reads it.
    context.select<SettingsProvider, int>((s) => s.firstWeekday);
    final label = reviewPeriodLabel(
      _period,
      _anchor,
      _today,
      firstWeekday: _firstWeekday,
    );
    final noun = switch (_period) {
      ReviewPeriod.day => 'day',
      ReviewPeriod.week => 'week',
      _ => 'month',
    };
    final shown = _shown;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text('Usage', style: text.headlineSmall),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<ReviewPeriod>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(value: ReviewPeriod.day, label: Text('Day')),
                ButtonSegment(value: ReviewPeriod.week, label: Text('Week')),
                ButtonSegment(value: ReviewPeriod.month, label: Text('Month')),
              ],
              selected: {_period},
              onSelectionChanged: (s) => _setPeriod(s.first),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous $noun',
                onPressed: _offset < _maxBack[_period]! ? () => _step(-1) : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    key: const ValueKey('usage-period-label'),
                    maxLines: 1,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next $noun',
                onPressed: _offset > 0 ? () => _step(1) : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (shown == null)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (shown.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('No app use yet', style: text.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      'Drift counts time once it has usage access.',
                      style: text.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _Ring(summary: shown),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  for (final (i, cat) in shown.categories.indexed) ...[
                    if (i > 0) Divider(height: 1, indent: 16, color: c.line),
                    _CategoryRow(
                      usage: cat,
                      totalMs: shown.totalMs,
                      open: _open.contains(cat.category),
                      onTap: () => setState(() {
                        if (!_open.remove(cat.category)) _open.add(cat.category);
                      }),
                    ),
                    if (_open.contains(cat.category))
                      for (final a in cat.apps)
                        _AppRow(
                          usage: a,
                          iconFor: _iconFor,
                          onTap: () => _openApp(a),
                        ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.summary});

  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Center(
      child: SizedBox.square(
        dimension: 200,
        child: CustomPaint(
          painter: CategoryRingPainter(
            parts: [
              for (final cat in summary.categories)
                (categoryColor(context, cat.category), cat.ms),
            ],
            track: c.line,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatMinutes(summary.totalMinutes),
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      'on apps',
                      style: text.bodySmall?.copyWith(color: c.textSecondary),
                    ),
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

/// "42%", or "<1%" for a sliver that would otherwise read as nothing.
String sharePercent(int ms, int totalMs) {
  if (totalMs <= 0) return '0%';
  final p = (100 * ms / totalMs).round();
  return p == 0 && ms > 0 ? '<1%' : '$p%';
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.usage,
    required this.totalMs,
    required this.open,
    required this.onTap,
  });

  final CategoryUsage usage;
  final int totalMs;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final name = categoryLabel(usage.category);
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: categoryColor(context, usage.category),
                ),
              ),
              const SizedBox(width: 12),
              // The share sits under the name rather than in its own
              // column, so "Music and audio" keeps its words whole on a
              // narrow phone with large text.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge,
                    ),
                    Text(
                      sharePercent(usage.ms, totalMs),
                      style: text.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatMinutes(usage.minutes),
                style: text.bodyMedium?.copyWith(color: c.text),
              ),
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                color: c.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.usage,
    required this.iconFor,
    required this.onTap,
  });

  final AppUsage usage;
  final Future<Uint8List?> Function(String p) iconFor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(38, 8, 12, 8),
        child: Row(
          children: [
            AppIcon(
              package: usage.p,
              label: usage.label,
              size: 28,
              iconFor: iconFor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                usage.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium,
              ),
            ),
            Text(
              formatMinutes(usage.minutes),
              style: text.bodyMedium?.copyWith(color: c.textSecondary),
            ),
            Icon(Icons.chevron_right, size: 20, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}
