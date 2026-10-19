import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../theme/drift_theme.dart';
import '../widgets/plan_timeline.dart';

/// Opens the block editor (option A, a form) as a full-screen page.
///
/// Pass [block] to edit it, or nothing to add one, prefilled with
/// [startMin] and [endMin] when the timeline drew a range. [date] is the
/// day the Plan tab shows: a new block with no repeat days is a one-off on
/// that day, and "This day only" edits act on it.
///
/// The services are handed to the page directly instead of read from the
/// route's context, so the editor works wherever the provider sits.
Future<void> showBlockEditor(
  BuildContext context, {
  PlanBlock? block,
  required DateTime date,
  int? startMin,
  int? endMin,
}) {
  final services = context.read<AppServices>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => BlockEditorScreen(
        services: services,
        block: block,
        date: date,
        startMin: startMin,
        endMin: endMin,
      ),
    ),
  );
}

/// Short day letters for the repeat chips, Monday first, matching the bit
/// order of [PlanBlock.repeatMask].
const _dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const _dayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _dayLong = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// "every day", "every weekday", "every weekend" or "every Mon, Wed".
String repeatDaysLabel(int mask) {
  if (mask == PlanBlock.everyDay) return 'every day';
  if (mask == PlanBlock.weekdays) return 'every weekday';
  if (mask == 0x60) return 'every weekend';
  final days = [
    for (var i = 0; i < 7; i++)
      if (mask & (1 << i) != 0) _dayShort[i],
  ];
  return 'every ${days.join(', ')}';
}

