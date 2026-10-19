import 'package:flutter/material.dart';

import '../theme/drift_theme.dart';

/// Hour and minute wheels in 5-minute steps, with a highlight band behind
/// the chosen row. [allowMidnight] adds 24:00, so a block can run to
/// midnight. Reports minutes from midnight through [onChanged].
class TimeWheel extends StatefulWidget {
  const TimeWheel({
    super.key,
    required this.initial,
    required this.onChanged,
    this.allowMidnight = false,
    this.wheelWidth = 88,
  });

  final int initial;
  final ValueChanged<int> onChanged;
  final bool allowMidnight;
  final double wheelWidth;

  @override
  State<TimeWheel> createState() => _TimeWheelState();
}

class _TimeWheelState extends State<TimeWheel> {
  late int _hour = (widget.initial ~/ 60).clamp(0, _maxHour);
  late int _minute = _hour == 24 ? 0 : (widget.initial % 60) ~/ 5 * 5;
  late final _hours = FixedExtentScrollController(initialItem: _hour);
  late final _minutes = FixedExtentScrollController(initialItem: _minute ~/ 5);

  int get _maxHour => widget.allowMidnight ? 24 : 23;

  void _report() => widget.onChanged(_hour == 24 ? 1440 : _hour * 60 + _minute);

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int count,
    required String Function(int i) label,
    required ValueChanged<int> onSelected,
  }) {
    final c = context.drift;
    final style = Theme.of(context).textTheme.headlineSmall;
    return SizedBox(
      width: widget.wheelWidth,
      child: ListWheelScrollView.useDelegate(
        controller: controller,
        itemExtent: 44,
        physics: const FixedExtentScrollPhysics(),
        perspective: 0.004,
        diameterRatio: 1.6,
        onSelectedItemChanged: onSelected,
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: count,
          builder: (context, i) => Center(
            child: Text(
              label(i),
              textScaler: TextScaler.noScaling,
              style: style?.copyWith(color: c.text),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return SizedBox(
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.line),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _wheel(
                controller: _hours,
                count: _maxHour + 1,
                label: (i) => i.toString().padLeft(2, '0'),
                onSelected: (i) {
                  setState(() => _hour = i);
                  if (i == 24 && _minute != 0) _minutes.jumpToItem(0);
                  _report();
                },
              ),
              Text(
                ':',
                textScaler: TextScaler.noScaling,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              _wheel(
                controller: _minutes,
                count: 12,
                label: (i) => (i * 5).toString().padLeft(2, '0'),
                onSelected: (i) {
                  setState(() => _minute = i * 5);
                  _report();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A sheet with one [TimeWheel] and Done; pops the chosen minutes.
class TimeWheelSheet extends StatefulWidget {
  const TimeWheelSheet({
    super.key,
    required this.title,
    required this.initial,
    required this.allowMidnightEnd,
  });

  final String title;
  final int initial;
  final bool allowMidnightEnd;

  @override
  State<TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<TimeWheelSheet> {
  late int _value = widget.initial.clamp(0, widget.allowMidnightEnd ? 1440 : 1435);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TimeWheel(
              initial: widget.initial,
              allowMidnight: widget.allowMidnightEnd,
              onChanged: (v) => _value = v,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, _value),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quiet hours option A: From and Until wheels side by side in one sheet.
/// Returns (start, end) in minutes from midnight; (0, 0) means Off.
Future<(int, int)?> showQuietHoursSheet(
  BuildContext context, {
  required int start,
  required int end,
}) => showModalBottomSheet<(int, int)>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _QuietHoursSheet(start: start, end: end),
);

class _QuietHoursSheet extends StatefulWidget {
  const _QuietHoursSheet({required this.start, required this.end});

  final int start;
  final int end;

  @override
  State<_QuietHoursSheet> createState() => _QuietHoursSheetState();
}

class _QuietHoursSheetState extends State<_QuietHoursSheet> {
  late int _start = widget.start == widget.end ? 22 * 60 : widget.start;
  late int _end = widget.start == widget.end ? 7 * 60 : widget.end;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    Widget column(String label, int initial, ValueChanged<int> onChanged) =>
        Column(
          children: [
            Text(label, style: text.labelLarge?.copyWith(color: c.textSecondary)),
            const SizedBox(height: 4),
            TimeWheel(initial: initial, onChanged: onChanged, wheelWidth: 56),
          ],
        );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Quiet hours', style: text.titleMedium),
            const SizedBox(height: 2),
            Text(
              'No nudges between these times.',
              style: text.bodySmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                column('From', _start, (v) => _start = v),
                column('Until', _end, (v) => _end = v),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, (_start, _end)),
              child: const Text('Done'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context, (0, 0)),
              child: const Text('No quiet hours'),
            ),
          ],
        ),
      ),
    );
  }
}
