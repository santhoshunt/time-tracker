import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/update_launch_check.dart';
import 'package:drift_time/services/update_service.dart';

ReleaseOption opt(String tag) => ReleaseOption(
  tag: tag,
  publishedAt: DateTime(2026, 10, 14),
  sizeBytes: 62 * 1024 * 1024,
  notes: '',
  downloadUrl: UpdateService.assetUrlFor(tag),
);

/// Answers every check with [result] and counts the calls.
class _FakeService extends UpdateService {
  UpdateCheckResult result;
  int calls = 0;
  _FakeService(this.result);

  @override
  Future<UpdateCheckResult> check() async {
    calls++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 19, 9);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    availableUpdate.value = null;
    resetLaunchUpdateCheck();
  });

  Future<SettingsProvider> settingsWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final settings = SettingsProvider();
    await settings.load();
    return settings;
  }

  group('runLaunchUpdateCheck', () {
    test('an update found is published and the check recorded', () async {
      final settings = await settingsWith({});
      final updates = UpdateList('0.1.0', [opt('v0.2.0')]);
      final service = _FakeService(UpdateAvailable(updates));
      await runLaunchUpdateCheck(settings, service: service, now: now);
      expect(service.calls, 1);
      expect(availableUpdate.value, same(updates));
      expect(settings.updateLastCheck, now);
    });

    test('up to date records the check and publishes nothing', () async {
      final settings = await settingsWith({});
      final service = _FakeService(const UpToDate('0.1.0'));
      await runLaunchUpdateCheck(settings, service: service, now: now);
      expect(service.calls, 1);
      expect(availableUpdate.value, isNull);
      expect(settings.updateLastCheck, now);
    });

    test('switched off, it never asks GitHub', () async {
      final settings = await settingsWith({'update_check_on_launch_v1': false});
      final service = _FakeService(const UpToDate('0.1.0'));
      await runLaunchUpdateCheck(settings, service: service, now: now);
      expect(service.calls, 0);
    });

    test('within a day of the last check, it waits', () async {
      final settings = await settingsWith({
        'update_last_check_v1': now
            .subtract(const Duration(hours: 23))
            .millisecondsSinceEpoch,
      });
      final service = _FakeService(const UpToDate('0.1.0'));
      await runLaunchUpdateCheck(settings, service: service, now: now);
      expect(service.calls, 0);

      await runLaunchUpdateCheck(
        settings,
        service: service,
        now: now.add(const Duration(hours: 1)),
      );
      expect(service.calls, 1, reason: 'a day has passed');
    });

    test('off Android it never asks GitHub', () async {
      final settings = await settingsWith({});
      final service = _FakeService(const UpToDate('0.1.0'));
      await runLaunchUpdateCheck(
        settings,
        service: service,
        now: now,
        isAndroid: false,
      );
      expect(service.calls, 0);
    });

    test('an update already waiting stops further checks', () async {
      final settings = await settingsWith({});
      availableUpdate.value = UpdateList('0.1.0', [opt('v0.2.0')]);
      final service = _FakeService(const UpToDate('0.1.0'));
      await runLaunchUpdateCheck(settings, service: service, now: now);
      expect(service.calls, 0);
    });

    test('a failure is not recorded and holds the next try back an hour', () async {
      final settings = await settingsWith({});
      final service = _FakeService(const CheckFailed('offline'));
      await runLaunchUpdateCheck(settings, service: service, now: now);
      expect(service.calls, 1);
      expect(settings.updateLastCheck, isNull);

      await runLaunchUpdateCheck(
        settings,
        service: service,
        now: now.add(const Duration(minutes: 30)),
      );
      expect(service.calls, 1, reason: 'inside the hour');

      service.result = const UpToDate('0.1.0');
      final later = now.add(const Duration(minutes: 61));
      await runLaunchUpdateCheck(settings, service: service, now: later);
      expect(service.calls, 2, reason: 'the hour is up');
      expect(settings.updateLastCheck, later);
    });
  });

  group('takeUpdateResultMessage', () {
    test('the running version matches the tag: says so, clears it', () async {
      final settings = await settingsWith({
        'update_installing_tag_v1': 'v0.2.0',
      });
      final message = await takeUpdateResultMessage(
        settings,
        currentVersion: () async => '0.2.0',
      );
      expect(
        message,
        'Updated to v0.2.0. You can turn off Install unknown apps for Drift '
        'again.',
      );
      expect(settings.updateInstallingTag, isNull, reason: 'said once');
    });

    test('a different version: nothing to say, the tag is cleared', () async {
      final settings = await settingsWith({
        'update_installing_tag_v1': 'v0.2.0',
      });
      final message = await takeUpdateResultMessage(
        settings,
        currentVersion: () async => '0.1.0',
      );
      expect(message, isNull);
      expect(settings.updateInstallingTag, isNull);
    });

    test('no tag: nothing to say, the version is not read', () async {
      final settings = await settingsWith({});
      var read = false;
      final message = await takeUpdateResultMessage(
        settings,
        currentVersion: () async {
          read = true;
          return '0.2.0';
        },
      );
      expect(message, isNull);
      expect(read, isFalse);
    });

    test('an unreadable version keeps the tag for the next launch', () async {
      final settings = await settingsWith({
        'update_installing_tag_v1': 'v0.2.0',
      });
      final message = await takeUpdateResultMessage(
        settings,
        currentVersion: () async => throw StateError('no platform'),
      );
      expect(message, isNull);
      expect(settings.updateInstallingTag, 'v0.2.0');
    });
  });
}
