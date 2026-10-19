import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../services/period_loader.dart';
import '../theme/drift_theme.dart';
import '../widgets/ask_sheet.dart';
import '../widgets/settings_group.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/verdict_style.dart';
import 'block_editor_screen.dart';

/// One learned rule as the list shows it.
class _Rule {
  _Rule({
    required this.key,
    required this.p,
    required this.label,
    required this.verdict,
  });

  /// The stored block key, lower-cased.
  final String key;
  final String p;
  final String label;
  Verdict verdict;
}

/// The rules of one block name, under the block's own spelling.
class _Group {
  _Group(this.key, this.title, this.rules);

  final String key;
  final String title;
  final List<_Rule> rules;
}

/// One (block, app) pair Drift has only guessed about, as the Not sorted
/// tab shows it.
class _Unsorted {
  const _Unsorted({
    required this.blockName,
    required this.p,
    required this.label,
    required this.guess,
    required this.start,
  });

  /// The block's own spelling on the day the app was last used in it.
  final String blockName;
  final String p;
  final String label;

  /// [Verdict.guessedOn] or [Verdict.guessedOff].
  final Verdict guess;

  /// When the newest guessed use started; the list sorts on it.
  final DateTime start;

  (String, String) get id => (blockKey(blockName), p);
}

/// How many days back, today included, the Not sorted tab looks.
const _unsortedDays = 14;

