import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/screens/settings_screen.dart';
import 'package:drift_time/services/csv_export.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_usage_source.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  late AppServices s;
  late FakeUsageSource usage;
  late SettingsProvider settings;

  setUp(() async {
    usage = FakeUsageSource();
    s = await testServices(usage: usage);
    settings = await testSettings();
  });

  tearDown(() => s.db.close());

  test('fields with commas, quotes or line breaks are quoted', () {
    expect(csvField('Notes'), 'Notes');
    expect(csvField('Mail, work'), '"Mail, work"');
    expect(csvField('Say "hi"'), '"Say ""hi"""');
    expect(csvField('a\nb'), '"a\nb"');
  });

  test('one row per classified slice, with stable verdict words', () async {
    await seedSampleDay(s, testNow);
    final csv = buildCsv([await loadDay(s, testNow)]);
    final lines = csv.trimRight().split('\r\n');
    expect(lines.first, csvHeader);
    expect(
      lines,
      contains('2026-10-19,10:15,10:24,9.0,WhatsApp,com.example.chat,Deep work,guessed_off_track'),
    );
    expect(lines, contains(startsWith('2026-10-19,09:40,10:05,25.0,Instagram,')));
    expect(lines.where((l) => l.endsWith(',outside_plan')), isEmpty,
        reason: 'the seeded day has no app use outside blocks');
  });

  test('export covers every day from the first session and names the file by time', () async {
    await seedSampleDay(s, DateTime(2026, 10, 17));
    await seedSampleDay(s, testNow);
    final loaded = <DateTime>[];
    final where = await exportAllCsv(s, (first, last) async {
      final days = await dayByDay(s)(first, last);
      loaded.addAll(days.map((d) => d.day));
      return days;
    });
    expect(loaded, [DateTime(2026, 10, 17), DateTime(2026, 10, 18), DateTime(2026, 10, 19)]);
    expect(where, 'Downloads/Drift/drift_20261019_1330.csv');
    expect(usage.savedCsv.keys.single, 'drift_20261019_1330.csv');
    expect(usage.savedCsv.values.single, contains('2026-10-17,'));
  });

  testWidgets('Settings exports and says where the file went', (tester) async {
    await seedSampleDay(s, testNow);
    await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, 'Backup and data');
    await tester.tap(find.text('Export to CSV'));
    await tester.pumpAndSettle();
    expect(find.text('Saved to Downloads/Drift/drift_20261019_1330.csv'), findsOneWidget);
  });

  testWidgets('a failed export says so', (tester) async {
    usage.saveFails = true;
    await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, 'Backup and data');
    await tester.tap(find.text('Export to CSV'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save the export. Try again."), findsOneWidget);
  });

  testWidgets('week start can be Sunday and survives a restart', (tester) async {
    await tester.pumpWidget(withApp(s, settings, const SettingsScreen()));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, 'Goals and week');
    await tester.tap(find.text('Week starts on'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sunday'));
    await tester.pumpAndSettle();
    expect(settings.firstWeekday, DateTime.sunday);
    final again = SettingsProvider();
    await again.load();
    expect(again.firstWeekday, DateTime.sunday);
  });
}
