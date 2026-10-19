import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../domain/plan_suggest.dart';
import '../providers/settings_provider.dart';
import '../theme/drift_theme.dart';
import '../widgets/plan_timeline.dart';
import '../widgets/plan_week_view.dart';
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
///
/// A Day / Week switch in the header swaps the day for [PlanWeekView]:
/// the week holding the selected date, with "Copy to next week", "Fill
/// weekends", and holding a day to copy it to other days. Every week
/// action writes one-off blocks only and offers Undo.
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

  /// Whether the Week view is showing instead of the day.
  bool _week = false;

  /// Days the strip runs past today + 6, so a later date picked in the
  /// Week view still has its pill.
  int _stripExtra = 0;

  /// The strip's day width from its last layout.
  double _stripItemWidth = 0;

  /// True while a week action is writing, so a second tap waits its turn.
  bool _busy = false;

  /// Frozen plans of the last five weeks, which ghost-block suggestions
  /// read for past weekdays.
  Map<String, String> _frozen = const {};

  /// Dates whose suggestions were hidden with "Hide suggestions". Kept in
  /// memory only, so they come back the next time the app starts.
  final _hiddenSuggestions = <String>{};

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
    final today = _today;
    final frozen = await _services.plans.frozenPlansBetween(
      DateTime(today.year, today.month, today.day - 7 * (suggestWeeks + 1)),
      DateTime(today.year, today.month, today.day + 1),
    );
    if (!mounted) return;
    setState(() {
      _all = all;
      _templates = templates;
      _frozen = frozen;
    });
  }

  /// Ghost blocks for the selected day: only on an empty day from today
  /// on (a past day's one-offs are history edits), and not once hidden.
  List<PlanBlock> get _suggestions {
    if (_date.isBefore(_today) || _dayBlocks.isNotEmpty) return const [];
    if (_hiddenSuggestions.contains(dateKey(_date))) return const [];
    return suggestPlan(_date, _all, _frozen);
  }

  Future<void> _keepSuggestions(List<PlanBlock> blocks) => _guarded(() async {
    if (blocks.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await _applyEdit(
      messenger,
      remove: const [],
      add: blocks,
      message: blocks.length == 1
          ? 'Added ${blocks.single.name}'
          : 'Added ${blocks.length} suggested blocks',
      icon: Icons.add,
    );
  });

  void _hideSuggestions() =>
      setState(() => _hiddenSuggestions.add(dateKey(_date)));

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

  // Week view.

  /// Whole calendar days from [a] to [b], counted on UTC dates so a
  /// daylight-saving change never makes a day 23 or 25 hours long.
  static int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  static DateTime _addDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  /// The seven days of the week holding [date], from [firstWeekday].
  static List<DateTime> _weekDays(DateTime date, int firstWeekday) {
    final start = planWeekStart(date, firstWeekday);
    return [for (var i = 0; i < 7; i++) _addDays(start, i)];
  }

  static List<PlanBlock> _oneOffsOn(List<PlanBlock> all, String key) => [
    for (final b in all)
      if (b.repeatMask == 0 && b.date == key) b,
  ];

  /// Same name (as [blockKey] compares it) and the same times.
  static bool _sameSlot(PlanBlock a, PlanBlock b) =>
      blockKey(a.name) == blockKey(b.name) &&
      a.startMin == b.startMin &&
      a.endMin == b.endMin;

  /// What a block looks like on its day, without its row id, for telling
  /// whether an edit would change anything.
  static String _shape(PlanBlock b) =>
      '${b.name}|${b.startMin}|${b.endMin}|${b.colorIdx}|${b.anyApp}|${b.date}';

  static bool _sameShapes(List<PlanBlock> a, List<PlanBlock> b) {
    if (a.length != b.length) return false;
    final x = a.map(_shape).toList()..sort();
    final y = b.map(_shape).toList()..sort();
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  void _setWeek(bool week) {
    if (week == _week) return;
    setState(() {
      _week = week;
      if (!week) _resetStrip();
    });
  }

  /// Leaves the Week view for [day]'s Day view.
  void _openDay(DateTime day) => setState(() {
    _date = day;
    _week = false;
    _resetStrip();
  });

  void _shiftWeek(int weeks) =>
      setState(() => _date = _addDays(_date, weeks * 7));

  /// Rebuilds the date strip around [_date] the next time the Day view
  /// lays out. Only called while the strip is off screen (in the Week
  /// view), so its controller is detached and safe to drop.
  void _resetStrip() {
    _strip?.dispose();
    _strip = null;
    _stripExtra = math.max(0, _daysBetween(_addDays(_today, 6), _date));
  }

  /// Where the strip opens: today first, as always, unless [_date] is
  /// outside that first page; then [_date] is brought on screen.
  double _stripOffset(DateTime today, double itemWidth, int count) {
    final first = _addDays(today, -PlanScreen.pastDays);
    final index = _daysBetween(first, _date);
    if (index >= PlanScreen.pastDays && index < PlanScreen.pastDays + 7) {
      return PlanScreen.pastDays * itemWidth;
    }
    return index.clamp(0, count - 7) * itemWidth;
  }

  /// Runs a week action unless one is already writing.
  Future<void> _guarded(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } finally {
      _busy = false;
    }
  }

  /// Deletes [remove], inserts [add], bumps, and offers an Undo that puts
  /// [remove] back and takes [add] out again.
  Future<void> _applyEdit(
    ScaffoldMessengerState messenger, {
    required List<PlanBlock> remove,
    required List<PlanBlock> add,
    required String message,
    required IconData icon,
  }) async {
    final plans = _services.plans;
    for (final b in remove) {
      await plans.deleteBlock(b.id!);
    }
    final added = <int>[for (final b in add) await plans.insertBlock(b)];
    _services.bump();
    showAppToastOn(
      messenger,
      message,
      tone: AppToastTone.change,
      icon: icon,
      actionLabel: 'Undo',
      onAction: () async {
        for (final id in added) {
          await plans.deleteBlock(id);
        }
        for (final b in remove) {
          await plans.insertBlock(b);
        }
        _services.bump();
      },
    );
  }

  /// Copies each day's one-off blocks to the same weekday next week,
  /// replacing that day's one-offs. Repeating blocks already repeat, so
  /// they are left alone. A day with nothing to copy leaves next week's
  /// day as it is, so a plan already made there (a dentist next Tuesday)
  /// is never wiped by an empty day this week.
  Future<void> _copyToNextWeek(List<DateTime> days, int firstWeekday) =>
      _guarded(() async {
        final messenger = ScaffoldMessenger.of(context);
        final all = await _services.plans.allBlocks();
        final remove = <PlanBlock>[];
        final add = <PlanBlock>[];
        var sources = 0;
        for (final d in days) {
          final source = _oneOffsOn(all, dateKey(d));
          if (source.isEmpty) continue;
          sources += source.length;
          final target = dateKey(_addDays(d, 7));
          remove.addAll(_oneOffsOn(all, target));
          add.addAll([for (final b in source) _oneOff(b, target)]);
        }
        if (sources == 0) {
          final anyBlocks = days.any((d) => activeBlocks(d, all).isNotEmpty);
          showAppToastOn(
            messenger,
            anyBlocks
                ? 'Nothing to copy: this week has only repeating blocks'
                : 'This week has no blocks to copy',
          );
          return;
        }
        if (_sameShapes(remove, add)) {
          showAppToastOn(messenger, 'Next week already matches this week');
          return;
        }
        final next = planWeekLabel(_addDays(days.first, 7), _today);
        await _applyEdit(
          messenger,
          remove: remove,
          add: add,
          message: 'Copied this week to $next',
          icon: Icons.content_copy_outlined,
        );
      });

  /// Applies a picked template to the week's Saturday and Sunday as
  /// one-offs, replacing their one-offs. A template block that a
  /// repeating block already covers on that day is not added again.
  Future<void> _fillWeekends(List<DateTime> days) => _guarded(() async {
    final messenger = ScaffoldMessenger.of(context);
    final templates = await _services.plans.allTemplates();
    if (!mounted) return;
    if (templates.isEmpty) {
      showAppToastOn(
        messenger,
        'Save a template first',
        icon: Icons.bookmark_add_outlined,
      );
      return;
    }
    final weekend = [
      for (final d in days)
        if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) d,
    ];
    final template = await showFillWeekendsSheet(
      context,
      templates: templates,
      days: weekend,
    );
    if (template == null || !mounted) return;
    final all = await _services.plans.allBlocks();
    final remove = <PlanBlock>[];
    final add = <PlanBlock>[];
    for (final d in weekend) {
      final key = dateKey(d);
      final repeating = [
        for (final b in activeBlocks(d, all))
          if (b.repeatMask != 0) b,
      ];
      remove.addAll(_oneOffsOn(all, key));
      add.addAll([
        for (final b in template.blocks)
          if (!repeating.any((r) => _sameSlot(r, b))) _oneOff(b, key),
      ]);
    }
    await _applyEdit(
      messenger,
      remove: remove,
      add: add,
      message:
          'Applied "${template.name}" to ${weekend.map(shortDayLabel).join(' and ')}',
      icon: Icons.weekend_outlined,
    );
  });

  /// Copies [day]'s blocks to the days picked in a sheet as one-offs,
  /// replacing their one-offs. A block is skipped on a day where the same
  /// repeating block (or one with the same name and times) already
  /// applies, so nothing shows twice.
  Future<void> _copyDay(DateTime day, List<DateTime> days) => _guarded(() async {
    final messenger = ScaffoldMessenger.of(context);
    final before = await _services.plans.allBlocks();
    if (!mounted) return;
    if (activeBlocks(day, before).isEmpty) {
      showAppToastOn(messenger, '${shortDayLabel(day)} has no blocks to copy');
      return;
    }
    final targets = await showCopyDaySheet(
      context,
      source: day,
      targets: [
        for (final d in days)
          if (d != day) d,
      ],
    );
    if (targets == null || targets.isEmpty || !mounted) return;
    final all = await _services.plans.allBlocks();
    final source = [
      for (final b in activeBlocks(day, all))
        if (b.endMin > b.startMin) b,
    ];
    final remove = <PlanBlock>[];
    final add = <PlanBlock>[];
    for (final t in targets) {
      final key = dateKey(t);
      final repeating = [
        for (final b in activeBlocks(t, all))
          if (b.repeatMask != 0) b,
      ];
      remove.addAll(_oneOffsOn(all, key));
      add.addAll([
        for (final b in source)
          if (!repeating.any((r) => r.id == b.id || _sameSlot(r, b)))
            _oneOff(b, key),
      ]);
    }
    await _applyEdit(
      messenger,
      remove: remove,
      add: add,
      message: targets.length == 1
          ? 'Copied ${shortDayLabel(day)} to ${shortDayLabel(targets.single)}'
          : 'Copied ${shortDayLabel(day)} to ${targets.length} days',
      icon: Icons.content_copy_outlined,
    );
  });

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final now = _services.clock.now();
    final today = localDayStart(now);
    final isToday = _date == today;
    final firstWeekday = context.select<SettingsProvider, int>(
      (s) => s.firstWeekday,
    );
    final nowMinute = now.hour * 60 + now.minute;

    final List<Widget> body;
    if (_week) {
      final days = _weekDays(_date, firstWeekday);
      body = [
        _header(context, today, isToday, days, firstWeekday),
        _weekChips(days, firstWeekday),
        Divider(height: 1, color: c.line),
        Expanded(
          child: PlanWeekView(
            days: days,
            blocks: _all,
            today: today,
            nowMinute: nowMinute,
            onDayTap: _openDay,
            onDayLongPress: (d) => _copyDay(d, days),
          ),
        ),
      ];
    } else {
      final blocks = _dayBlocks;
      final hintStart = _suggestedStart(blocks, isToday);
      final suggestions = _suggestions;
      body = [
        _header(context, today, isToday, null, firstWeekday),
        _dateStrip(context, today),
        _chips(context, suggestions),
        Divider(height: 1, color: c.line),
        Expanded(
          child: PlanTimeline(
            blocks: blocks,
            suggestions: suggestions,
            onKeepSuggestion: (b) => _keepSuggestions([b]),
            nowMinute: isToday ? nowMinute : null,
            hint: hintStart == null
                ? null
                : (hintStart, math.min(hintStart + 60, 1440)),
            onBlockTap: (b) => _openEditor(block: b),
            onCreate: (s, e) => _openEditor(start: s, end: e),
            onHintTap: (s, e) => _openEditor(start: s, end: e),
            bottomPadding: 88,
          ),
        ),
      ];
    }

    return Scaffold(
      // The week has no single day to add to, and the button would cover
      // the bottom of the last column.
      floatingActionButton: _week
          ? null
          : FloatingActionButton(
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
          children: body,
        ),
      ),
    );
  }

  /// "Plan Monday" over the date, or "Plan this week" over the week's
  /// range with arrows, and the Day / Week switch. The second line keeps
  /// one height in both views, so switching never moves the page.
  Widget _header(
    BuildContext context,
    DateTime today,
    bool isToday,
    List<DateTime>? week,
    int firstWeekday,
  ) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final String title;
    final String subtitle;
    final (String, VoidCallback)? jump;
    if (week == null) {
      title = _dayName(_date);
      final dateText = DateFormat('d MMMM').format(_date);
      subtitle = isToday
          ? 'Today, $dateText'
          : _date.isBefore(today)
          ? '$dateText, changes apply to this day only'
          : dateText;
      jump = isToday
          ? null
          : (
              'Today',
              () {
                setState(() => _date = today);
                final strip = _strip;
                if (strip != null && strip.hasClients) {
                  strip.animateTo(
                    PlanScreen.pastDays * _stripItemWidth,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  );
                }
              },
            );
    } else {
      final offset =
          _daysBetween(
            planWeekStart(today, firstWeekday),
            week.first,
          ) ~/
          7;
      title = switch (offset) {
        0 => 'this week',
        1 => 'next week',
        -1 => 'last week',
        > 1 => 'in $offset weeks',
        _ => '${-offset} weeks ago',
      };
      subtitle = planWeekLabel(week.first, today);
      jump = offset == 0
          ? null
          : ('This week', () => setState(() => _date = today));
    }
    const compact = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final titleStyle = text.headlineSmall!;
    final titleText = Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Plan '),
          TextSpan(text: title, style: TextStyle(color: c.textSecondary)),
        ],
      ),
      style: titleStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final modeSwitch = SegmentedButton<bool>(
      showSelectedIcon: false,
      style: compact,
      segments: const [
        ButtonSegment(value: false, label: Text('Day')),
        ButtonSegment(value: true, label: Text('Week')),
      ],
      selected: {_week},
      onSelectionChanged: (s) => _setWeek(s.first),
    );
    final jumpButton = jump == null
        ? null
        : TextButton(style: compact, onPressed: jump.$2, child: Text(jump.$1));
    final subtitleStyle = text.bodyMedium?.copyWith(color: c.textSecondary);
    // The week's range stays on one line, shrinking if it must, so the
    // header keeps its height from week to week.
    final subtitleText = week == null
        ? Text(subtitle, style: subtitleStyle)
        : FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(subtitle, style: subtitleStyle, maxLines: 1),
          );
    Widget second({required bool withJump}) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: [
          Expanded(child: subtitleText),
          if (withJump && jumpButton != null) jumpButton,
          if (week != null) ...[
            IconButton(
              tooltip: 'Previous week',
              visualDensity: VisualDensity.compact,
              onPressed: () => _shiftWeek(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Next week',
              visualDensity: VisualDensity.compact,
              onPressed: () => _shiftWeek(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 2),
      child: LayoutBuilder(
        builder: (context, box) {
          // The switch sits beside the title when the longest title this
          // view can show fits next to it, and on its own line under the
          // date otherwise (small phones, large text). Deciding on the
          // longest title, not the current one, keeps the header the same
          // height while moving between days or weeks.
          final scaler = MediaQuery.textScalerOf(context);
          double width(String s, TextStyle? style) =>
              (TextPainter(
                    text: TextSpan(text: s, style: style),
                    textDirection: TextDirection.ltr,
                    textScaler: scaler,
                    maxLines: 1,
                  )..layout())
                  .width;
          final candidates = week == null
              ? [
                  for (var i = 0; i < 7; i++)
                    _dayName(_addDays(DateTime(2026, 10, 19), i)),
                ]
              : const ['this week', 'next week', 'last week'];
          final longest = candidates
              .map((t) => width('Plan $t', titleStyle))
              .reduce(math.max);
          final labelStyle = Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500);
          // Each segment pads its label by 12 on both sides, plus borders.
          final switchWidth =
              width('Day', labelStyle) + width('Week', labelStyle) + 50;
          final inline = longest + 12 + switchWidth <= box.maxWidth;
          if (inline) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: titleText),
                    const SizedBox(width: 12),
                    modeSwitch,
                  ],
                ),
                second(withJump: true),
              ],
            );
          }
          // Stacked: the jump back to today or this week moves onto the
          // switch's line, leaving the date line room for the date.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleText,
              second(withJump: false),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Row(
                  children: [
                    modeSwitch,
                    const Spacer(),
                    ?jumpButton,
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _weekChips(List<DateTime> days, int firstWeekday) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          _PlanChip(
            icon: Icons.content_copy_outlined,
            label: 'Copy to next week',
            onPressed: () => _copyToNextWeek(days, firstWeekday),
          ),
          const SizedBox(width: 8),
          _PlanChip(
            icon: Icons.weekend_outlined,
            label: 'Fill weekends',
            onPressed: () => _fillWeekends(days),
          ),
        ],
      ),
    );
  }

  Widget _dateStrip(BuildContext context, DateTime today) {
    final scaler = MediaQuery.textScalerOf(context);
    final height = 22 + scaler.scale(11) * 16 / 11 + scaler.scale(16) * 24 / 16;
    final count = PlanScreen.pastDays + 7 + _stripExtra;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          const pad = 12.0;
          final itemWidth = (box.maxWidth - pad * 2) / 7;
          _stripItemWidth = itemWidth;
          // Today is the first visible day; earlier days sit to the left.
          // A date picked in the Week view off that page is shown instead.
          final strip = _strip ??= ScrollController(
            keepScrollOffset: false,
            initialScrollOffset: _stripOffset(today, itemWidth, count),
          );
          return ListView.builder(
            controller: strip,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: pad),
            itemExtent: itemWidth,
            itemCount: count,
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

  Widget _chips(BuildContext context, List<PlanBlock> suggestions) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          if (suggestions.isNotEmpty) ...[
            _PlanChip(
              icon: Icons.done_all,
              label: 'Keep all',
              onPressed: () => _keepSuggestions(suggestions),
            ),
            const SizedBox(width: 8),
            _PlanChip(
              icon: Icons.visibility_off_outlined,
              label: 'Hide suggestions',
              onPressed: _hideSuggestions,
            ),
            const SizedBox(width: 8),
          ],
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
