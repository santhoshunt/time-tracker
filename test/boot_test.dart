import 'dart:async';

import 'package:drift_time/boot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('a screen is drawn before startup finishes', (tester) async {
    final gate = Completer<BootResult>();
    await tester.pumpWidget(
      BootApp(
        boot: (onStep) {
          onStep('Opening your data');
          return gate.future;
        },
      ),
    );
    await tester.pump();
    expect(find.text('Drift'), findsOneWidget);
    expect(find.text('Opening your data'), findsOneWidget);
  });

  testWidgets('a failing step shows the error, copies a report and retries', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    var attempts = 0;
    await tester.pumpWidget(
      BootApp(
        boot: (onStep) async {
          attempts++;
          onStep('Opening your data');
          throw StateError('database is locked');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Drift couldn't start"), findsOneWidget);
    expect(find.textContaining('while opening your data'), findsOneWidget);
    expect(find.textContaining('database is locked'), findsOneWidget);

    await tester.tap(find.text('Copy report'));
    await tester.pumpAndSettle();
    expect(copied.single, startsWith('Drift startup report\nstep: Opening your data\n'));
    expect(copied.single, contains('error: Bad state: database is locked'));

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  test('a stalled step becomes a timeout naming the step', () async {
    final step = BootStep(
      'Reading your settings',
      () => Completer<void>().future,
      limit: const Duration(milliseconds: 50),
    );
    await expectLater(
      step.run().timeout(step.limit, onTimeout: () => throw BootTimeout(step.label, step.limit)),
      throwsA(
        isA<BootTimeout>().having(
          (e) => e.toString(),
          'message',
          'Timed out after 0 s while reading your settings',
        ),
      ),
    );
  });

  testWidgets('a successful startup hands over to the app', (tester) async {
    final nudges = FakeNudgeBridge()
      ..notifications = true
      ..overlay = true;
    final services = await testServices(nudges: nudges);
    final settings = await testSettings();
    await tester.pumpWidget(
      BootApp(boot: (onStep) async => BootResult(services, settings)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Drift'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    await services.db.close();
  });
}
