import 'package:flutter/services.dart';

import 'usage_source.dart';

/// [UsageSource] over the `drift/usage` method channel (UsageBridge.kt).
///
/// A failed or missing native side gives the safe answer instead of an
/// error: no access, no events, no apps. Callers then show the setup step
/// or an empty state rather than crashing.
class ChannelUsageSource implements UsageSource {
  const ChannelUsageSource({
    this.channel = const MethodChannel('drift/usage'),
  });

  final MethodChannel channel;

  @override
  Future<bool> hasUsageAccess() async =>
      await _call<bool>('hasUsageAccess') ?? false;

  @override
  Future<void> openUsageAccessSettings() => _call<void>('openUsageAccessSettings');

  @override
  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _call<bool>('isIgnoringBatteryOptimizations') ?? false;

  @override
  Future<void> requestIgnoreBatteryOptimizations() =>
      _call<void>('requestIgnoreBatteryOptimizations');

  @override
  Future<List<Map<String, Object?>>> queryEvents({
    required int fromMs,
    required int toMs,
  }) async =>
      _maps(await _call<List<Object?>>('queryEvents', {
        'fromMs': fromMs,
        'toMs': toMs,
      }));

  @override
  Future<int?> earliestEventMs() => _call<int>('earliestEventMs');

  @override
  Future<List<Map<String, Object?>>> listApps() async =>
      _maps(await _call<List<Object?>>('listApps'));

  @override
  Future<List<int>?> appIcon(String package) =>
      _call<Uint8List>('appIcon', {'p': package});

  @override
  Future<List<String>> homePackages() async =>
      _strings(await _call<List<Object?>>('homePackages'));

  @override
  Future<List<String>> drainBuffer() async =>
      _strings(await _call<List<Object?>>('drainBuffer'));

  @override
  Future<void> deleteBuffer(List<String> paths) async {
    if (paths.isEmpty) return;
    await _call<void>('deleteBuffer', {'paths': paths});
  }

  @override
  Future<Map<String, Object?>> diagnostics() async {
    final raw = await _call<Map<Object?, Object?>>('diagnostics');
    return {
      'workerLastRunMs': raw?['workerLastRunMs'] as int?,
      'bufferFiles': raw?['bufferFiles'] as int? ?? 0,
      'bufferCursorMs': raw?['bufferCursorMs'] as int?,
      'backgroundLastRunMs': raw?['backgroundLastRunMs'] as int?,
      'backgroundLastOk': raw?['backgroundLastOk'] as bool?,
      'backgroundLastError': raw?['backgroundLastError'] as String?,
    };
  }

  /// Unlike the queries, a failed save must reach the user, so errors
  /// propagate instead of turning into a default.
  @override
  Future<String> saveCsv(String name, String text) async {
    final where = await channel.invokeMethod<String>('saveCsv', {
      'name': name,
      'text': text,
    });
    return where ?? name;
  }

  /// The channel result, or null when the native side failed or is absent
  /// (tests, a platform without the bridge).
  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The codec delivers maps as `Map<Object?, Object?>`; copy each to the
  /// typed shape so a bad cast fails here, not later in a caller.
  static List<Map<String, Object?>> _maps(List<Object?>? raw) => [
        for (final item in raw ?? const [])
          if (item is Map) Map<String, Object?>.from(item),
      ];

  static List<String> _strings(List<Object?>? raw) => [
        for (final item in raw ?? const [])
          if (item is String) item,
      ];
}
