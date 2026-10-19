import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../services/usage_summary.dart';
import '../theme/drift_theme.dart';
import '../widgets/category_style.dart';
import '../widgets/score_card.dart' show formatMinutes;

/// One app's page from the Usage tab, option A: its last seven days, when
/// it was in front on [day], and how that time fell against the plan.
class AppUsageScreen extends StatefulWidget {
  const AppUsageScreen({super.key, required this.package, required this.day});

  final String package;

  /// The day the page is about; the seven days end on it.
  final DateTime day;

  @override
  State<AppUsageScreen> createState() => _AppUsageScreenState();
}

class _AppUsageScreenState extends State<AppUsageScreen> {
  late final AppServices _services = context.read<AppServices>();
  late Future<AppDetail> _future = _load();

  @override
  void initState() {
    super.initState();
    _services.revision.addListener(_reload);
  }

  @override
  void dispose() {
    _services.revision.removeListener(_reload);
    super.dispose();
  }

  Future<AppDetail> _load() =>
      loadAppDetail(_services, widget.package, widget.day);

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        title: const Text('Usage'),
      ),
      body: FutureBuilder<AppDetail>(
        future: _future,
        builder: (context, snap) {
          final d = snap.data;
          if (d == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _Body(detail: d, day: widget.day, now: _services.clock.now());
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.detail, required this.day, required this.now});

  final AppDetail detail;
  final DateTime day;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final today = DateTime(now.year, now.month, now.day);
    final isToday = DateTime(day.year, day.month, day.day) == today;
    final dayWord = isToday ? 'today' : DateFormat('EEE d MMM').format(day);
    final heading = text.titleSmall?.copyWith(
      color: c.textSecondary,
      fontWeight: FontWeight.w500,
    );
    final color = categoryColor(context, detail.category);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Text(detail.label, style: text.headlineSmall),
        const SizedBox(height: 2),
        Text(
          '${categoryLabel(detail.category)}, '
          '${formatMinutes(detail.dayMinutes)} $dayWord',
          style: text.bodyMedium?.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: 16),
        Text('Last 7 days', style: heading),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: _WeekBars(days: detail.lastSevenDays, color: color),
          ),
        ),
        const SizedBox(height: 16),
        Text(isToday ? 'When today' : 'When on $dayWord', style: heading),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: _DayStrip(day: day, spans: detail.daySpans, color: color),
          ),
        ),
        const SizedBox(height: 16),
        Text('Inside your blocks', style: heading),
        const SizedBox(height: 8),
        Card(
          child: detail.byBlock.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No time $dayWord.',
                    style: text.bodyMedium?.copyWith(color: c.textSecondary),
                  ),
                )
              : Column(
                  children: [
                    for (final (i, b) in detail.byBlock.indexed) ...[
                      if (i > 0) Divider(height: 1, indent: 16, color: c.line),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                b.block ?? 'Outside blocks',
                                style: text.bodyLarge,
                              ),
                            ),
                            Text(
                              b.offTrack
                                  ? '${formatMinutes(b.minutes)} off track'
                                  : formatMinutes(b.minutes),
                              style: text.bodyMedium?.copyWith(
                                color: b.offTrack
                                    ? c.offTrack
                                    : c.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// Seven bars, one per day, the last one in the accent.
class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.days, required this.color});

  final List<(DateTime, int)> days;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final top = maxOf(days.map((d) => d.$2));
    final small = text.labelSmall?.copyWith(color: c.textSecondary);
    return Column(
      children: [
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, (_, m)) in days.indexed)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(m == 0 ? '' : '$m', maxLines: 1, style: small),
                        const SizedBox(height: 2),
                        Container(
                          height: m == 0 ? 2 : 70 * m / top,
                          decoration: BoxDecoration(
                            color: i == days.length - 1
                                ? c.accent
                                : color.withValues(alpha: m == 0 ? 0.3 : 0.85),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final (d, _) in days)
              Expanded(
                child: Text(
                  DateFormat('EEEEE').format(d),
                  textAlign: TextAlign.center,
                  style: small,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The day as one bar from 00:00 to 24:00 with the app's runs on it.
class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.day, required this.spans, required this.color});

  final DateTime day;
  final List<(DateTime, DateTime)> spans;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final small = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: c.textSecondary);
    final start = DateTime(day.year, day.month, day.day);
    final length = DateTime(
      day.year,
      day.month,
      day.day + 1,
    ).difference(start).inMilliseconds;
    double at(DateTime t) =>
        (t.difference(start).inMilliseconds / length).clamp(0.0, 1.0);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, box) => SizedBox(
            height: 14,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.line,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                for (final (a, b) in spans)
                  Positioned(
                    left: box.maxWidth * at(a),
                    // At least two pixels, so a short run is still seen.
                    width: (box.maxWidth * (at(b) - at(a))).clamp(2.0, box.maxWidth),
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: color),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final h in const ['00', '06', '12', '18', '24'])
              Text(h, style: small),
          ],
        ),
      ],
    );
  }
}
