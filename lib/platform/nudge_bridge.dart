/// What Drift needs from Android for live nudges.
/// `ChannelNudgeBridge` implements it over the `drift/nudge` method
/// channel (NudgeBridge.kt); tests use fakes.
///
/// The service itself only reads the snapshot file Dart writes
/// (nudge_snapshot.json in the app's files folder) and asks
/// NudgeDecider.kt whether to nudge, so all plan logic stays in Dart.
abstract class NudgeBridge {
  /// "Display over other apps" (Settings.canDrawOverlays).
  Future<bool> canDrawOverlays();

  /// Opens the "Display over other apps" page for Drift.
  Future<void> openOverlaySettings();

  /// POST_NOTIFICATIONS on Android 13 and later; true below that.
  Future<bool> hasNotificationPermission();

  /// Shows the system notification dialog; returns whether it was granted.
  Future<bool> requestNotificationPermission();

  /// Starts the foreground service and remembers that it should run, so
  /// it restarts after a reboot or an app update.
  Future<void> startService();

  /// Stops the service and forgets it should run.
  Future<void> stopService();

  /// {"running": bool, "lastTickMs": int?, "lastNudgeMs": int?,
  ///  "lastError": String?}
  Future<Map<String, Object?>> serviceStatus();
}

/// Answers "not granted" and does nothing: for tests that don't care
/// about nudges and for platforms without the service.
class DisabledNudgeBridge implements NudgeBridge {
  const DisabledNudgeBridge();

  @override
  Future<bool> canDrawOverlays() async => false;

  @override
  Future<void> openOverlaySettings() async {}

  @override
  Future<bool> hasNotificationPermission() async => false;

  @override
  Future<bool> requestNotificationPermission() async => false;

  @override
  Future<void> startService() async {}

  @override
  Future<void> stopService() async {}

  @override
  Future<Map<String, Object?>> serviceStatus() async => const {'running': false};
}
