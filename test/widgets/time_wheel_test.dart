import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  late AppServices s;
  late SettingsProvider settings;

  setUp(() async {
    s = await testServices();
    settings = await testSettings();
  });

  tearDown(() => s.db.close());

  Future<void> openQuiet(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, 'Nudges');
    await tester.tap(find.text('Quiet hours'));
    await tester.pumpAndSettle();
  }

  testWidgets('quiet hours open as two wheels, not the clock dial', (tester) async {
    await openQuiet(tester);
    expect(find.text('From'), findsOneWidget);
    expect(find.text('Until'), findsOneWidget);
    expect(find.byType(ListWheelScrollView), findsNWidgets(4));
    expect(find.byType(TimePickerDialog), findsNothing);
  });

  testWidgets('scrolling the From hour wheel moves the start', (tester) async {
    await openQuiet(tester);
    // The first wheel is the From hour, showing 22; one row up is 23.
    await tester.drag(find.byType(ListWheelScrollView).first, const Offset(0, -44));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(settings.quietStartMin, 23 * 60);
    expect(settings.quietEndMin, 7 * 60);
    expect(find.text('23:00 to 07:00'), findsOneWidget);
  });

  testWidgets('No quiet hours turns them off', (tester) async {
    await openQuiet(tester);
    await tester.tap(find.text('No quiet hours'));
    await tester.pumpAndSettle();
    expect((settings.quietStartMin, settings.quietEndMin), (0, 0));
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('the nudge rows are named for what they do, with help lines', (tester) async {
    await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, 'Nudges');
    expect(find.text('First nudge after'), findsOneWidget);
    expect(find.text('Nudge again after'), findsOneWidget);
    expect(find.text('15 min'), findsOneWidget);

    await tester.tap(find.text('Nudge again after'));
    await tester.pumpAndSettle();
    expect(find.text('Wait this long before nudging again'), findsOneWidget);
    expect(find.textContaining('Drift stays quiet this long'), findsOneWidget);
  });
}
