import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift_time/app_services.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/backup_codec.dart';
import 'package:drift_time/services/drive_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

/// Google, faked: [silent] is handed out in order (the last one repeats),
/// [interactive] answers a connect, or [interactiveError] refuses it.
/// [onSilent] runs before each silent answer, to act between the
/// snapshot and the network.
class FakeDriveAuth implements DriveAuth {
  FakeDriveAuth({
    this.silent = const [null],
    this.interactive = 'tok-interactive',
    this.interactiveError,
    this.onSilent,
  });

  List<String?> silent;
  String interactive;
  DriveAuthException? interactiveError;
  Future<void> Function()? onSilent;
  int silentCalls = 0;
  int interactiveCalls = 0;
  int signOuts = 0;
  final forgotten = <String>[];
  final silentEmails = <String?>[];
  final interactiveEmails = <String?>[];

  @override
  Future<String?> silentToken(List<String> scopes, {String? email}) async {
    silentCalls++;
    silentEmails.add(email);
    await onSilent?.call();
    if (silent.length > 1) {
      final next = silent.first;
      silent = silent.sublist(1);
      return next;
    }
    return silent.single;
  }

  @override
  Future<String> interactiveToken(List<String> scopes, {String? email}) async {
    interactiveCalls++;
    interactiveEmails.add(email);
    final error = interactiveError;
    if (error != null) throw error;
    return interactive;
  }

  @override
  Future<void> forget(String accessToken) async => forgotten.add(accessToken);

  @override
  Future<void> signOut() async => signOuts++;
}

/// One file in the fake backups folder.
class FakeFile {
  FakeFile(this.id, this.name, this.createdTime, this.bytes);

  final String id;
  final String name;
  final DateTime createdTime;
  final List<int> bytes;
}

/// Drive v3, faked: about, folder lookup, file listing, download and
/// upload. The first [uploads401] uploads answer 401, as for an expired
/// token. [backups] are listed newest first.
class FakeDrive {
  FakeDrive({
    this.email = 'me@example.com',
    this.uploads401 = 0,
    this.offline = false,
    List<FakeFile>? backups,
  }) : backups = backups ?? [];

  final String email;
  int uploads401;

