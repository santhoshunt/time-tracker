import 'package:drift_time/platform/channel_nudge_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The method names Kotlin reads (NudgeBridge.kt). A rename on either side
/// must fail here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('drift/nudge');
  const bridge = ChannelNudgeBridge();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  void answer(Object? Function(MethodCall) reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  setUp(() => calls = []);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('permission checks read bools and pass no arguments', () async {
    answer((call) => true);
    expect(await bridge.canDrawOverlays(), isTrue);
    expect(await bridge.hasNotificationPermission(), isTrue);
    expect(await bridge.requestNotificationPermission(), isTrue);
    expect(calls.map((c) => c.method), [
      'canDrawOverlays',
      'hasNotificationPermission',
      'requestNotificationPermission',
    ]);
    expect(calls.every((c) => c.arguments == null), isTrue);
  });

  test('a refused permission comes back false', () async {
    answer((call) => false);
    expect(await bridge.canDrawOverlays(), isFalse);
    expect(await bridge.requestNotificationPermission(), isFalse);
  });

  test('settings and service calls use the Kotlin method names', () async {
    answer((call) => null);
    await bridge.openOverlaySettings();
    await bridge.startService();
    await bridge.stopService();
    expect(calls.map((c) => c.method),
        ['openOverlaySettings', 'startService', 'stopService']);
  });

  test('serviceStatus keeps all four keys', () async {
    answer((call) => {
          'running': true,
          'lastTickMs': 1760860800000,
          'lastNudgeMs': null,
          'lastError': 'SecurityException: denied',
        });
    expect(await bridge.serviceStatus(), {
      'running': true,
      'lastTickMs': 1760860800000,
      'lastNudgeMs': null,
      'lastError': 'SecurityException: denied',
    });
    expect(calls.single.method, 'serviceStatus');
  });

  test('a native error gives the safe defaults', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'FAILED');
    });
    await _expectDefaults(bridge);
  });

  test('a missing plugin gives the safe defaults', () async {
    await _expectDefaults(bridge);
  });
}

Future<void> _expectDefaults(ChannelNudgeBridge bridge) async {
  expect(await bridge.canDrawOverlays(), isFalse);
  expect(await bridge.hasNotificationPermission(), isFalse);
  expect(await bridge.requestNotificationPermission(), isFalse);
  await bridge.openOverlaySettings();
  await bridge.startService();
  await bridge.stopService();
  expect(await bridge.serviceStatus(), {'running': false});
}
