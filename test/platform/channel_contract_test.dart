import 'package:drift_time/platform/channel_usage_source.dart';
import 'package:drift_time/platform/icon_switcher.dart';
import 'package:drift_time/platform/usage_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The method names and argument keys Kotlin reads (UsageBridge.kt,
/// IconSwitcher.kt). A rename on either side must fail here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const usage = MethodChannel('drift/usage');
  const icon = MethodChannel('drift/icon');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  void answer(MethodChannel channel, Object? Function(MethodCall) reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  setUp(() => calls = []);

  tearDown(() {
    messenger.setMockMethodCallHandler(usage, null);
    messenger.setMockMethodCallHandler(icon, null);
  });

  group('ChannelUsageSource', () {
    const source = ChannelUsageSource();

    test('hasUsageAccess and battery checks pass no arguments', () async {
      answer(usage, (call) => true);
      expect(await source.hasUsageAccess(), isTrue);
      expect(await source.isIgnoringBatteryOptimizations(), isTrue);
      await source.openUsageAccessSettings();
      await source.requestIgnoreBatteryOptimizations();
      expect(calls.map((c) => c.method), [
        'hasUsageAccess',
        'isIgnoringBatteryOptimizations',
        'openUsageAccessSettings',
        'requestIgnoreBatteryOptimizations',
      ]);
      expect(calls.every((c) => c.arguments == null), isTrue);
    });

    test('queryEvents sends fromMs and toMs and types each event', () async {
      answer(usage, (call) => [
            {
              't': 1760860800123,
              'p': 'com.example.video',
              'c': 'com.example.video.Player',
              'k': UsageEventKinds.resumed,
            },
            {'t': 0, 'p': 'android', 'c': null, 'k': UsageEventKinds.screenOff},
          ]);
      final events =
          await source.queryEvents(fromMs: 1760800000000, toMs: 1760886400000);
      expect(calls.single.method, 'queryEvents');
      expect(calls.single.arguments,
          {'fromMs': 1760800000000, 'toMs': 1760886400000});
      expect(events, hasLength(2));
      expect(events.first, isA<Map<String, Object?>>());
      expect(events.first['t'], 1760860800123);
      expect(events.first['k'], 'resumed');
      expect(events.last['c'], isNull);
      expect(UsageEventKinds.all, contains(events.last['k']));
    });

    test('earliestEventMs reads an int or null', () async {
      answer(usage, (call) => 1760000000000);
      expect(await source.earliestEventMs(), 1760000000000);
      answer(usage, (call) => null);
      expect(await source.earliestEventMs(), isNull);
      expect(calls.map((c) => c.method).toSet(), {'earliestEventMs'});
    });

    test('listApps types each app', () async {
      answer(usage, (call) => [
            {
              'p': 'com.example.notes',
              'label': 'Notes',
              'category': AppCategories.productivity,
            },
          ]);
      final apps = await source.listApps();
      expect(calls.single.method, 'listApps');
      expect(apps.single['p'], 'com.example.notes');
      expect(apps.single['label'], 'Notes');
      expect(AppCategories.all, contains(apps.single['category']));
    });

    test('appIcon sends p and returns the PNG bytes', () async {
      final png = Uint8List.fromList([137, 80, 78, 71]);
      answer(usage, (call) => png);
      final bytes = await source.appIcon('com.example.chat');
      expect(calls.single.method, 'appIcon');
      expect(calls.single.arguments, {'p': 'com.example.chat'});
      expect(bytes, [137, 80, 78, 71]);
    });

    test('homePackages and drainBuffer return strings', () async {
      answer(usage, (call) => call.method == 'homePackages'
          ? ['com.example.launcher']
          : ['/data/user/0/x/files/usage_buffer/1-2.jsonl']);
      expect(await source.homePackages(), ['com.example.launcher']);
      expect(await source.drainBuffer(),
          ['/data/user/0/x/files/usage_buffer/1-2.jsonl']);
      expect(calls.map((c) => c.method), ['homePackages', 'drainBuffer']);
    });

    test('deleteBuffer sends paths, and skips the call when empty', () async {
      answer(usage, (call) => null);
      await source.deleteBuffer(['/a/1-2.jsonl', '/a/3-4.jsonl']);
      await source.deleteBuffer([]);
      expect(calls.single.method, 'deleteBuffer');
      expect(calls.single.arguments, {
        'paths': ['/a/1-2.jsonl', '/a/3-4.jsonl'],
      });
    });

    test('diagnostics keeps all three keys', () async {
      answer(usage, (call) => {
            'workerLastRunMs': 1760860800000,
            'bufferFiles': 3,
            'bufferCursorMs': null,
          });
      expect(await source.diagnostics(), {
        'workerLastRunMs': 1760860800000,
        'bufferFiles': 3,
        'bufferCursorMs': null,
      });
    });

    test('a native error gives the safe defaults', () async {
      messenger.setMockMethodCallHandler(usage, (call) async {
        throw PlatformException(code: 'FAILED');
      });
      await _expectDefaults(source);
    });

    test('a missing plugin gives the safe defaults', () async {
      await _expectDefaults(source);
    });
  });

  group('ChannelIconSwitcher', () {
    const switcher = ChannelIconSwitcher();

    test('current reads the alias name', () async {
      answer(icon, (call) => 'IconNeedle');
      expect(await switcher.current(), 'IconNeedle');
      expect(calls.single.method, 'current');
      expect(calls.single.arguments, isNull);
    });

    test('set sends name', () async {
      answer(icon, (call) => null);
      await switcher.set('IconEscape');
      expect(calls.single.method, 'set');
      expect(calls.single.arguments, {'name': 'IconEscape'});
    });

    test('set refuses an unknown name without calling Android', () async {
      answer(icon, (call) => null);
      await expectLater(switcher.set('IconNope'), throwsArgumentError);
      expect(calls, isEmpty);
    });

    test('a native refusal reaches the caller', () async {
      messenger.setMockMethodCallHandler(icon, (call) async {
        throw PlatformException(code: 'UNKNOWN_ICON');
      });
      await expectLater(
          switcher.set('IconWanderer'), throwsA(isA<PlatformException>()));
    });

    test('a missing plugin or an odd answer gives the default', () async {
      expect(await switcher.current(), 'IconMeltingClock');
      answer(icon, (call) => 'SomethingElse');
      expect(await switcher.current(), 'IconMeltingClock');
    });

    test('the alias list matches the manifest', () {
      expect(iconAliasNames, [
        'IconMeltingClock',
        'IconTimeRiver',
        'IconSlidingDay',
        'IconNeedle',
        'IconWanderer',
        'IconEscape',
      ]);
    });
  });
}

Future<void> _expectDefaults(UsageSource source) async {
  expect(await source.hasUsageAccess(), isFalse);
  expect(await source.isIgnoringBatteryOptimizations(), isFalse);
  await source.openUsageAccessSettings();
  await source.requestIgnoreBatteryOptimizations();
  expect(await source.queryEvents(fromMs: 0, toMs: 1), isEmpty);
  expect(await source.earliestEventMs(), isNull);
  expect(await source.listApps(), isEmpty);
  expect(await source.appIcon('com.example.chat'), isNull);
  expect(await source.homePackages(), isEmpty);
  expect(await source.drainBuffer(), isEmpty);
  await source.deleteBuffer(['/a/1-2.jsonl']);
  expect(await source.diagnostics(), {
    'workerLastRunMs': null,
    'bufferFiles': 0,
    'bufferCursorMs': null,
  });
}
