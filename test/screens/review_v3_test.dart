import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/review_v3_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed_history.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices services;
  late SettingsProvider settings;

  setUp(() async {
    services = await testServices();
    settings = await testSettings();
  });

  tearDown(() => services.db.close());

  Future<void> pump(WidgetTester tester, {int firstWeekday = DateTime.monday}) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      withApp(services, settings, Scaffold(body: ReviewV3Screen(firstWeekday: firstWeekday))),
    );
    await tester.pumpAndSettle();
  }

  String label(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('review-period-label'))).data!;

  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(Tab, name));
    await tester.pumpAndSettle();
  }

  Future<void> swipe(WidgetTester tester, double dx) async {
    await tester.fling(find.byType(PageView), Offset(dx, 0), 1200);
    await tester.pumpAndSettle();
  }

  testWidgets('the tabs switch between the four views', (tester) async {
    await seedHistory(services);
    await pump(tester);

    expect(label(tester), 'Today');
    expect(find.text('Block by block'), findsOneWidget);
    expect(find.text('Top drift apps'), findsOneWidget);

    await openTab(tester, 'Week');
    expect(label(tester), '19 to 25 Oct');
    expect(find.text('Worst day'), findsOneWidget);
    expect(find.text('Drift total'), findsOneWidget);

    await openTab(tester, 'Month');
    expect(label(tester), 'October 2026');
    expect(find.text('Trend'), findsOneWidget);
    expect(find.textContaining('vs last month'), findsOneWidget);

    await openTab(tester, 'Year');
    expect(label(tester), '2026');
    expect(find.text('Best month'), findsOneWidget);
    expect(find.text('Worst month'), findsOneWidget);
    expect(find.text('Oct'), findsOneWidget);

    await openTab(tester, 'Day');
    expect(label(tester), 'Today');
  });

  testWidgets('swiping right goes back a week and the pill comes back', (tester) async {
    await seedHistory(services);
    await pump(tester);
    await openTab(tester, 'Week');
    expect(find.text('Back to this week'), findsNothing);

    await swipe(tester, 400);
    expect(label(tester), '12 to 18 Oct');
    expect(find.text('Back to this week'), findsOneWidget);
    expect(find.textContaining('vs last week'), findsOneWidget);

    await swipe(tester, 400);
    expect(label(tester), '5 to 11 Oct');

    await tester.tap(find.text('Back to this week'));
    await tester.pumpAndSettle();
    expect(label(tester), '19 to 25 Oct');
    expect(find.text('Back to this week'), findsNothing);
  });

  testWidgets('a week across a month edge has both month names', (tester) async {
    await seedHistory(services);
    await pump(tester);
    await openTab(tester, 'Week');
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
    }
    expect(label(tester), '28 Sep to 4 Oct');
  });

  testWidgets('forward never passes the current period', (tester) async {
    await seedHistory(services);
    await pump(tester);

    await swipe(tester, -400);
    expect(label(tester), 'Today');
    final next = tester.widget<IconButton>(
      find.ancestor(of: find.byIcon(Icons.chevron_right), matching: find.byType(IconButton)),
    );
    expect(next.onPressed, isNull);

    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();
    expect(label(tester), 'Sun 18 Oct');
    expect(find.text('Back to today'), findsOneWidget);

    await tester.tap(find.byTooltip('Next day'));
    await tester.pumpAndSettle();
    expect(label(tester), 'Today');
    expect(find.text('Back to today'), findsNothing);

    await openTab(tester, 'Month');
    await swipe(tester, -400);
    expect(label(tester), 'October 2026');
    await swipe(tester, 400);
    expect(label(tester), 'September 2026');
    expect(find.text('Back to this month'), findsOneWidget);
  });

  testWidgets('each tab keeps its own period', (tester) async {
    await seedHistory(services);
    await pump(tester);
    await openTab(tester, 'Month');
    await swipe(tester, 400);
    expect(label(tester), 'September 2026');

    await openTab(tester, 'Year');
    expect(label(tester), '2026');
    expect(find.text('Back to this year'), findsNothing);

    await openTab(tester, 'Month');
    expect(label(tester), 'September 2026');
  });

  testWidgets('tapping a month tile opens that month', (tester) async {
    await seedHistory(services);
    await pump(tester);
    await openTab(tester, 'Year');
    await tester.tap(find.bySemanticsLabel(RegExp('^September, ')));
    await tester.pumpAndSettle();
    expect(label(tester), 'September 2026');
    expect(find.text('Back to this month'), findsOneWidget);
  });

  testWidgets('a week can start on Sunday', (tester) async {
    await seedHistory(services);
    await pump(tester, firstWeekday: DateTime.sunday);
    await openTab(tester, 'Week');
    expect(label(tester), '18 to 24 Oct');
  });

  testWidgets('empty states when nothing is planned', (tester) async {
    await pump(tester);
    expect(find.text('Nothing planned today'), findsOneWidget);

    await openTab(tester, 'Week');
    expect(find.text('Nothing planned this week'), findsOneWidget);

    await openTab(tester, 'Month');
    expect(find.text('Nothing planned this month'), findsOneWidget);

    await openTab(tester, 'Year');
    expect(find.text('Nothing planned this year'), findsOneWidget);
  });

  testWidgets('a planned day before tracking began says there is no data', (tester) async {
    await seedHistory(services);
    await pump(tester);
    // Friday 4 September 2026 is planned, but history starts on the 7th.
    for (var i = 0; i < 45; i++) {
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pumpAndSettle();
    expect(label(tester), 'Fri 4 Sep');
    expect(find.text('No data for this day'), findsOneWidget);
  });

  testWidgets('reloads when the services revision changes', (tester) async {
    await pump(tester);
    expect(find.text('Nothing planned today'), findsOneWidget);

    await seedHistory(services);
    services.bump();
    await tester.pumpAndSettle();
    expect(find.text('Nothing planned today'), findsNothing);
    expect(find.text('Block by block'), findsOneWidget);
  });
}
