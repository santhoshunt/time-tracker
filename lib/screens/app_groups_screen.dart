import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/app_groups.dart';
import '../theme/drift_theme.dart';
import '../widgets/group_style.dart';
import '../widgets/plan_timeline.dart' show DashedBorderPainter;
import 'group_editor_screen.dart';

/// Settings > App groups (list option B): two cards across, each with the
/// group's emoji, name, kind and app count inside a border in its colour,
/// and a dashed "+ New group" card at the end.
class AppGroupsScreen extends StatefulWidget {
  const AppGroupsScreen({super.key});

  @override
  State<AppGroupsScreen> createState() => _AppGroupsScreenState();
}

class _AppGroupsScreenState extends State<AppGroupsScreen> {
  late final AppServices _services = context.read<AppServices>();
  List<AppGroup>? _groups;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groups = await _services.groups.all();
    if (mounted) setState(() => _groups = groups);
  }

  Future<void> _open([AppGroup? group]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => GroupEditorScreen(group: group)),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        title: const Text('App groups'),
      ),
      body: groups == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Text(
                  'Group apps once, then pick the group in any block. '
                  'Distracting groups count as drift everywhere unless a '
                  'block allows them.',
                  style: text.bodySmall?.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, box) {
                    const gap = 12.0;
                    final w = (box.maxWidth - gap) / 2;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final g in groups)
                          SizedBox(width: w, child: _GroupCard(group: g, onTap: () => _open(g))),
                        SizedBox(width: w, child: _NewCard(onTap: _open)),
                      ],
                    );
                  },
                ),
              ],
            ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.onTap});

  final AppGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final distracting = group.kind == GroupKind.distracting;
    final n = group.apps.length;
    return Semantics(
      button: true,
      label: '${group.name}, ${distracting ? 'distracting' : 'productive'}, $n apps',
      excludeSemantics: true,
      child: Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: groupColor(context, group.colorIdx), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.emoji, textScaler: TextScaler.noScaling, style: const TextStyle(fontSize: 26)),
                const SizedBox(height: 6),
                Text(group.name, style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: distracting ? 'Distracting' : 'Productive',
                        style: TextStyle(color: distracting ? c.offTrack : c.onTrack),
                      ),
                      TextSpan(text: ' · ${n == 1 ? '1 app' : '$n apps'}'),
                    ],
                  ),
                  style: text.bodySmall?.copyWith(color: c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NewCard extends StatelessWidget {
  const _NewCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'New group',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: DashedBorderPainter(color: c.textSecondary.withValues(alpha: 0.6)),
          child: SizedBox(
            height: 104,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, color: c.accent),
                  const SizedBox(width: 6),
                  Text('New group', style: text.labelLarge?.copyWith(color: c.text)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
