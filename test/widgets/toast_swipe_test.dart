import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/undo_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Toasts go away with a sideways swipe either way; Undo is still only a
/// button, so a swipe never undoes.
void main() {
  late int undos;

  Future<void> show(WidgetTester tester) async {
    undos = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDriftTheme(ThemeId.mono),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showAppToast(
                  context,
                  'Block saved',
                  tone: AppToastTone.change,
                  actionLabel: 'Undo',
                  onAction: () => undos++,
                  duration: const Duration(minutes: 1),
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.text('Block saved'), findsOneWidget);
  }

  for (final (name, offset) in [
    ('left', const Offset(-400, 0)),
    ('right', const Offset(400, 0)),
  ]) {
    testWidgets('a swipe $name dismisses without undoing', (tester) async {
      await show(tester);
      await tester.drag(find.text('Block saved'), offset);
      await tester.pumpAndSettle();
      expect(find.text('Block saved'), findsNothing);
      expect(undos, 0);
    });
  }

  testWidgets('a swipe down leaves the toast up', (tester) async {
    await show(tester);
    await tester.drag(find.text('Block saved'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Block saved'), findsOneWidget);
  });

  testWidgets('Undo still fires once and closes the toast', (tester) async {
    await show(tester);
    await tester.tap(find.text('Undo'));
    await tester.tap(find.text('Undo'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(undos, 1);
    expect(find.text('Block saved'), findsNothing);
  });
}
