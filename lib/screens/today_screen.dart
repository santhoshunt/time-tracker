import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../painters/day_ring_painter.dart';
import '../providers/settings_provider.dart';
import '../services/day_loader.dart';
import '../theme/drift_theme.dart';
import '../theme/theme_id.dart';
import '../widgets/score_card.dart';
import '../widgets/timeline_lanes.dart';
import '../widgets/update_banner.dart';
import '../widgets/verdict_style.dart';

/// The Today tab: the plan with real app use over it, as two lanes or a
/// 24-hour ring (the Lanes / Ring control in the header). Reloads whenever
/// [AppServices.revision] changes, which the home shell bumps after every
/// ingest on open and resume.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, this.onPlan});

  /// Switches to the Plan tab.
  final VoidCallback? onPlan;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  DayData? _data;
  late final AppServices _services;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _services.revision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _services.revision.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final data = await loadDay(_services, _services.clock.now());
    if (mounted) setState(() => _data = data);
  }

  void _showSegment(Segment s) {
    final data = _data;
    if (data == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SegmentSheet(segment: s, label: data.labelOf(s.p)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final settings = context.watch<SettingsProvider>();
    final data = _data;
    final view = settings.todayView;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Today', style: text.headlineSmall),
                Text(
                  DateFormat('EEE d MMM').format(_services.clock.now()),
                  style: text.bodySmall?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          SegmentedButton<TodayView>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(value: TodayView.lanes, label: Text('Lanes')),
              ButtonSegment(value: TodayView.ring, label: Text('Ring')),
            ],
            selected: {view},
            onSelectionChanged: (s) => settings.setTodayView(s.first),
          ),
        ],
      ),
    );

    final top = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          const UpdateBanner(),
          ScoreCard(score: data?.score, onPlan: widget.onPlan),
        ],
      ),
    );

    return SafeArea(
      bottom: false,
      child: data == null
          ? Column(
              children: [
                header,
                const Expanded(child: Center(child: CircularProgressIndicator())),
              ],
            )
          : view == TodayView.lanes
          ? Column(
              children: [
                header,
                top,
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TimelineLanes(data: data, onSegmentTap: _showSegment),
                  ),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                header,
                top,
                const SizedBox(height: 12),
                _RingView(data: data),
              ],
            ),
    );
  }
}

class _RingView extends StatelessWidget {
  const _RingView({required this.data});

  final DayData data;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final now = data.now;
    final current = data.blocks.where(
      (b) => !now.isBefore(b.start) && now.isBefore(b.end),
    );
    final next = data.blocks.where((b) => b.start.isAfter(now));
    final nowSegment = data.segments.isEmpty ? null : data.segments.last;
    final offMin = data.score?.offMin ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final size = box.maxWidth.clamp(0.0, 300.0);
              return SizedBox.square(
                dimension: size,
                child: CustomPaint(
                  painter: DayRingPainter(
                    day: data.day,
                    blocks: data.blocks,
                    segments: data.segments,
                    now: now,
                    colors: c,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          DateFormat('HH:mm').format(now),
                          style: text.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          current.isEmpty ? 'No block now' : current.first.name,
                          style: text.bodyMedium?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                _Row(
                  label: 'Now',
                  value: nowSegment == null || current.isEmpty
                      ? 'Outside your plan'
                      : verdictLabel(nowSegment.verdict),
                  color: nowSegment == null || current.isEmpty
                      ? null
                      : verdictColor(c, nowSegment.verdict),
                ),
                Divider(height: 1, indent: 16, color: c.line),
                _Row(
                  label: 'Drift today',
                  value: offMin == 0 ? 'None' : formatMinutes(offMin),
                  color: offMin == 0 ? c.onTrack : c.offTrack,
                ),
                Divider(height: 1, indent: 16, color: c.line),
                _Row(
                  label: 'Next',
                  value: next.isEmpty
                      ? 'Nothing else planned'
                      : '${next.first.name} at ${DateFormat('HH:mm').format(next.first.start)}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: text.bodyLarge)),
          if (color != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 8),
          ],
          Text(value, style: text.bodyMedium?.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }
}

class _SegmentSheet extends StatelessWidget {
  const _SegmentSheet({required this.segment, required this.label});

  final Segment segment;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final time = DateFormat('HH:mm');
    final v = segment.verdict;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.isEmpty ? verdictLabel(v) : label,
              style: text.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${time.format(segment.start)} to ${time.format(segment.end)}'
              ' · ${formatMinutes(segment.duration.inMinutes)}'
              '${segment.blockName == null ? '' : ' · ${segment.blockName}'}',
              style: text.bodyMedium?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: verdictColor(c, v),
                  ),
                ),
                const SizedBox(width: 8),
                Text(verdictLabel(v), style: text.bodyLarge),
              ],
            ),
            if (v == Verdict.guessedOn || v == Verdict.guessedOff) ...[
              const SizedBox(height: 8),
              Text(
                'This is a guess from the app\'s category. Add the app to the '
                'block in the Plan tab to make it a rule.',
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
