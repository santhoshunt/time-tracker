import 'package:drift_time/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_usage_source.dart';
import 'helpers/test_app.dart';

void main() {
  testWidgets('setup pages show while usage access is off', (tester) async {
    final usage = FakeUsageSource(usageAccess: false);
    final services = await tester.runAsync(() => testServices(usage: usage));
    final settings = await testSettings();
    await tester.pumpWidget(DriftApp(services: services!, settings: settings));
    await tester.pumpAndSettle();

    expect(find.text('See which app is open'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('Open settings'));
    expect(usage.openUsageSettingsCalls, 1);
  });

  testWidgets('the tabs show once every permission is granted', (tester) async {
    final nudges = FakeNudgeBridge()
      ..notifications = true
      ..overlay = true;
    final services = await tester.runAsync(() => testServices(nudges: nudges));
    final settings = await testSettings();
    await tester.pumpWidget(DriftApp(services: services!, settings: settings));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Nothing planned yet'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(find.text('Live nudges'), findsOneWidget);
    await tester.runAsync(() => services.db.close());
  });
}
