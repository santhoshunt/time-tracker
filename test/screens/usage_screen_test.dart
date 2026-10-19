import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/app_usage_screen.dart';
import 'package:drift_time/screens/usage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices s;
  late SettingsProvider settings;

  setUp(() async {
    s = await testServices();
    settings = await testSettings();
  });

  tearDown(() => s.db.close());

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(withApp(s, settings, const Scaffold(body: UsageScreen())));
    await tester.pumpAndSettle();
  }

  String label(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('usage-period-label'))).data!;

  testWidgets('the ring total and one row per category, largest first', (tester) async {
    await seedSampleDay(s, testNow);
    await pump(tester);
    expect(label(tester), 'Today');
    expect(find.text('3 h 49 min'), findsOneWidget);
    expect(find.text('on apps'), findsOneWidget);
    final rows = ['Productivity', 'Video', 'Music and audio', 'Social'];
    final ys = [for (final r in rows) tester.getTopLeft(find.text(r)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('1 h 30 min'), findsOneWidget);
    expect(find.text('39%'), findsOneWidget);
    // Apps stay folded until their category is opened.
    expect(find.text('Notes'), findsNothing);
  });

  testWidgets('a category opens its apps, and an app opens its page', (tester) async {
    await seedSampleDay(s, testNow);
    await pump(tester);
    await tester.tap(find.text('Productivity'));
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('1 h 10 min'), findsOneWidget);
    expect(find.text('Zoom'), findsOneWidget);

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUsageScreen), findsOneWidget);
    expect(find.text('Productivity, 1 h 10 min today'), findsOneWidget);
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('When today'), findsOneWidget);
    expect(find.text('Deep work'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Productivity'));
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsNothing);
  });

  testWidgets('periods step back but never past now', (tester) async {
    await seedSampleDay(s, testNow);
    await pump(tester);
    final next = find.byTooltip('Next day');
    expect(tester.widget<IconButton>(find.ancestor(of: next, matching: find.byType(IconButton)).first).onPressed, isNull);
    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();
    expect(label(tester), 'Sun 18 Oct');
    expect(find.text('No app use yet'), findsOneWidget);

    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    expect(label(tester), '19 to 25 Oct');
    expect(find.text('3 h 49 min'), findsOneWidget);
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(label(tester), 'October 2026');
  });

  testWidgets('new usage shows without leaving the tab', (tester) async {
    await pump(tester);
    expect(find.text('No app use yet'), findsOneWidget);
    await seedSampleDay(s, testNow);
    s.bump();
    await tester.pumpAndSettle();
    expect(find.text('3 h 49 min'), findsOneWidget);
  });
}
