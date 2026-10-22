import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../services/unsorted_loader.dart';
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

/// Learned rules option B: two tabs. Sorted is option A, every (block,
/// app) answer grouped by block with an On track, Neutral or Off track
/// tag; tap a row to move it to the next answer, swipe it to forget it
/// (with Undo). Not sorted lists the apps used in a block over the last 14
/// days that have only a guess, under the same block headings, each with
/// the three answers (option C) and Drift's guess drawn dashed.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  late final AppServices _services;
  List<_Group>? _groups;
  List<UnsortedPair>? _unsorted;

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
    final unsorted = await loadUnsorted(_services);
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
    _services.toSort.value = _unsorted!.length;
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

  /// On track, then Neutral, then Off track, then round again.
  Future<void> _flip(_Rule r) async {
    final next = switch (r.verdict) {
      Verdict.onTrack => Verdict.neutral,
      Verdict.neutral => Verdict.offTrack,
      _ => Verdict.onTrack,
    };
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
  Future<void> _answer(UnsortedPair u, Verdict verdict) async {
    if (!_pending.add(u.id)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _unsorted?.remove(u));
    _services.toSort.value = _unsorted?.length ?? 0;
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
    showAppToastOn(
      messenger,
      '${u.label} counts as ${verdictLabel(verdict).toLowerCase()} in ${u.blockName}',
      tone: verdict == Verdict.onTrack ? AppToastTone.success : AppToastTone.change,
      icon: switch (verdict) {
        Verdict.onTrack => Icons.check,
        Verdict.neutral => Icons.remove,
        _ => Icons.close,
      },
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
    // One heading per block, as on Sorted: the block used most recently
    // first, and the newest app first inside it. The answer is per block,
    // so an app used in two blocks is asked about under each.
    final byBlock = <String, List<UnsortedPair>>{};
    for (final u in unsorted) {
      (byBlock[u.id.$1] ??= []).add(u);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Apps used in a block over the last $unsortedDays days that '
            'Drift has only guessed about. Pick what each counts as in its '
            "block; the dashed answer is Drift's guess. Neutral is fine in "
            'that block but leaves the app distracting for the rest of the day.',
            style: text.bodySmall?.copyWith(color: c.textSecondary),
          ),
        ),
        for (final MapEntry(:key, value: pairs) in byBlock.entries)
          SettingsGroup(
            key: ValueKey('unsortedGroup|$key'),
            title: pairs.first.blockName,
            children: [
              for (final u in pairs)
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
              'Tap an app to move it between on track, neutral and off '
              'track. Swipe to forget it.',
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

/// One guessed pair under its block's heading (option C): the app and
/// "Guessed on track" or "Guessed off track", with On track, Neutral and
/// Off track on a line of their own under it. The guessed answer has a
/// dashed edge.
class _UnsortedRow extends StatelessWidget {
  const _UnsortedRow({
    super.key,
    required this.item,
    required this.services,
    required this.onAnswer,
  });

  final UnsortedPair item;
  final AppServices services;
  final ValueChanged<Verdict> onAnswer;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final guessedOff = item.guess == Verdict.guessedOff;
    return Material(
      color: c.card,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                      Text(
                        guessedOff ? 'Guessed off track' : 'Guessed on track',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Under the name, lined up with it, so three answers fit a
            // narrow phone; they wrap rather than overflow with large text.
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _AnswerPill(
                    verdict: Verdict.onTrack,
                    guessed: !guessedOff,
                    onPressed: () => onAnswer(Verdict.onTrack),
                  ),
                  _AnswerPill(
                    verdict: Verdict.neutral,
                    guessed: false,
                    onPressed: () => onAnswer(Verdict.neutral),
                  ),
                  _AnswerPill(
                    verdict: Verdict.offTrack,
                    guessed: guessedOff,
                    onPressed: () => onAnswer(Verdict.offTrack),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One answer as an outlined pill: the edge in the verdict colour and the
/// words in the text colour, never coloured text on a coloured fill. The
/// guessed answer's edge is dashed.
class _AnswerPill extends StatelessWidget {
  const _AnswerPill({
    required this.verdict,
    required this.guessed,
    required this.onPressed,
  });

  final Verdict verdict;
  final bool guessed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final color = verdictColor(c, verdict);
    final label = verdictLabel(verdict);
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        backgroundColor: c.card,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        visualDensity: VisualDensity.compact,
        // The dashed edge is painted around the widget's own box, so the
        // box must be the pill, without the extra tap margin.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        side: guessed
            ? BorderSide.none
            : BorderSide(color: color.withValues(alpha: 0.8), width: 1.5),
      ),
      child: Text(label),
    );
    return Semantics(
      label: guessed ? "$label, Drift's guess" : label,
      excludeSemantics: true,
      button: true,
      onTap: onPressed,
      child: guessed
          ? CustomPaint(
              foregroundPainter: DashedBorderPainter(color: color, radius: 18),
              child: button,
            )
          : button,
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
            hint: 'Move between on track, neutral and off track',
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
