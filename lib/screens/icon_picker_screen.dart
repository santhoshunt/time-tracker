import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../icons/drift_icons.dart';
import '../theme/drift_theme.dart';
import '../widgets/undo_snackbar.dart';

/// Icon picker option A: a 3 by 2 grid of the six launcher icons. A tap
/// switches the home-screen icon at once.
class IconPickerScreen extends StatefulWidget {
  const IconPickerScreen({super.key});

  @override
  State<IconPickerScreen> createState() => _IconPickerScreenState();
}

class _IconPickerScreenState extends State<IconPickerScreen> {
  DriftIcon? _current;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final alias = await context.read<AppServices>().icons.current();
    if (mounted) setState(() => _current = DriftIcon.fromAlias(alias));
  }

  Future<void> _pick(DriftIcon icon) async {
    if (icon == _current) return;
    final messenger = ScaffoldMessenger.of(context);
    final previous = _current;
    setState(() => _current = icon);
    try {
      await context.read<AppServices>().icons.set(icon.aliasName);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _current = previous);
      showAppToastOn(
        messenger,
        "The icon didn't change: ${e.message ?? 'Android refused it'}.",
        tone: AppToastTone.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('App icon')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(
            'Your home screen may take a moment to update.',
            style: text.bodyMedium?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 20),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 18,
            crossAxisSpacing: 8,
            childAspectRatio: 0.82,
            children: [
              for (final icon in DriftIcon.values)
                _IconChoice(
                  icon: icon,
                  selected: icon == _current,
                  onTap: () => _pick(icon),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final DriftIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Semantics(
      selected: selected,
      button: true,
      label: icon.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? c.accent : Colors.transparent,
                  width: 2,
                ),
              ),
              // Two icons share Mono's background colour, so every tile
              // gets a hairline edge or it would melt into the page.
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: ShapeDecoration(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(64 * 30 / 96),
                    side: BorderSide(color: c.line),
                  ),
                ),
                child: DriftIconTile(icon, 64),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              icon.label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: selected ? c.text : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
