import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../theme/drift_theme.dart';
import '../theme/theme_id.dart';

/// Theme picker option A: one row per theme with a strip of its colours
/// (background, card, accent, off track, on track) and a radio.
class ThemePickerScreen extends StatelessWidget {
  const ThemePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final c = context.drift;
    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: RadioGroup<ThemeId>(
        groupValue: settings.theme,
        onChanged: (id) {
          if (id != null) settings.setTheme(id);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final id in ThemeId.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: c.card,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: id == settings.theme ? c.accent : c.line,
                      width: id == settings.theme ? 1.5 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => settings.setTheme(id),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                      child: Row(
                        children: [
                          _Strip(colors: DriftColors.of(id)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              id.label,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                          Radio<ThemeId>(value: id),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.colors});

  final DriftColors colors;

  @override
  Widget build(BuildContext context) {
    final swatches = [
      colors.bg,
      colors.card,
      colors.accent,
      colors.offTrack,
      colors.onTrack,
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: context.drift.line),
        borderRadius: BorderRadius.circular(7),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          for (final s in swatches) Container(width: 16, height: 26, color: s),
        ],
      ),
    );
  }
}
