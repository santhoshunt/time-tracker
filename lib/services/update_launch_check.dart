import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../providers/settings_provider.dart';
import 'update_service.dart';

/// True while a launch check is talking to GitHub, so a resume that lands
/// during a launch check does not start a second one.
bool _checking = false;

/// When a launch check last failed (offline, rate limited). In memory
/// only: a failure is retried after an hour, not on every resume.
DateTime? _failedAt;

/// The daily launch check for a newer release (Settings can switch it
/// off). Only reads GitHub; what it finds waits in [availableUpdate] for
/// the Today tab's update banner, and no further check runs while it is
/// there. Failures stay silent, since nobody asked.
///
/// The home shell calls this after the first frame and again on every
/// resume (Android keeps the process alive, so a launch is often a resume).
/// Pass `isAndroid: !kIsWeb && defaultTargetPlatform ==
/// TargetPlatform.android`; on anything else it returns at once. At
/// startup the shell also calls `UpdateDownloader().cleanup()`, so a
/// downloaded APK never outlives the launch after it.
///
/// Runs only when [SettingsProvider.updateOnLaunch] is on and a day or
/// more has passed since [SettingsProvider.updateLastCheck]
/// ([shouldCheckForUpdate]). A success (up to date or update found) is
/// recorded with [SettingsProvider.markUpdateChecked]; a failure is not,
/// and instead holds the next try back for an hour.
///
/// [service] and [now] are for tests.
Future<void> runLaunchUpdateCheck(
  SettingsProvider settings, {
  UpdateService? service,
  DateTime? now,
  bool isAndroid = true,
}) async {
  if (!isAndroid || _checking) return;
  if (availableUpdate.value != null) return;
  final at = now ?? DateTime.now();
  final failed = _failedAt;
  if (failed != null && at.difference(failed) < const Duration(hours: 1)) {
    return;
  }
  if (!shouldCheckForUpdate(
    enabled: settings.updateOnLaunch,
    lastCheck: settings.updateLastCheck,
    now: at,
  )) {
    return;
  }
  _checking = true;
  try {
    final result = await (service ?? UpdateService()).check();
    switch (result) {
      case UpdateAvailable(:final updates):
        availableUpdate.value = updates;
        await settings.markUpdateChecked(at);
      case UpToDate():
        await settings.markUpdateChecked(at);
      case CheckFailed():
        _failedAt = at;
    }
  } finally {
    _checking = false;
  }
}

/// Forgets the in-memory failure backoff and in-flight flag of
/// [runLaunchUpdateCheck], so each test starts clean.
@visibleForTesting
void resetLaunchUpdateCheck() {
  _checking = false;
  _failedAt = null;
}

/// First launch after an in-app update: the message that says it worked
/// and points to the switch that allowed it, which the app cannot turn off
/// itself. Null when there is nothing to say.
///
/// Reads [SettingsProvider.updateInstallingTag] (set by the update sheet
/// just before the install). With no tag it returns null. Otherwise it
/// clears the tag and returns the message only when the running version
/// equals the tag; a mismatch (the install failed or was abandoned) clears
/// the tag and returns null. When the running version cannot be read, the
/// tag is kept and null is returned, so the next launch tries again.
///
/// The home shell shows the message after the first frame, Android only,
/// with `showAppToastOn(messenger, message, tone: AppToastTone.success,
/// icon: Icons.system_update_alt, actionLabel: 'Settings', onAction:
/// ChannelUpdateInstaller.instance.openInstallSettings, duration: const
/// Duration(seconds: 10))`.
///
/// [currentVersion] is for tests; it defaults to the installed version
/// from package_info_plus.
Future<String?> takeUpdateResultMessage(
  SettingsProvider settings, {
  Future<String> Function()? currentVersion,
}) async {
  final tag = settings.updateInstallingTag;
  if (tag == null) return null;
  final String version;
  try {
    version = await (currentVersion ??
        () async => (await PackageInfo.fromPlatform()).version)();
  } catch (_) {
    return null;
  }
  await settings.setUpdateInstallingTag(null);
  if (UpdateService.compareVersions(version, tag) != 0) return null;
  return 'Updated to $tag. You can turn off Install unknown apps for Drift '
      'again.';
}
