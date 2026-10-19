import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../theme/drift_theme.dart';
import '../widgets/plan_timeline.dart';
import '../widgets/undo_snackbar.dart';
import 'block_editor_screen.dart';

/// The Plan tab, option B "draw on a calendar": a date strip, template
/// chips, and the day's timeline where a long-press and drag draws a new
/// block.
///
/// It shows and edits the live blocks for the selected date, never the
/// frozen `day_plans` copy: the frozen copy is history for the review
/// screens, while this tab is where the plan is changed. Past dates can
/// still be edited, but only through one-off blocks (the editor enforces
/// that), so a repeating block's other days are never rewritten from here.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  /// How many days before today the date strip reaches by scrolling left.
  static const pastDays = 60;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  late final AppServices _services = context.read<AppServices>();
  late DateTime _date;
  List<PlanBlock> _all = const [];
  List<PlanTemplate> _templates = const [];
  ScrollController? _strip;

  @override
  void initState() {
    super.initState();
    _date = localDayStart(_services.clock.now());
    _services.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _services.revision.removeListener(_load);
    _strip?.dispose();
    super.dispose();
  }

  /// Reloads blocks and templates. Runs on open and after every
  /// [AppServices.bump], so edits made in the editor show up on return.
  Future<void> _load() async {
    final all = await _services.plans.allBlocks();
    final templates = await _services.plans.allTemplates();
    if (!mounted) return;
    setState(() {
      _all = all;
      _templates = templates;
    });
  }

  DateTime get _today => localDayStart(_services.clock.now());

  List<PlanBlock> get _dayBlocks => activeBlocks(_date, _all);

  static bool _isFree(List<PlanBlock> blocks, int start, int end) =>
      !blocks.any((b) => b.startMin < end && start < b.endMin);

  /// The first whole free hour at or after [fromHour], or null.
  static int? _freeHourFrom(List<PlanBlock> blocks, int fromHour) {
    for (var h = fromHour; h < 24; h++) {
      if (_isFree(blocks, h * 60, h * 60 + 60)) return h * 60;
    }
    return null;
  }

  /// Where a new block goes by default: the next free hour after now on
  /// today, or from 09:00 on other days.
  int? _suggestedStart(List<PlanBlock> blocks, bool isToday) {
    final from = isToday ? math.min(_services.clock.now().hour + 1, 23) : 9;
    return _freeHourFrom(blocks, from);
  }

  Future<void> _openEditor({PlanBlock? block, int? start, int? end}) =>
      showBlockEditor(
        context,
        block: block,
        date: _date,
        startMin: start,
        endMin: end,
      );

  Future<void> _addBlock() {
    final blocks = _dayBlocks;
    final isToday = _date == _today;
    final start =
        _suggestedStart(blocks, isToday) ?? _freeHourFrom(blocks, 0) ?? 9 * 60;
    return _openEditor(start: start, end: math.min(start + 60, 1440));
  }

  String _dayName(DateTime d) => DateFormat('EEEE').format(d);

  /// Replaces the date's one-off blocks with [template]'s blocks. Repeating
  /// blocks that fall on the date stay; the template only adds one-offs.
  Future<void> _applyTemplate(PlanTemplate template) async {
    final messenger = ScaffoldMessenger.of(context);
    final key = dateKey(_date);
    final removed = [
      for (final b in _all)
        if (b.repeatMask == 0 && b.date == key) b,
    ];
    for (final b in removed) {
      await _services.plans.deleteBlock(b.id!);
    }
    final added = <int>[
      for (final b in template.blocks)
        await _services.plans.insertBlock(_oneOff(b, key)),
    ];
    _services.bump();
    showAppToastOn(
      messenger,
      'Applied "${template.name}" to ${_dayName(_date)}',
      tone: AppToastTone.change,
      icon: Icons.dashboard_customize_outlined,
      actionLabel: 'Undo',
      onAction: () async {
        for (final id in added) {
          await _services.plans.deleteBlock(id);
        }
        for (final b in removed) {
          await _services.plans.insertBlock(b);
        }
        _services.bump();
      },
    );
  }

  /// Copies yesterday's blocks onto the selected date as one-offs,
  /// skipping any that are already there with the same name and times
  /// (a block that repeats on both days, for one).
  Future<void> _copyYesterday() async {
    final messenger = ScaffoldMessenger.of(context);
    final yesterday = DateTime(_date.year, _date.month, _date.day - 1);
    final source = activeBlocks(yesterday, _all);
    final here = _dayBlocks;
    if (source.isEmpty) {
      showAppToastOn(messenger, 'Yesterday has no blocks to copy');
      return;
    }
    final key = dateKey(_date);
    final toCopy = [
      for (final b in source)
        if (!here.any(
          (h) =>
              blockKey(h.name) == blockKey(b.name) &&
              h.startMin == b.startMin &&
              h.endMin == b.endMin,
        ))
          b,
    ];
    if (toCopy.isEmpty) {
      showAppToastOn(messenger, "Yesterday's blocks are already here");
      return;
    }
    final added = <int>[
      for (final b in toCopy) await _services.plans.insertBlock(_oneOff(b, key)),
    ];
    _services.bump();
    showAppToastOn(
      messenger,
      toCopy.length == 1
          ? 'Copied 1 block from yesterday'
          : 'Copied ${toCopy.length} blocks from yesterday',
      tone: AppToastTone.change,
      icon: Icons.content_copy_outlined,
      actionLabel: 'Undo',
      onAction: () async {
        for (final id in added) {
          await _services.plans.deleteBlock(id);
        }
        _services.bump();
      },
    );
  }

  static PlanBlock _oneOff(PlanBlock b, String key) => PlanBlock(
    name: b.name,
    startMin: b.startMin,
    endMin: b.endMin,
    colorIdx: b.colorIdx,
    date: key,
    anyApp: b.anyApp,
  );

  Future<void> _saveTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    final blocks = _dayBlocks;
    if (blocks.isEmpty) {
      showAppToastOn(messenger, 'Add a block before saving a template');
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TemplateNameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    // Templates hold times and settings only; the date and repeat days
    // come from wherever the template is applied.
    await _services.plans.saveTemplate(name.trim(), [
      for (final b in blocks)
        PlanBlock(
          name: b.name,
          startMin: b.startMin,
          endMin: b.endMin,
          colorIdx: b.colorIdx,
          anyApp: b.anyApp,
        ),
    ]);
    _services.bump();
    showAppToastOn(
      messenger,
      'Saved template "${name.trim()}"',
      tone: AppToastTone.success,
      icon: Icons.bookmark_added_outlined,
    );
  }

  Future<void> _deleteTemplate(PlanTemplate template) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${template.name}"?'),
        content: const Text('Days it was applied to keep their blocks.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _services.plans.deleteTemplate(template.id!);
    final restore = template.blocks;
    _services.bump();
    showAppToastOn(
      messenger,
      'Deleted template "${template.name}"',
      tone: AppToastTone.removal,
      actionLabel: 'Undo',
      onAction: () async {
        await _services.plans.saveTemplate(template.name, restore);
        _services.bump();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final now = _services.clock.now();
    final today = localDayStart(now);
    final isToday = _date == today;
    final blocks = _dayBlocks;
    final hintStart = _suggestedStart(blocks, isToday);

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _addBlock,
        tooltip: 'Add a block',
        shape: const CircleBorder(),
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        elevation: 2,
        highlightElevation: 4,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, today, isToday),
            _dateStrip(context, today),
            _chips(context),
            Divider(height: 1, color: c.line),
            Expanded(
              child: PlanTimeline(
                blocks: blocks,
                nowMinute: isToday ? now.hour * 60 + now.minute : null,
                hint: hintStart == null
                    ? null
                    : (hintStart, math.min(hintStart + 60, 1440)),
                onBlockTap: (b) => _openEditor(block: b),
                onCreate: (s, e) => _openEditor(start: s, end: e),
                onHintTap: (s, e) => _openEditor(start: s, end: e),
                bottomPadding: 88,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, DateTime today, bool isToday) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final dateText = DateFormat('d MMMM').format(_date);
    final subtitle = isToday
        ? 'Today, $dateText'
        : _date.isBefore(today)
        ? '$dateText, changes apply to this day only'
        : dateText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Plan '),
                      TextSpan(
                        text: _dayName(_date),
                        style: TextStyle(color: c.textSecondary),
                      ),
                    ],
                  ),
                  style: text.headlineSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: text.bodyMedium?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          if (!isToday)
            TextButton(
              onPressed: () {
                setState(() => _date = today);
                final strip = _strip;
                if (strip != null && strip.hasClients) {
                  strip.animateTo(
                    strip.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  );
                }
              },
              child: const Text('Today'),
            ),
        ],
      ),
    );
  }

  Widget _dateStrip(BuildContext context, DateTime today) {
    final scaler = MediaQuery.textScalerOf(context);
    final height = 22 + scaler.scale(11) * 16 / 11 + scaler.scale(16) * 24 / 16;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          const pad = 12.0;
          final itemWidth = (box.maxWidth - pad * 2) / 7;
          // Today is the first visible day; earlier days sit to the left.
          final strip = _strip ??= ScrollController(
            initialScrollOffset: PlanScreen.pastDays * itemWidth,
          );
          return ListView.builder(
            controller: strip,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: pad),
            itemExtent: itemWidth,
            itemCount: PlanScreen.pastDays + 7,
            itemBuilder: (context, i) {
              final day = DateTime(
                today.year,
                today.month,
                today.day + i - PlanScreen.pastDays,
              );
              return _DayPill(
                key: ValueKey('planDay${dateKey(day)}'),
                day: day,
                selected: day == _date,
                isToday: day == today,
                isPast: day.isBefore(today),
                onTap: () => setState(() => _date = day),
              );
            },
          );
        },
      ),
    );
  }

  Widget _chips(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          for (final t in _templates) ...[
            GestureDetector(
              onLongPress: () => _deleteTemplate(t),
              child: _PlanChip(
                icon: Icons.dashboard_customize_outlined,
                label: t.name,
                onPressed: () => _applyTemplate(t),
              ),
            ),
            const SizedBox(width: 8),
          ],
          _PlanChip(
            icon: Icons.content_copy_outlined,
            label: 'Copy yesterday',
            onPressed: _copyYesterday,
          ),
          const SizedBox(width: 8),
          _PlanChip(
            icon: Icons.bookmark_add_outlined,
            label: 'Save as template',
            onPressed: _saveTemplate,
          ),
        ],
      ),
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return ActionChip(
      avatar: Icon(icon, size: 18, color: c.textSecondary),
      label: Text(label),
      labelStyle: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: c.text),
      backgroundColor: c.card,
      side: BorderSide(color: c.line),
      shape: const StadiumBorder(),
      onPressed: onPressed,
    );
  }
}

