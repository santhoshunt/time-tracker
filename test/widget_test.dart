import 'package:drift_time/app.dart';
import 'package:drift_time/platform/background_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    expect(find.text('Learned rules'), findsOneWidget);
    await tester.runAsync(() => services.db.close());
  });

  testWidgets('a Today notification tap opens its tab', (tester) async {
    final nudges = FakeNudgeBridge()
      ..notifications = true
      ..overlay = true;
    final services = await tester.runAsync(() => testServices(nudges: nudges));
    final settings = await testSettings();
    await tester.pumpWidget(DriftApp(services: services!, settings: settings));
    await tester.pumpAndSettle();

    Future<void> tap(String payload) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        BackgroundBridge.instance.notify.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('launchPayload', payload)),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    int selected() => tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

    await tap('tab:usage');
    expect(selected(), 3);
    await tap('tab:today');
    expect(selected(), 0);
    await tap('something else');
    expect(selected(), 0);
    await tester.runAsync(() => services.db.close());
  });
}