  /// When set, every request fails as if offline.
  bool offline;
  final List<FakeFile> backups;
  final requests = <http.Request>[];

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (offline) throw const SocketException('offline');
    final path = request.url.path;
    if (path.endsWith('/drive/v3/about')) {
      return _json({
        'user': {'emailAddress': email},
      });
    }
    if (path.endsWith('/upload/drive/v3/files')) {
      if (uploads401 > 0) {
        uploads401--;
        // As Google answers a bad token: the header makes googleapis_auth
        // throw AccessDeniedException before googleapis parses the body.
        return http.Response(
          jsonEncode({
            'error': {'code': 401, 'message': 'Invalid Credentials'},
          }),
          401,
          headers: {
            'content-type': 'application/json',
            'www-authenticate':
                'Bearer realm="https://accounts.google.com/", '
                'error="invalid_token"',
          },
        );
      }
      return _json({'id': 'file1', 'name': 'backup'});
    }
    if (path.endsWith('/drive/v3/files') && request.method == 'GET') {
      final q = request.url.queryParameters['q'] ?? '';
      if (q.contains('google-apps.folder')) {
        return _json({
          'files': [
            {'id': 'folder1'},
          ],
        });
      }
      return _json({
        'files': [
          for (final f in backups)
            {
              'id': f.id,
              'name': f.name,
              'createdTime': f.createdTime.toUtc().toIso8601String(),
            },
        ],
      });
    }
    if (path.contains('/drive/v3/files/')) {
      final id = request.url.pathSegments.last;
      if (request.url.queryParameters['alt'] == 'media') {
        final f = backups.firstWhere((f) => f.id == id);
        return http.Response.bytes(
          f.bytes,
          200,
          headers: {'content-type': 'application/gzip'},
        );
      }
      return _json({'id': id, 'trashed': false});
    }
    return _json({'id': 'folder1'});
  });

  List<String?> get authHeaders => [
    for (final r in requests) r.headers['authorization'],
  ];

  Iterable<http.Request> get uploads =>
      requests.where((r) => r.url.path.endsWith('/upload/drive/v3/files'));

  /// The backup inside the last successful multipart upload.
  Map<String, dynamic> lastUploadedPayload() {
    final body = uploads.last.body;
    const marker = 'Content-Transfer-Encoding: base64\r\n\r\n';
    final start = body.indexOf(marker) + marker.length;
    final end = body.indexOf('\r\n--', start);
    return decodeBackupGz(
      Uint8List.fromList(base64.decode(body.substring(start, end))),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isDue', () {
    final now = DateTime(2026, 8, 10, 9);

    test('never backed up is due', () {
      expect(DriveBackupService.isDue(null, 'daily', now), isTrue);
    });

    test('a last backup in the future (clock moved back) is due', () {
      expect(
        DriveBackupService.isDue(
          now.add(const Duration(days: 2)),
          'daily',
          now,
        ),
        isTrue,
      );
    });

    test('daily: due after 23 h, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(hours: 23)),
          'daily',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(hours: 22)),
          'daily',
          now,
        ),
        isFalse,
      );
    });

    test('weekly: due after 6 days, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 6)),
          'weekly',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 5)),
          'weekly',
          now,
        ),
        isFalse,
      );
    });

    test('off is never due', () {
      expect(DriveBackupService.isDue(null, 'off', now), isFalse);
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 60)),
          'off',
          now,
        ),
        isFalse,
      );
    });

    test('an unknown frequency falls back to daily', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 1)),
          'bogus',
          now,
        ),
        isTrue,
      );
    });
  });

  group('Drive access (google_sign_in 7)', () {
    AppServices? opened;
    late AppServices services;
    late SettingsProvider settings;

    /// An in-memory database stays shared until closed, so each phone
    /// closes the one before it.
    Future<void> freshServices() async {
      if (opened?.db.isOpen ?? false) await opened!.db.close();
      services = opened = await testServices();
    }

    tearDown(() async {
      if (opened?.db.isOpen ?? false) await opened!.db.close();
      opened = null;
    });

    /// Settings first: testSettings resets the mock prefs, so the drive_
    /// keys go in after it.
    Future<void> setUpWith(Map<String, Object> drivePrefs) async {
      settings = await testSettings();
      final prefs = await SharedPreferences.getInstance();
      for (final MapEntry(:key, :value) in drivePrefs.entries) {
        await prefs.setString(key, value as String);
      }
      await freshServices();
      await seedSampleDay(services, testNow);
    }

    const connected = {DriveBackupService.emailKey: 'me@example.com'};

    DriveBackupService service(FakeDriveAuth auth, FakeDrive drive) =>
        DriveBackupService(auth: auth, httpClient: () => drive.client);

    test('connect names the account from Drive and remembers it', () async {
      await setUpWith({});
      final auth = FakeDriveAuth();
      final drive = FakeDrive();
      final svc = service(auth, drive);
      expect(await svc.connectedEmail(), isNull, reason: 'never connected');
      expect(auth.silentCalls, 0, reason: 'nothing asked of Google');

      expect(await svc.connect(), 'me@example.com');
      expect(await svc.connectedEmail(), 'me@example.com');
      expect(await svc.lastError(), isNull);
      expect(drive.authHeaders.single, 'Bearer tok-interactive');
    });

    test('a cancelled connect stores nothing', () async {
      await setUpWith({});
      final auth = FakeDriveAuth(
        interactiveError: const DriveAuthException('cancelled'),
      );
      final svc = service(auth, FakeDrive());
      await expectLater(svc.connect(), throwsA(isA<DriveAuthException>()));
      expect(await svc.connectedEmail(), isNull);
    });

    test('connect while offline asks to check the connection', () async {
      await setUpWith({});
      final svc = service(FakeDriveAuth(), FakeDrive(offline: true));
      await expectLater(
        svc.connect(),
        throwsA(
          isA<DriveAuthException>().having(
            (e) => e.message,
            'message',
            contains('Check the connection'),
          ),
        ),
      );
      expect(await svc.connectedEmail(), isNull);
    });

    test('a scheduled backup without a token records the reconnect message '
        'and shows no UI', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth();
      final drive = FakeDrive();
      await service(auth, drive).checkAndRunScheduled(services, settings);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(DriveBackupService.lastErrorKey),
        kDriveReconnectMessage,
      );
      expect(auth.interactiveCalls, 0);
      expect(drive.requests, isEmpty);
    });

    test('an upload goes to the backups folder as multipart', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth(silent: ['tok-1']);
      final drive = FakeDrive();
      final name = await service(auth, drive).uploadNow(services, settings);
      expect(name, startsWith('drift_backup_'));
      expect(name, endsWith('.json.gz'));
      final upload = drive.uploads.single;
      expect(upload.method, 'POST');
      expect(upload.url.queryParameters['uploadType'], 'multipart');
      expect(upload.body, contains('"parents":["folder1"]'));
      expect(upload.headers['authorization'], 'Bearer tok-1');
      final payload = drive.lastUploadedPayload();
      expect(payload['app'], 'drift');
      expect((payload['tables'] as Map)['blocks'], hasLength(5));
    });

    test('the snapshot is taken before any network call', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth(silent: ['tok-1']);
      // Wipes the plan once the upload is waiting on Google.
      auth.onSilent = () async {
        await services.db.delete('blocks');
      };
      final drive = FakeDrive();
      await service(auth, drive).uploadNow(services, settings);
      expect((drive.lastUploadedPayload()['tables'] as Map)['blocks'], hasLength(5));
    });

    test('a rejected token is dropped and the upload retried once', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth(silent: ['tok-stale', 'tok-fresh']);
      final drive = FakeDrive(uploads401: 1);
      final svc = service(auth, drive);
      await svc.uploadNow(services, settings);
      expect(auth.forgotten, ['tok-stale']);
      expect(drive.authHeaders.last, 'Bearer tok-fresh');
      expect(await svc.lastBackupAt(), isNotNull);
    });

    test('an offline tap says to check the connection, records nothing', () async {
      await setUpWith(connected);
      final svc = service(
        FakeDriveAuth(silent: ['tok-1']),
        FakeDrive(offline: true),
      );
      await expectLater(
        svc.uploadNow(services, settings, interactive: true),
        throwsA(isA<DriveOfflineException>()),
      );
      expect(await svc.lastError(), isNull);
      await expectLater(
        svc.downloadLatest(interactive: true),
        throwsA(isA<DriveOfflineException>()),
      );
    });

    test('a second rejection fails the upload and is recorded', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth(silent: ['tok-1', 'tok-2']);
      final svc = service(auth, FakeDrive(uploads401: 2));
      await expectLater(svc.uploadNow(services, settings), throwsA(anything));
      expect(await svc.lastError(), isNotNull);
    });

    test('every silent request names the connected account', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth(silent: ['tok-1']);
      await service(auth, FakeDrive()).uploadNow(services, settings);
      expect(auth.silentEmails, everyElement('me@example.com'));
    });

    test('a tap asks for access again when it was lost, for the same '
        'account', () async {
      await setUpWith(connected);
      final auth = FakeDriveAuth(interactive: 'tok-again');
      final drive = FakeDrive();
      await service(
        auth,
        drive,
      ).uploadNow(services, settings, interactive: true);
      expect(auth.interactiveEmails, ['me@example.com']);
      expect(drive.authHeaders.last, 'Bearer tok-again');
    });

    test('keeps the newest 7 backups and deletes the rest', () async {
      await setUpWith(connected);
      final drive = FakeDrive(
        backups: [
          for (var i = 0; i < 9; i++)
            FakeFile(
              'b$i',
              'drift_backup_$i.json.gz',
              DateTime(2026, 10, 19 - i),
              const [],
            ),
        ],
      );
      await service(
        FakeDriveAuth(silent: ['tok-1']),
        drive,
      ).uploadNow(services, settings);
      final deleted = [
        for (final r in drive.requests)
          if (r.method == 'DELETE') r.url.pathSegments.last,
      ];
      expect(deleted, ['b7', 'b8']);
    });

    test('disconnect forgets the token and the account-scoped state', () async {
      await setUpWith({});
      final auth = FakeDriveAuth(silent: ['tok-1']);
      final svc = service(auth, FakeDrive());
      await svc.connect();
      await svc.uploadNow(services, settings);
      await svc.disconnect();
      expect(auth.forgotten, ['tok-1']);
      expect(auth.signOuts, 1);
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        DriveBackupService.emailKey,
        DriveBackupService.folderIdKey,
        DriveBackupService.lastKey,
        DriveBackupService.lastErrorKey,
        DriveBackupService.connectedAtKey,
      ]) {
        expect(prefs.getString(key), isNull, reason: key);
      }
      expect(await svc.connectedEmail(), isNull);
    });

    group('scheduled check', () {
      String ago(Duration d) => DateTime.now().subtract(d).toIso8601String();

      test('uploads when a day has passed', () async {
        await setUpWith({
          ...connected,
          DriveBackupService.lastKey: ago(const Duration(hours: 30)),
        });
        final drive = FakeDrive();
        await service(
          FakeDriveAuth(silent: ['tok-1']),
          drive,
        ).checkAndRunScheduled(services, settings);
        expect(drive.uploads, hasLength(1));
      });

      test('waits a day after connecting before the first backup', () async {
        await setUpWith({
          ...connected,
          DriveBackupService.connectedAtKey: ago(const Duration(minutes: 5)),
        });
        final drive = FakeDrive();
        await service(
          FakeDriveAuth(silent: ['tok-1']),
          drive,
        ).checkAndRunScheduled(services, settings);
        expect(drive.requests, isEmpty);

        await setUpWith({
          ...connected,
          DriveBackupService.connectedAtKey: ago(const Duration(hours: 24)),
        });
        final later = FakeDrive();
        await service(
          FakeDriveAuth(silent: ['tok-1']),
          later,
        ).checkAndRunScheduled(services, settings);
        expect(later.uploads, hasLength(1));
      });

      test('offline leaves no error behind', () async {
        await setUpWith(connected);
        final svc = service(
          FakeDriveAuth(silent: ['tok-1']),
          FakeDrive(offline: true),
        );
        await svc.checkAndRunScheduled(services, settings);
        expect(await svc.lastError(), isNull);
        expect(await svc.lastBackupAt(), isNull);
      });

      test('does nothing when off', () async {
        await setUpWith({
          ...connected,
          DriveBackupService.freqKey: 'off',
        });
        final drive = FakeDrive();
        await service(
          FakeDriveAuth(silent: ['tok-1']),
          drive,
        ).checkAndRunScheduled(services, settings);
        expect(drive.requests, isEmpty);
      });

      test('never uploads an empty database', () async {
        await setUpWith(connected);
        await freshServices();
        final drive = FakeDrive();
        await service(
          FakeDriveAuth(silent: ['tok-1']),
          drive,
        ).checkAndRunScheduled(services, settings);
        expect(drive.requests, isEmpty);
      });

      test('does nothing when not connected', () async {
        await setUpWith({});
        final auth = FakeDriveAuth(silent: ['tok-1']);
        final drive = FakeDrive();
        await service(auth, drive).checkAndRunScheduled(services, settings);
        expect(auth.silentCalls, 0);
        expect(drive.requests, isEmpty);
      });
    });

    group('download', () {
      test('returns the newest backup with its date', () async {
        await setUpWith(connected);
        final bytes = encodeBackupGz(await exportAll(services, settings));
        final created = DateTime(2026, 10, 18, 8);
        final drive = FakeDrive(
          backups: [FakeFile('b1', 'drift_backup_1.json.gz', created, bytes)],
        );
        final backup = await service(
          FakeDriveAuth(silent: ['tok-1']),
          drive,
        ).downloadLatest();
        expect(backup.data['app'], 'drift');
        expect(backup.createdAt, created);
        expect(backup.name, 'drift_backup_1.json.gz');
      });

      test('skips a corrupt newest file for the next one', () async {
        await setUpWith(connected);
        final bytes = encodeBackupGz(await exportAll(services, settings));
        final drive = FakeDrive(
          backups: [
            FakeFile('bad', 'drift_backup_2.json.gz', DateTime(2026, 10, 19), [1, 2, 3]),
            FakeFile('good', 'drift_backup_1.json.gz', DateTime(2026, 10, 18), bytes),
          ],
        );
        final backup = await service(
          FakeDriveAuth(silent: ['tok-1']),
          drive,
        ).downloadLatest();
        expect(backup.name, 'drift_backup_1.json.gz');
      });

      test('an empty folder says no backup was found', () async {
        await setUpWith(connected);
        await expectLater(
          service(FakeDriveAuth(silent: ['tok-1']), FakeDrive()).downloadLatest(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('No backup found in "Drift Backups"'),
            ),
          ),
        );
      });
    });
  });

  group('Android authorization errors', () {
    String message(GoogleSignInExceptionCode code, [String? description]) =>
        GoogleDriveAuth.mapped(
          GoogleSignInException(code: code, description: description),
        ).message;

    test('a cancel reads as cancelled, however Android reports it', () {
      expect(message(GoogleSignInExceptionCode.canceled), contains('cancelled'));
      expect(
        message(
          GoogleSignInExceptionCode.unknownError,
          'SDK reported an exception: 16: Cancelled by user.',
        ),
        contains('cancelled'),
      );
    });

    test('status 10 (package or SHA-1 mismatch) reads as not set up', () {
      expect(
        message(
          GoogleSignInExceptionCode.unknownError,
          'SDK reported an exception: 10: ',
        ),
        "Google Drive access isn't set up for this build of the app.",
      );
      expect(
        message(GoogleSignInExceptionCode.clientConfigurationError),
        contains("isn't set up"),
      );
    });

    test('anything else asks to try again', () {
      expect(
        message(GoogleSignInExceptionCode.unknownError, 'Authorization failed'),
        contains('Try again'),
      );
    });
  });

  group('uploadNow race hardening', () {
    late AppServices services;
    late SettingsProvider settings;

    setUp(() async {
      settings = await testSettings();
      services = await testServices();
    });

    tearDown(() => services.db.close());

    test('a second uploadNow joins the in-flight one', () async {
      final svc = DriveBackupService(auth: FakeDriveAuth());
      final f1 = svc.uploadNow(services, settings);
      final f2 = svc.uploadNow(services, settings);
      expect(identical(f1, f2), isTrue);
      await expectLater(f1, throwsA(anything));
      // Once finished the slot is free again: a new call runs fresh.
      final f3 = svc.uploadNow(services, settings);
      expect(identical(f1, f3), isFalse);
      await expectLater(f3, throwsA(anything));
    });

    test('a failed upload records drive_last_error_v1', () async {
      final svc = DriveBackupService(auth: FakeDriveAuth());
      await expectLater(svc.uploadNow(services, settings), throwsA(anything));
      expect(await svc.lastError(), kDriveReconnectMessage);
    });
  });

  group('names and labels', () {
    test('the file name is prefixed, sortable and tagged', () {
      final name = DriveBackupService.backupFileName(
        DateTime(2026, 8, 10, 9, 5, 3),
      );
      expect(name, 'drift_backup_2026-08-10T09-05-03.json.gz');
      final later = DriveBackupService.backupFileName(DateTime(2026, 8, 11, 8));
      expect(name.compareTo(later), lessThan(0));
    });

    test('last backup reads as a relative time, then a date', () {
      final now = DateTime(2026, 10, 19, 12);
      String f(Duration d) =>
          DriveBackupService.formatLastBackup(now.subtract(d), now: now);
      expect(DriveBackupService.formatLastBackup(null), 'Never');
      expect(f(const Duration(minutes: 1)), 'Just now');
      expect(f(const Duration(minutes: 12)), '12 min ago');
      expect(f(const Duration(hours: 3)), '3 h ago');
      expect(f(const Duration(days: 2)), '17 Oct 2026');
    });
  });
}