/// One day in the strip: short weekday over the date number. The selected
/// day is an accent pill with on-accent text; today, when not selected,
/// gets an outline so it is easy to find again.
class _DayPill extends StatelessWidget {
  const _DayPill({
    super.key,
    required this.day,
    required this.selected,
    required this.isToday,
    required this.isPast,
    required this.onTap,
  });

  final DateTime day;
  final bool selected;
  final bool isToday;
  final bool isPast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final fg = selected ? c.onAccent : (isPast ? c.textSecondary : c.text);
    final sub = selected ? c.onAccent : c.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: Semantics(
        selected: selected,
        button: true,
        label: DateFormat('EEEE d MMMM').format(day),
        excludeSemantics: true,
        child: Material(
          color: selected ? c.accent : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: isToday && !selected
                ? BorderSide(color: c.accent.withValues(alpha: 0.6))
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('EEE').format(day),
                      style: text.labelSmall?.copyWith(color: sub),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${day.day}',
                      style: text.titleMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w500,
                      ),
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

class _TemplateNameDialog extends StatefulWidget {
  const _TemplateNameDialog();

  @override
  State<_TemplateNameDialog> createState() => _TemplateNameDialogState();
}

class _TemplateNameDialogState extends State<_TemplateNameDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save as template'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Template name',
          hintText: 'Workday',
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