/// Learned rules option B: two tabs. Sorted is option A, every (block,
/// app) answer grouped by block with an On track or Off track tag; tap a
/// row to switch it, swipe it to forget it (with Undo). Not sorted lists
/// the apps used in a block over the last 14 days that have only a guess,
/// each with a tick and a cross that store the answer.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  late final AppServices _services;
  List<_Group>? _groups;
  List<_Unsorted>? _unsorted;

  /// Answers being written. A load that read the database before the write
  /// landed must not bring the row back.
  final _pending = <(String, String)>{};

  /// Rules being deleted, by (block key, package), for the same reason.
  final _forgetting = <(String, String)>{};

  /// Counts loads, so only the newest one is applied.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _services.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _services.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final groups = await _loadGroups();
    final unsorted = await _loadUnsorted();
    if (!mounted || generation != _generation) return;
    setState(() {
      // A rule being forgotten stays gone even if this load read it first.
      for (final g in groups) {
        g.rules.removeWhere((r) => _forgetting.contains((r.key, r.p)));
      }
      groups.removeWhere((g) => g.rules.isEmpty);
      _groups = groups;
      _unsorted = [
        for (final u in unsorted)
          if (!_pending.contains(u.id)) u,
      ];
    });
  }

  /// Every guessed (block, app) pair from the last [_unsortedDays] days,
  /// one row per pair (the newest use wins), newest first.
  Future<List<_Unsorted>> _loadUnsorted() async {
    final now = _services.clock.now();
    final days = await loadDays(
      _services,
      DateTime(now.year, now.month, now.day - (_unsortedDays - 1)),
      now,
    );
    final byPair = <(String, String), _Unsorted>{};
    for (final day in days) {
      for (final s in day.unanswered) {
        final u = _Unsorted(
          blockName: s.blockName!.trim(),
          p: s.p!,
          label: day.labelOf(s.p),
          guess: s.verdict,
          start: s.start,
        );
        final seen = byPair[u.id];
        if (seen == null || u.start.isAfter(seen.start)) byPair[u.id] = u;
      }
    }
    return byPair.values.toList()..sort((a, b) => b.start.compareTo(a.start));
  }

  Future<List<_Group>> _loadGroups() async {
    final rules = await _services.rules.allRules();
    final blocks = await _services.plans.allBlocks();
    final apps = await _services.apps.all();
    final labels = {for (final a in apps) a.p: a.label};
    final names = <String, String>{};
    for (final b in blocks) {
      names.putIfAbsent(blockKey(b.name), () => b.name.trim());
    }

    final byKey = <String, List<_Rule>>{};
    for (final MapEntry(key: (key, p), value: verdict) in rules.entries) {
      byKey
          .putIfAbsent(key, () => [])
          .add(_Rule(key: key, p: p, label: labels[p] ?? p, verdict: verdict));
    }
    final groups = [
      for (final MapEntry(:key, :value) in byKey.entries)
        _Group(
          key,
          names[key] ?? _capitalised(key),
          value..sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          ),
        ),
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return groups;
  }

  static String _capitalised(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Future<void> _flip(_Rule r) async {
    final next = r.verdict == Verdict.onTrack
        ? Verdict.offTrack
        : Verdict.onTrack;
    setState(() => r.verdict = next);
    await _services.rules.upsertRule(r.key, r.p, next, _services.clock.now());
    _services.bump();
  }

  Future<void> _forget(_Group g, _Rule r) async {
    final messenger = ScaffoldMessenger.of(context);
    // The row must leave the tree before the next frame, or Dismissible
    // asserts that a dismissed child is still there.
    setState(() {
      g.rules.remove(r);
      if (g.rules.isEmpty) _groups?.remove(g);
    });
    _forgetting.add((r.key, r.p));
    try {
      await _services.rules.deleteRule(r.key, r.p);
    } finally {
      _forgetting.remove((r.key, r.p));
    }
    _services.bump();
    showAppToastOn(
      messenger,
      'Forgot ${r.label} in ${g.title}',
      tone: AppToastTone.removal,
      icon: Icons.delete_outline,
      actionLabel: 'Undo',
      onAction: () async {
        await _services.rules.upsertRule(
          r.key,
          r.p,
          r.verdict,
          _services.clock.now(),
        );
        await _load();
        _services.bump();
      },
    );
  }

  /// Stores [verdict] for every block named like [u]'s, then lets the
  /// reload move the pair to Sorted.
  Future<void> _answer(_Unsorted u, Verdict verdict) async {
    if (!_pending.add(u.id)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _unsorted?.remove(u));
    try {
      await _services.rules.upsertRule(
        u.blockName,
        u.p,
        verdict,
        _services.clock.now(),
      );
    } finally {
      _pending.remove(u.id);
    }
    _services.bump();
    final on = verdict == Verdict.onTrack;
    showAppToastOn(
      messenger,
      '${u.label} counts as ${on ? 'on' : 'off'} track in ${u.blockName}',
      tone: on ? AppToastTone.success : AppToastTone.change,
      icon: on ? Icons.check : Icons.close,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final n = _unsorted?.length ?? 0;
    final tabStyle = text.titleSmall?.copyWith(fontWeight: FontWeight.w500);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Learned rules'),
          bottom: TabBar(
            labelColor: c.text,
            unselectedLabelColor: c.textSecondary,
            labelStyle: tabStyle,
            unselectedLabelStyle: tabStyle,
            indicatorColor: c.accent,
            indicatorWeight: 2.5,
            dividerColor: c.line,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              const Tab(text: 'Sorted'),
              Tab(text: n == 0 ? 'Not sorted' : 'Not sorted ($n)'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          // Rows swipe sideways to be forgotten, so the pages change only
          // from the tabs; a missed page swipe must not forget a rule.
          child: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [_sorted(context), _notSorted(context)],
          ),
        ),
      ),
    );
  }

  Widget _notSorted(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final unsorted = _unsorted;
    if (unsorted == null) return const SizedBox.shrink();
    if (unsorted.isEmpty) {
      return const _EmptyState(
        icon: Icons.task_alt,
        message: 'Nothing waiting. Drift asks about new apps as you use them.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Apps used in a block that Drift has only guessed about. '
            'Tick if the app fits the block, cross if it does not.',
            style: text.bodySmall?.copyWith(color: c.textSecondary),
          ),
        ),
        SettingsGroup(
          title: 'Last $_unsortedDays days',
          children: [
            for (final u in unsorted)
              _UnsortedRow(
                key: ValueKey('unsorted|${u.id.$1}|${u.p}'),
                item: u,
                services: _services,
                onAnswer: (v) => _answer(u, v),
              ),
          ],
        ),
      ],
    );
  }

  Widget _sorted(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final groups = _groups;

    Widget body;
    if (groups == null) {
      body = const SizedBox.shrink();
    } else if (groups.isEmpty) {
      body = const _EmptyState(
        icon: Icons.lightbulb_outline,
        message:
            'Nothing learned yet. Answer a question on the Today tab, '
            'or add apps to a block.',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Tap an app to switch between on and off track. '
              'Swipe to forget it.',
              style: text.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ),
          for (final g in groups)
            SettingsGroup(
              key: ValueKey('group|${g.key}'),
              title: g.title,
              children: [
                for (final r in g.rules)
                  _RuleRow(
                    key: ValueKey('rule|${r.key}|${r.p}'),
                    rule: r,
                    services: _services,
                    onTap: () => _flip(r),
                    onDismissed: () => _forget(g, r),
                  ),
              ],
            ),
        ],
      );
    }
    return body;
  }
}

