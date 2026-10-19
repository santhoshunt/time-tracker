/// One small sample screen per theme, so a change to a token or a component
/// theme shows up as a pixel diff: a score card, a plan block with every
/// bar colour, the common controls and the four-tab navigation bar.
@Tags(['golden'])
library;

import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';

class _Sample extends StatelessWidget {
  const _Sample();

  @override
  Widget build(BuildContext context) {
    final d = context.drift;
    final text = Theme.of(context).textTheme;
    final secondary = text.bodyMedium?.copyWith(color: d.textSecondary);

    Widget legend(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: text.labelMedium?.copyWith(color: d.textSecondary)),
      ],
    );

    Widget bar(Color color, int flex) => Expanded(
      flex: flex,
      child: ColoredBox(color: color),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text('74%', style: text.displaySmall),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('On plan so far', style: text.titleMedium),
                        const SizedBox(height: 2),
                        Text('3 h 40 m planned, 52 m off', style: secondary),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: d.planFill,
              border: Border.all(color: d.planBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Deep work', style: text.titleSmall),
                Text('09:00 to 11:00', style: secondary),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 14,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        bar(d.onTrack, 5),
                        bar(d.offTrack, 2),
                        bar(d.guessed, 2),
                        bar(d.idleFill, 3),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [
                    legend(d.onTrack, 'On track'),
                    legend(d.offTrack, 'Off track'),
                    legend(d.guessed, 'Guessed'),
                    legend(d.idleFill, 'Idle'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'lanes', label: Text('Lanes')),
              ButtonSegment(value: 'ring', label: Text('Ring')),
            ],
            selected: const {'lanes'},
            onSelectionChanged: (_) {},
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Check on launch'),
            subtitle: const Text('Once a day'),
            value: true,
            onChanged: (_) {},
          ),
          const Divider(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {},
                  child: const Text('Not now'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('See versions'),
                ),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(
            icon: Icon(Icons.calendar_month),
            label: 'Plan',
          ),
          NavigationDestination(icon: Icon(Icons.insights), label: 'Review'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

void main() {
  setUpAll(loadDriftFonts);

  for (final theme in ThemeId.values) {
    testWidgets('theme tokens: ${theme.label}', (tester) async {
      await pumpGolden(tester, const _Sample(), theme: theme);
      await expectLater(
        find.byType(_Sample),
        matchesGoldenFile('goldens/theme_tokens_${theme.key}.png'),
      );
    });
  }

  testWidgets('theme tokens: Mono, small phone, 1.3 text', (tester) async {
    await pumpGolden(
      tester,
      const _Sample(),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    await expectLater(
      find.byType(_Sample),
      matchesGoldenFile('goldens/theme_tokens_mono_small_1_3.png'),
    );
  });
}
