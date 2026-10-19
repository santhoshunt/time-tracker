import 'package:flutter/services.dart';

import 'nudge_bridge.dart';

/// [NudgeBridge] over the `drift/nudge` method channel (NudgeBridge.kt).
///
/// A failed or missing native side gives the safe answer instead of an
/// error: no permission, nothing started, the service not running. The
/// settings screen then shows the setup step rather than crashing.
class ChannelNudgeBridge implements NudgeBridge {
  const ChannelNudgeBridge({
    this.channel = const MethodChannel('drift/nudge'),
  });

  final MethodChannel channel;

  @override
  Future<bool> canDrawOverlays() async =>
      await _call<bool>('canDrawOverlays') ?? false;

  @override
  Future<void> openOverlaySettings() => _call<void>('openOverlaySettings');

  @override
  Future<bool> hasNotificationPermission() async =>
      await _call<bool>('hasNotificationPermission') ?? false;

  @override
  Future<bool> requestNotificationPermission() async =>
      await _call<bool>('requestNotificationPermission') ?? false;

  @override
  Future<void> startService() => _call<void>('startService');

  @override
  Future<void> stopService() => _call<void>('stopService');

  @override
  Future<Map<String, Object?>> serviceStatus() async {
    final raw = await _call<Map<Object?, Object?>>('serviceStatus');
    if (raw == null) return {'running': false};
    return {
      'running': raw['running'] as bool? ?? false,
      'lastTickMs': raw['lastTickMs'] as int?,
      'lastNudgeMs': raw['lastNudgeMs'] as int?,
      'lastError': raw['lastError'] as String?,
    };
  }

  /// The channel result, or null when the native side failed or is absent
  /// (tests, a platform without the bridge).
  Future<T?> _call<T>(String method) async {
    try {
      return await channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