String _capitalised(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Which days a change to a repeating block applies to.
enum _Scope { thisDay, every }

/// Launcher icons by package, kept for the life of the process so the
/// picker and the chips never ask Android for the same icon twice.
final _iconCache = <String, Future<Uint8List?>>{};

class BlockEditorScreen extends StatefulWidget {
  const BlockEditorScreen({
    super.key,
    required this.services,
    this.block,
    required this.date,
    this.startMin,
    this.endMin,
  });

  final AppServices services;
  final PlanBlock? block;
  final DateTime date;
  final int? startMin;
  final int? endMin;

  @override
  State<BlockEditorScreen> createState() => _BlockEditorScreenState();
}

class _BlockEditorScreenState extends State<BlockEditorScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.block?.name ?? '',
  );
  late int _start = widget.block?.startMin ?? widget.startMin ?? 9 * 60;
  late int _end =
      widget.block?.endMin ??
      widget.endMin ??
      (_start + 60 > 1440 ? 1440 : _start + 60);
  late int _mask = _isPast ? 0 : (widget.block?.repeatMask ?? 0);
  late int _colorIdx = widget.block?.colorIdx ?? 0;
  late bool _anyApp = widget.block?.anyApp ?? false;

  /// Packages in insertion order, so chips keep the order they were added.
  final _allowed = <String>{};
  final _offTrack = <String>{};

  /// The rules stored for the block's name when the editor opened. Saving
  /// writes only the difference, and a rename moves exactly these.
  Map<String, Verdict> _initialRules = const {};

  List<AppInfo> _apps = const [];
  List<PlanBlock> _others = const [];
  bool _submitted = false;
  bool _saving = false;

  AppServices get _services => widget.services;

  String get _dateKey => dateKey(widget.date);

  /// Dates are compared as yyyy-MM-dd strings, which sort like dates.
  bool get _isPast =>
      _dateKey.compareTo(dateKey(widget.services.clock.now())) < 0;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onNameChanged);
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    if (_submitted) setState(() {});
  }

  Future<void> _load() async {
    final blocks = await _services.plans.allBlocks();
    final rules = await _services.rules.allRules();
    final apps = await _loadApps();
    if (!mounted) return;
    final original = widget.block;
    final initial = <String, Verdict>{};
    if (original != null) {
      final key = blockKey(original.name);
      for (final MapEntry(key: (k, p), :value) in rules.entries) {
        if (k == key) initial[p] = value;
      }
    }
    setState(() {
      _others = blocks;
      _apps = apps;
      _initialRules = initial;
      for (final MapEntry(key: p, :value) in initial.entries) {
        (value == Verdict.onTrack ? _allowed : _offTrack).add(p);
      }
    });
  }

  /// The apps table, or the live launcher list when the table is still
  /// empty (before the first ingest has stored it).
  Future<List<AppInfo>> _loadApps() async {
    final stored = await _services.apps.all();
    if (stored.isNotEmpty) return stored;
    try {
      final raw = await _services.usage.listApps();
      final apps = [for (final m in raw) ?AppInfo.fromMap(m)];
      apps.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return apps;
    } catch (e) {
      debugPrint('listApps failed: $e');
      return const [];
    }
  }

  String _labelFor(String p) {
    for (final a in _apps) {
      if (a.p == p) return a.label;
    }
    return p;
  }

  Future<Uint8List?> _iconFor(String p) => _iconCache.putIfAbsent(p, () async {
    try {
      final bytes = await _services.usage.appIcon(p);
      return bytes == null ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  });

  String? get _nameError =>
      _submitted && _name.text.trim().isEmpty ? 'Enter a name' : null;

  String? get _timeError =>
      _submitted && _end <= _start ? 'End must be after start' : null;

  /// Other blocks on this date that share time with the edited range.
  /// The block being edited is left out.
  List<PlanBlock> get _overlaps {
    final id = widget.block?.id;
    return [
      for (final b in activeBlocks(widget.date, _others))
        if (b.id != id && b.startMin < _end && _start < b.endMin) b,
    ];
  }

  PlanBlock _built({
    int? id,
    required int mask,
    String? date,
    List<String> skipDates = const [],
  }) => PlanBlock(
    id: id,
    name: _name.text.trim(),
    startMin: _start,
    endMin: _end,
    colorIdx: _colorIdx,
    repeatMask: mask,
    date: mask == 0 ? (date ?? _dateKey) : null,
    skipDates: skipDates,
    anyApp: _anyApp,
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _submitted = true);
    if (_nameError != null || _timeError != null) return;
    final original = widget.block;
    final plans = _services.plans;
    final mask = _isPast ? 0 : _mask;
    var keepOldRules = false;

    if (original == null) {
      setState(() => _saving = true);
      await plans.insertBlock(_built(mask: mask));
    } else if (original.repeatMask != 0 && (mask != 0 || _isPast)) {
      // A repeating block, edited on a day where it still repeats or on a
      // past day, where only that day may change.
      final scope = _isPast
          ? _Scope.thisDay
          : await _askScope(
              title: 'Change which days?',
              message:
                  '"${original.name}" repeats ${repeatDaysLabel(original.repeatMask)}.',
              everyLabel: _capitalised(repeatDaysLabel(mask)),
            );
      if (scope == null) return;
      setState(() => _saving = true);
      if (scope == _Scope.thisDay) {
        await plans.insertBlock(_built(mask: 0));
        await plans.updateBlock(original.copyWith(
          skipDates: {...original.skipDates, _dateKey}.toList(),
        ));
        // The repeating block keeps its old name on its other days.
        keepOldRules = true;
      } else {
        await plans.updateBlock(
          _built(id: original.id, mask: mask, skipDates: original.skipDates),
        );
      }
    } else {
      // A one-off, or a repeating block whose days were all cleared: it
      // becomes (or stays) a one-off on this date.
      setState(() => _saving = true);
      await plans.updateBlock(
        _built(
          id: original.id,
          mask: mask,
          date: original.repeatMask == 0 ? original.date : _dateKey,
        ),
      );
    }

    await _writeRules(original?.name, keepOldRules: keepOldRules);
    _services.bump();
    if (mounted) Navigator.of(context).pop();
  }

  /// Saves the app chips as `app_rules`. Under an unchanged key only the
  /// difference is written. On a rename the rules go to the new key and
  /// leave the old one, unless the old name is still in use (the
  /// repeating block after a "This day only" edit, or another block with
  /// that name), in which case they are copied instead. New rules are
  /// written before old ones are removed, so a case-only rename, which
  /// keeps the key, never loses them.
  Future<void> _writeRules(String? oldName, {required bool keepOldRules}) async {
    final rules = _services.rules;
    final now = _services.clock.now();
    final newName = _name.text.trim();
    final desired = <String, Verdict>{
      for (final p in _allowed) p: Verdict.onTrack,
      for (final p in _offTrack) p: Verdict.offTrack,
    };
    final renamed = oldName != null && blockKey(oldName) != blockKey(newName);

    if (!renamed) {
      for (final MapEntry(key: p, :value) in desired.entries) {
        if (_initialRules[p] != value) {
          await rules.upsertRule(newName, p, value, now);
        }
      }
      for (final p in _initialRules.keys) {
        if (!desired.containsKey(p)) await rules.deleteRule(newName, p);
      }
      return;
    }

    for (final MapEntry(key: p, :value) in desired.entries) {
      await rules.upsertRule(newName, p, value, now);
    }
    final oldKey = blockKey(oldName);
    final stillUsed = keepOldRules ||
        _others.any(
          (b) => b.id != widget.block?.id && blockKey(b.name) == oldKey,
        );
    if (stillUsed) return;
    for (final p in _initialRules.keys) {
      await rules.deleteRule(oldName, p);
    }
  }

  Future<_Scope?> _askScope({
    required String title,
    required String message,
    required String everyLabel,
  }) => showDialog<_Scope>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, _Scope.thisDay),
            child: const Text('This day only'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.pop(context, _Scope.every),
            child: Text(everyLabel),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  Future<void> _delete() async {
    final original = widget.block;
    if (original == null) return;
    final plans = _services.plans;
    _Scope? scope;
    if (original.repeatMask != 0 && !_isPast) {
      scope = await _askScope(
        title: 'Delete "${original.name}"?',
        message: 'It repeats ${repeatDaysLabel(original.repeatMask)}.',
        everyLabel: _capitalised(repeatDaysLabel(original.repeatMask)),
      );
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            original.repeatMask != 0
                ? 'Delete "${original.name}" from this day?'
                : 'Delete "${original.name}"?',
          ),
          content: const Text('Its learned app rules stay for other blocks with this name.'),
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
      if (ok == true) {
        scope = original.repeatMask != 0 ? _Scope.thisDay : _Scope.every;
      }
    }
    if (scope == null) return;
    if (scope == _Scope.thisDay) {
      await plans.updateBlock(original.copyWith(
        skipDates: {...original.skipDates, _dateKey}.toList(),
      ));
    } else {
      await plans.deleteBlock(original.id!);
    }
    _services.bump();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => _TimeWheelSheet(
        title: isStart ? 'Start' : 'End',
        initial: isStart ? _start : _end,
        allowMidnightEnd: !isStart,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _pickApps({required bool allowed}) async {
    final mine = allowed ? _allowed : _offTrack;
    final other = allowed ? _offTrack : _allowed;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => AppPickerSheet(
        title: allowed ? 'Allowed apps' : 'Off-track apps',
        apps: _apps,
        selected: mine,
        otherSelected: other,
        otherLabel: allowed ? 'In off-track apps' : 'In allowed apps',
        iconFor: _iconFor,
        onChanged: (p, on) => setState(() {
          if (on) {
            // An app has one verdict per block, so picking it here takes
            // it out of the other list.
            other.remove(p);
            mine.add(p);
          } else {
            mine.remove(p);
          }
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final editing = widget.block != null;
    final overlaps = _overlaps;
    final timeError = _timeError;

    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(editing ? 'Edit block' : 'New block'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'Deep work',
                errorText: _nameError,
              ),
            ),
            const _SectionLabel('Time'),
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: 'Start',
                    value: formatMinute(_start),
                    error: timeError != null,
                    onTap: () => _pickTime(isStart: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TimeField(
                    label: 'End',
                    value: formatMinute(_end),
                    error: timeError != null,
                    onTap: () => _pickTime(isStart: false),
                  ),
                ),
              ],
            ),
            if (timeError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Text(
                  timeError,
                  style: text.bodySmall?.copyWith(color: c.offTrack),
                ),
              ),
            if (overlaps.isNotEmpty && _end > _start)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _OverlapWarning(blocks: overlaps),
              ),
            const _SectionLabel('Repeat'),
            _RepeatDays(
              mask: _mask,
              enabled: !_isPast,
              onChanged: (m) => setState(() => _mask = m),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                _isPast
                    ? 'Past days change only that day'
                    : _mask == 0
                    ? 'This day only, ${DateFormat('EEE d MMM').format(widget.date)}'
                    : _capitalised(repeatDaysLabel(_mask)),
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ),
            const _SectionLabel('Colour'),
            _ColourRow(
              selected: _colorIdx,
              onChanged: (i) => setState(() => _colorIdx = i),
            ),
            const _SectionLabel(
              'Allowed apps',
              help: 'Count as on track in this block',
            ),
            _AppChips(
              packages: _allowed.toList(),
              labelFor: _labelFor,
              iconFor: _iconFor,
              onAdd: () => _pickApps(allowed: true),
              onRemove: (p) => setState(() => _allowed.remove(p)),
            ),
            const _SectionLabel(
              'Off-track apps',
              help: 'Count as drift in this block',
            ),
            _AppChips(
              packages: _offTrack.toList(),
              labelFor: _labelFor,
              iconFor: _iconFor,
              onAdd: () => _pickApps(allowed: false),
              onRemove: (p) => setState(() => _offTrack.remove(p)),
            ),
            const _SectionLabel('Other apps'),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Ask me')),
                ButtonSegment(value: true, label: Text('Any app')),
              ],
              selected: {_anyApp},
              onSelectionChanged: (s) => setState(() => _anyApp = s.first),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                _anyApp
                    ? 'Every other app counts as on track'
                    : 'Drift guesses from the app type and asks you',
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ),
            if (editing) ...[
              const SizedBox(height: 28),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: c.offTrack),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete block'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title, {this.help});

  final String title;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleSmall?.copyWith(color: c.text)),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                help!,
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.error,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$label $value',
      excludeSemantics: true,
      child: Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: error ? c.offTrack : c.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: text.labelMedium?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(value, style: text.titleLarge),
                    ],
                  ),
                ),
                Icon(Icons.schedule, size: 20, color: c.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverlapWarning extends StatelessWidget {
  const _OverlapWarning({required this.blocks});

  final List<PlanBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final first = blocks.first;
    final others = blocks.length - 1;
    final what =
        '${first.name} (${formatRange(first.startMin, first.endMin)})'
        '${others > 0 ? ' and $others more' : ''}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.guessed.withValues(alpha: 0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: c.guessed),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Overlaps $what. You can still save it.',
              style: text.bodyMedium?.copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Seven round day toggles, Monday first. None selected means the block
/// is for the editor's date only.
class _RepeatDays extends StatelessWidget {
  const _RepeatDays({
    required this.mask,
    required this.enabled,
    required this.onChanged,
  });

  final int mask;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Builder(
                    builder: (context) {
                      final on = mask & (1 << i) != 0;
                      return Semantics(
                        label: _dayLong[i],
                        selected: on,
                        button: true,
                        excludeSemantics: true,
                        child: Material(
                          color: on ? c.accent : c.card,
                          shape: CircleBorder(
                            side: BorderSide(
                              color: on ? c.accent : c.line,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('repeatDay$i'),
                            onTap: enabled
                                ? () => onChanged(mask ^ (1 << i))
                                : null,
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _dayLetters[i],
                                  style: text.labelLarge?.copyWith(
                                    color: on ? c.onAccent : c.text,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ColourRow extends StatelessWidget {
  const _ColourRow({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        for (var i = 0; i < blockColorNames.length; i++)
          Semantics(
            label: '${blockColorNames[i]} colour',
            selected: i == selected,
            button: true,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: Container(
                width: 36,
                height: 36,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: i == selected ? c.text : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: blockColor(context, i),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AppChips extends StatelessWidget {
  const _AppChips({
    required this.packages,
    required this.labelFor,
    required this.iconFor,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> packages;
  final String Function(String p) labelFor;
  final Future<Uint8List?> Function(String p) iconFor;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: c.text);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in packages)
          InputChip(
            avatar: AppIcon(
              package: p,
              label: labelFor(p),
              size: 22,
              iconFor: iconFor,
            ),
            label: Text(labelFor(p)),
            labelStyle: labelStyle,
            backgroundColor: c.card,
            side: BorderSide(color: c.line),
            shape: const StadiumBorder(),
            deleteIcon: Icon(Icons.close, size: 16, color: c.textSecondary),
            deleteButtonTooltipMessage: 'Remove',
            onDeleted: () => onRemove(p),
          ),
        ActionChip(
          avatar: Icon(Icons.add, size: 18, color: c.textSecondary),
          label: const Text('Add'),
          labelStyle: labelStyle,
          backgroundColor: c.bg,
          side: BorderSide(color: c.line),
          shape: const StadiumBorder(),
          onPressed: onAdd,
        ),
      ],
    );
  }
}

/// An app's launcher icon, or a lettered circle while it loads or when
/// Android has none.
class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.package,
    required this.label,
    required this.size,
    required this.iconFor,
  });

  final String package;
  final String label;
  final double size;
  final Future<Uint8List?> Function(String p) iconFor;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.line, shape: BoxShape.circle),
      child: Text(
        label.isEmpty ? '?' : label.characters.first.toUpperCase(),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: c.text,
          fontSize: size * 0.48,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
    return FutureBuilder<Uint8List?>(
      future: iconFor(package),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return fallback;
        return Image.memory(
          bytes,
          width: size,
          height: size,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
  }
}

/// The app picker: a searchable list of launchable apps with a tick for
/// each one picked. Changes apply as they are tapped, so closing the sheet
/// by dragging it down keeps them.
class AppPickerSheet extends StatefulWidget {
  const AppPickerSheet({
    super.key,
    required this.title,
    required this.apps,
    required this.selected,
    required this.otherSelected,
    required this.otherLabel,
    required this.iconFor,
    required this.onChanged,
  });

  final String title;
  final List<AppInfo> apps;
  final Set<String> selected;
  final Set<String> otherSelected;

  /// Subtitle for an app already in the other list, which picking moves.
  final String otherLabel;
  final Future<Uint8List?> Function(String p) iconFor;
  final void Function(String p, bool selected) onChanged;

  @override
  State<AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<AppPickerSheet> {
  final _query = TextEditingController();
  late final Set<String> _picked = {...widget.selected};
  late final Set<String> _other = {...widget.otherSelected};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _toggle(String p) {
    final on = !_picked.contains(p);
    setState(() {
      if (on) {
        _picked.add(p);
        _other.remove(p);
      } else {
        _picked.remove(p);
      }
    });
    widget.onChanged(p, on);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final q = _query.text.trim().toLowerCase();
    final shown = [
      for (final a in widget.apps)
        if (q.isEmpty ||
            a.label.toLowerCase().contains(q) ||
            a.p.toLowerCase().contains(q))
          a,
    ];
    final media = MediaQuery.of(context);

    Widget body;
    if (widget.apps.isEmpty) {
      body = const _EmptyMessage(
        icon: Icons.apps_outlined,
        message: 'No apps found. Check that Usage access is on.',
      );
    } else if (shown.isEmpty) {
      body = _EmptyMessage(
        icon: Icons.search_off,
        message: 'No apps match "${_query.text.trim()}"',
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final a = shown[i];
          final on = _picked.contains(a.p);
          return ListTile(
            onTap: () => _toggle(a.p),
            leading: AppIcon(
              package: a.p,
              label: a.label,
              size: 36,
              iconFor: widget.iconFor,
            ),
            title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: _other.contains(a.p) ? Text(widget.otherLabel) : null,
            trailing: Icon(
              on ? Icons.check_circle : Icons.radio_button_unchecked,
              color: on ? c.accent : c.textSecondary,
            ),
          );
        },
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: media.size.height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title, style: text.titleMedium)),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            if (widget.apps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search apps',
                    prefixIcon: Icon(Icons.search, color: c.textSecondary),
                    isDense: true,
                  ),
                ),
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: c.textSecondary),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hour and minute wheels in 5-minute steps. The end picker also offers
/// 24:00, so a block can run to midnight.
class _TimeWheelSheet extends StatefulWidget {
  const _TimeWheelSheet({
    required this.title,
    required this.initial,
    required this.allowMidnightEnd,
  });

  final String title;
  final int initial;
  final bool allowMidnightEnd;

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  late int _hour = (widget.initial ~/ 60).clamp(0, _maxHour);
  late int _minute = _hour == 24 ? 0 : (widget.initial % 60) ~/ 5 * 5;
  late final _hours = FixedExtentScrollController(initialItem: _hour);
  late final _minutes = FixedExtentScrollController(initialItem: _minute ~/ 5);

  int get _maxHour => widget.allowMidnightEnd ? 24 : 23;

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
      width: 88,
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
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: text.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
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
                        },
                      ),
                      Text(
                        ':',
                        textScaler: TextScaler.noScaling,
                        style: text.headlineSmall,
                      ),
                      _wheel(
                        controller: _minutes,
                        count: 12,
                        label: (i) => (i * 5).toString().padLeft(2, '0'),
                        onSelected: (i) => setState(() => _minute = i * 5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _hour == 24 ? 1440 : _hour * 60 + _minute,
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