/// A centred icon and message for a tab with nothing in it.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: c.textSecondary),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// One guessed pair: the app, "Deep work · guess on" or "guess off", and a
/// tick and a cross in the verdict colours.
class _UnsortedRow extends StatelessWidget {
  const _UnsortedRow({
    super.key,
    required this.item,
    required this.services,
    required this.onAnswer,
  });

  final _Unsorted item;
  final AppServices services;
  final ValueChanged<Verdict> onAnswer;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    // A no-break space keeps "guess on" whole when the line wraps.
    final guess = item.guess == Verdict.guessedOff
        ? 'guess off'
        : 'guess on';
    return Material(
      color: c.card,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          child: Row(
            children: [
              AppIcon(
                package: item.p,
                label: item.label,
                size: 32,
                iconFor: (p) => cachedAppIcon(services, p),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.blockName} · $guess',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _AnswerButton(
                tooltip: 'On track',
                icon: Icons.check,
                color: c.onTrack,
                onPressed: () => onAnswer(Verdict.onTrack),
              ),
              const SizedBox(width: 6),
              _AnswerButton(
                tooltip: 'Off track',
                icon: Icons.close,
                color: c.offTrack,
                onPressed: () => onAnswer(Verdict.offTrack),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An outlined circle on the card with the icon and edge in [color].
class _AnswerButton extends StatelessWidget {
  const _AnswerButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.outlined(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: color,
        backgroundColor: context.drift.card,
        side: BorderSide(color: color.withValues(alpha: 0.7), width: 1.5),
      ),
      icon: Icon(icon, size: 20, color: color),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.services,
    required this.onTap,
    required this.onDismissed,
  });

  final _Rule rule;
  final AppServices services;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Dismissible(
      key: ValueKey('dismiss|${rule.key}|${rule.p}'),
      background: const _SwipeBackground(alignment: Alignment.centerLeft),
      secondaryBackground: const _SwipeBackground(
        alignment: Alignment.centerRight,
      ),
      onDismissed: (_) => onDismissed(),
      child: Material(
        color: c.card,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            hint: 'Switch between on and off track',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    AppIcon(
                      package: rule.p,
                      label: rule.label,
                      size: 32,
                      iconFor: (p) => cachedAppIcon(services, p),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        rule.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(color: c.text),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _VerdictTag(verdict: rule.verdict),
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

/// An outlined pill in the verdict colour, on the card.
class _VerdictTag extends StatelessWidget {
  const _VerdictTag({required this.verdict});

  final Verdict verdict;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final color = verdictColor(c, verdict);
    // A shared minimum width keeps the tags in one column.
    return Container(
      constraints: const BoxConstraints(minWidth: 84),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: ShapeDecoration(
        color: c.card,
        shape: StadiumBorder(side: BorderSide(color: color, width: 1.2)),
      ),
      child: Text(
        verdictLabel(verdict),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// What a row uncovers while it is swiped: a neutral strip with a delete
/// icon and "Forget".
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final start = alignment == Alignment.centerLeft;
    return Container(
      color: c.bg,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!start) ...[
            Text('Forget', style: text.labelLarge?.copyWith(color: c.text)),
            const SizedBox(width: 8),
          ],
          Icon(Icons.delete_outline, size: 20, color: c.offTrack),
          if (start) ...[
            const SizedBox(width: 8),
            Text('Forget', style: text.labelLarge?.copyWith(color: c.text)),
          ],
        ],
      ),
    );
  }
}
