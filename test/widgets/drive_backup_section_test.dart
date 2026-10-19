import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/drive_backup_service.dart';
import 'package:drift_time/widgets/drive_backup_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

/// Every call the section makes, answered from fields: no prefs, no
/// isolates, no Google.
class FakeDriveBackupService extends DriveBackupService {
  FakeDriveBackupService({
    this.email,
    this.freq = 'daily',
    this.last,
    this.error,
    this.backup,
  });

  String? email;
  String freq;
  DateTime? last;
  String? error;
  CloudBackup? backup;
  int connects = 0;
  int disconnects = 0;
  int uploads = 0;
  final restored = <CloudBackup>[];

  @override
  Future<String?> connectedEmail() async => email;

  @override
  Future<String> getFrequency() async => freq;

  @override
  Future<void> setFrequency(String f) async => freq = f;

  @override
  Future<DateTime?> lastBackupAt() async => last;

  @override
  Future<String?> lastError() async => error;

  DriveAuthException? connectError;

  @override
  Future<String> connect() async {
    connects++;
    final refused = connectError;
    if (refused != null) throw refused;
    email = 'me@example.com';
    error = null;
    return email!;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    email = null;
    last = null;
    error = null;
  }

  @override
  Future<String> uploadNow(
    AppServices services,
    SettingsProvider settings, {
    bool interactive = false,
  }) async {
    uploads++;
    last = DateTime.now();
    return 'drift_backup_x.json.gz';
  }

  @override
  Future<CloudBackup> downloadLatest({bool interactive = false}) async =>
      backup!;

  @override
  Future<void> restore(
    CloudBackup backup,
    AppServices services,
    SettingsProvider settings,
  ) async => restored.add(backup);
}

void main() {
  late AppServices services;
  late SettingsProvider settings;

  setUp(() async {
    services = await testServices();
    settings = await testSettings();
  });

  tearDown(() => services.db.close());

  Future<void> pump(WidgetTester tester, DriveBackupService svc) async {
    await tester.pumpWidget(
      withApp(
        services,
        settings,
        Scaffold(
          body: ListView(children: [DriveBackupSection(service: svc)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('disconnected: one row to connect, nothing uploaded', (
    tester,
  ) async {
    final svc = FakeDriveBackupService();
    await pump(tester, svc);

    expect(find.text('Backup'), findsOneWidget);
    expect(find.text('Connect Google Drive'), findsOneWidget);
    expect(find.text('Off until connected. Nothing is uploaded.'), findsOneWidget);
    expect(find.text('Back up now'), findsNothing);
    expect(find.text('Restore from Drive'), findsNothing);

    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();
    expect(svc.connects, 1);
    expect(find.text('me@example.com'), findsOneWidget);
  });

  testWidgets('connected: account, back up, frequency, restore, disconnect', (
    tester,
  ) async {
    final svc = FakeDriveBackupService(
      email: 'me@example.com',
      last: DateTime.now(),
    );
    await pump(tester, svc);

    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Last backup: Just now'), findsOneWidget);
    expect(find.text('Automatic backup'), findsOneWidget);
    expect(find.text('Daily'), findsOneWidget);
    expect(find.text('Restore from Drive'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);

    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    expect(svc.uploads, 1);
    expect(find.text('Saved to Drive'), findsOneWidget);

    await tester.tap(find.text('Automatic backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    expect(svc.freq, 'weekly');
    expect(find.text('Weekly'), findsOneWidget);
  });

  testWidgets('restore asks first, naming the backup date', (tester) async {
    final backup = CloudBackup(
      data: const {'app': 'drift'},
      createdAt: DateTime(2026, 10, 18, 8),
      name: 'drift_backup_1.json.gz',
    );
    final svc = FakeDriveBackupService(email: 'me@example.com', backup: backup);
    await pump(tester, svc);

    await tester.tap(find.text('Restore from Drive'));
    await tester.pumpAndSettle();
    const question =
        'Replace everything on this phone with the backup from '
        "18 Oct 2026, 08:00? This can't be undone.";
    expect(find.text(question), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(svc.restored, isEmpty);

    await tester.tap(find.text('Restore from Drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(svc.restored, [backup]);
    expect(
      find.text('Restored the backup from 18 Oct 2026, 08:00'),
      findsOneWidget,
    );
  });

  testWidgets('disconnect asks first, then offers to connect again', (
    tester,
  ) async {
    final svc = FakeDriveBackupService(email: 'me@example.com');
    await pump(tester, svc);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect Google Drive?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(svc.disconnects, 1);
    expect(find.text('Connect Google Drive'), findsOneWidget);
  });

  testWidgets('a lost grant shows the banner with Reconnect', (tester) async {
    final svc = FakeDriveBackupService(
      email: 'me@example.com',
      error: kDriveReconnectMessage,
    );
    await pump(tester, svc);

    expect(find.text(kDriveReconnectMessage), findsOneWidget);
    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();
    expect(svc.connects, 1);
    expect(find.text(kDriveReconnectMessage), findsNothing);
  });

  testWidgets('a failed connect stays under the Connect row', (tester) async {
    final svc = FakeDriveBackupService()
      ..connectError = const DriveAuthException(
        "Google Drive access isn't set up for this build of the app.",
      );
    await pump(tester, svc);

    await tester.tap(find.text('Connect Google Drive'));
    await tester.pump();
    // The toast and the row both say it.
    expect(
      find.text("Google Drive access isn't set up for this build of the app."),
      findsNWidgets(2),
    );
    expect(find.text('Off until connected. Nothing is uploaded.'), findsNothing);
  });

  testWidgets('the real service loads without Google', (tester) async {
    await pump(tester, DriveBackupService());
    expect(find.text('Connect Google Drive'), findsOneWidget);
  });

  testWidgets('any other failure shows in the banner without Reconnect', (
    tester,
  ) async {
    final svc = FakeDriveBackupService(
      email: 'me@example.com',
      error: 'Quota exceeded',
    );
    await pump(tester, svc);

    expect(
      find.text('The last Drive backup failed: Quota exceeded'),
      findsOneWidget,
    );
    expect(find.text('Reconnect'), findsNothing);
  });
}
