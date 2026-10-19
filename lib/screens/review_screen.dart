import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../services/day_loader.dart';
import '../theme/drift_theme.dart';
import '../widgets/score_card.dart';

/// The Review tab for v0.1: one day's score card, drift by block and top
/// drift apps, with arrows to earlier days. Week, month and year views
/// arrive in v0.3.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final AppServices _services;
  late DateTime _day;
  DayData? _data;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    final now = _services.clock.now();
    _day = DateTime(now.year, now.month, now.day);
    _services.revision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _services.revision.removeListener(_reload);
    super.dispose();
  }

  bool get _isToday {
    final now = _services.clock.now();
    return _day == DateTime(now.year, now.month, now.day);
  }

  Future<void> _reload() async {
    final day = _day;
    final data = await loadDay(_services, day);
    if (mounted && day == _day) setState(() => _data = data);
  }

  void _move(int days) {
    setState(() {
      _day = DateTime(_day.year, _day.month, _day.day + days);
      _data = null;
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final data = _data;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text('Review', style: text.headlineSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous day',
                onPressed: () => _move(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  _isToday ? 'Today' : DateFormat('EEE d MMM').format(_day),
                  textAlign: TextAlign.center,
                  style: text.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Next day',
                onPressed: _isToday ? null : () => _move(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (data == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            ScoreCard(score: data.score),
            if (data.blocks.isNotEmpty) ...[
              _Heading('Drift by block'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      for (final b in data.blocks) _BlockDrift(data: data, block: b),
                    ],
                  ),
                ),
              ),
            ],
            if (data.topDrift.isNotEmpty) ...[
              _Heading('Top drift apps'),
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < data.topDrift.length && i < 5; i++) ...[
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
                                data.labelOf(data.topDrift[i].$1),
                                style: text.bodyLarge,
                              ),
                            ),
                            Text(
                              formatMinutes(data.topDrift[i].$2),
                              style: text.bodyMedium?.copyWith(
                                color: c.offTrack,
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
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: context.drift.textSecondary),
    ),
  );
}

/// One block's planned time split into on track, idle and drift.
class _BlockDrift extends StatelessWidget {
  const _BlockDrift({required this.data, required this.block});

  final DayData data;
  final ResolvedBlock block;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    var on = 0, idle = 0, off = 0;
    for (final s in data.segments) {
      if (s.blockName != block.name) continue;
      if (s.start.isBefore(block.start) || !s.end.isAfter(block.start)) continue;
      if (!s.start.isBefore(block.end)) continue;
      final m = s.duration.inSeconds;
      switch (s.verdict) {
        case Verdict.offTrack || Verdict.guessedOff:
          off += m;
        case Verdict.idle:
          idle += m;
        case Verdict.onTrack || Verdict.guessedOn:
          on += m;
        case Verdict.unplanned || Verdict.noData:
          break;
      }
    }
    final planned = block.end.difference(block.start).inSeconds;
    final total = planned == 0 ? 1 : planned;
    int flex(int v) => (v * 1000 ~/ total).clamp(0, 1000);
    final rest = (1000 - flex(on) - flex(idle) - flex(off)).clamp(0, 1000);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(block.name, style: text.bodyLarge)),
              Text(
                off == 0 ? 'No drift' : '${formatMinutes(off ~/ 60)} drift',
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
              child: Row(
                children: [
                  if (flex(on) > 0) Expanded(flex: flex(on), child: ColoredBox(color: c.onTrack)),
                  if (flex(idle) > 0) Expanded(flex: flex(idle), child: ColoredBox(color: c.idleFill)),
                  if (flex(off) > 0) Expanded(flex: flex(off), child: ColoredBox(color: c.offTrack)),
                  if (rest > 0) Expanded(flex: rest, child: ColoredBox(color: c.line)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
