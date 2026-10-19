import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/models.dart';
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

/// Learned rules option A: every (block, app) answer, grouped by block,
/// with an On track or Off track tag. Tap a row to switch it, swipe it to
/// forget it (with Undo).
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  late final AppServices _services;
  List<_Group>? _groups;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _load();
  }

  Future<void> _load() async {
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
    if (mounted) setState(() => _groups = groups);
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
    await _services.rules.deleteRule(r.key, r.p);
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

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final groups = _groups;

    Widget body;
    if (groups == null) {
      body = const SizedBox.shrink();
    } else if (groups.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lightbulb_outline, size: 40, color: c.textSecondary),
              const SizedBox(height: 14),
              Text(
                'Nothing learned yet. Answer a question on the Today tab, '
                'or add apps to a block.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
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

    return Scaffold(
      appBar: AppBar(title: const Text('Learned rules')),
      body: SafeArea(top: false, child: body),
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
