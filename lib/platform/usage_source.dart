/// What Drift needs from Android about app usage. `ChannelUsageSource`
/// implements it over the `drift/usage` method channel; tests use fakes.
///
/// Kotlin passes raw facts only. Sessions, idle time and verdicts are
/// worked out in Dart (lib/domain).
abstract class UsageSource {
  Future<bool> hasUsageAccess();
  Future<void> openUsageAccessSettings();
  Future<bool> isIgnoringBatteryOptimizations();
  Future<void> requestIgnoreBatteryOptimizations();

  /// Raw usage events between [fromMs] and [toMs] (UTC milliseconds),
  /// oldest first. Each map is {"t": int, "p": String, "c": String?,
  /// "k": String} where k is one of [UsageEventKinds.all].
  Future<List<Map<String, Object?>>> queryEvents({
    required int fromMs,
    required int toMs,
  });

  /// Timestamp of the oldest event Android still holds within the last
  /// 10 days, or null when it holds none. Used to detect data gaps.
  Future<int?> earliestEventMs();

  /// Every launchable app: {"p": String, "label": String, "category": String}
  /// where category is one of [AppCategories.all].
  Future<List<Map<String, Object?>>> listApps();

  /// The app's launcher icon as a 96 px PNG, or null if unavailable.
  Future<List<int>?> appIcon(String package);

  /// Packages that answer the HOME intent (launchers). Their time is idle.
  Future<List<String>> homePackages();

  /// Absolute paths of hourly buffer files written by UsageBufferWorker.
  /// Each line is one event map in the [queryEvents] shape.
  Future<List<String>> drainBuffer();

  /// Deletes buffer files once their events are committed to the database.
  Future<void> deleteBuffer(List<String> paths);

  /// {"workerLastRunMs": int?, "bufferFiles": int, "bufferCursorMs": int?}
  Future<Map<String, Object?>> diagnostics();
}

/// The `k` values Kotlin sends, one per UsageEvents.Event type it keeps.
abstract final class UsageEventKinds {
  static const resumed = 'resumed';
  static const paused = 'paused';
  static const stopped = 'stopped';
  static const screenOn = 'screenOn';
  static const screenOff = 'screenOff';
  static const keyguardShown = 'keyguardShown';
  static const keyguardHidden = 'keyguardHidden';
  static const shutdown = 'shutdown';
  static const startup = 'startup';

  static const all = {
    resumed,
    paused,
    stopped,
    screenOn,
    screenOff,
    keyguardShown,
    keyguardHidden,
    shutdown,
    startup,
  };
}

/// The `category` values Kotlin sends, from ApplicationInfo.category.
abstract final class AppCategories {
  static const game = 'game';
  static const audio = 'audio';
  static const video = 'video';
  static const image = 'image';
  static const social = 'social';
  static const news = 'news';
  static const maps = 'maps';
  static const productivity = 'productivity';
  static const accessibility = 'accessibility';
  static const undefined = 'undefined';

  static const all = {
    game,
    audio,
    video,
    image,
    social,
    news,
    maps,
    productivity,
    accessibility,
    undefined,
  };
}
