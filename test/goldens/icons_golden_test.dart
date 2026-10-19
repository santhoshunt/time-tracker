/// The icon picker mask check: all six icons at 64 px under the circle and
/// the rounded-square mask, on the Mono background.
@Tags(['golden'])
library;

import 'package:drift_time/icons/drift_icons.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/golden.dart';

class _MaskGrid extends StatelessWidget {
  const _MaskGrid(this.mask, this.title);

  final IconMask mask;
  final String title;

  @override
  Widget build(BuildContext context) {
    const icons = DriftIcon.values;
    Widget tile(DriftIcon icon) => SizedBox(
      width: 104,
      child: Column(
        children: [
          DriftIconTile(icon, 64, mask: mask),
          const SizedBox(height: 6),
          Text(
            icon.label,
            style: Theme.of(context).textTheme.labelMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (var row = 0; row < 2; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var col = 0; col < 3; col++) tile(icons[row * 3 + col]),
              ],
            ),
          ),
      ],
    );
  }
}

void main() {
  setUpAll(loadDriftFonts);

  testWidgets('icon tiles under both masks', (tester) async {
    await pumpGolden(
      tester,
      Builder(
        builder: (context) => Scaffold(
          backgroundColor: context.drift.bg,
          body: const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                children: [
                  _MaskGrid(IconMask.circle, 'Circle mask'),
                  SizedBox(height: 16),
                  _MaskGrid(IconMask.squircle, 'Rounded-square mask'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/icons_masks.png'),
    );
  });
}
