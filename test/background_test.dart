import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift_time/app_services.dart';
import 'package:drift_time/background.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/evening_summary.dart';
import 'package:drift_time/services/nudge_sync.dart';
import 'package:drift_time/services/widget_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_background_channels.dart';
import 'helpers/fake_usage_source.dart';
import 'helpers/seed.dart';
import 'helpers/test_app.dart';

/// Monday 19 October 2026, 21:45: past the default 21:30 summary time.
final evening = DateTime(2026, 10, 19, 21, 45);

/// A day of raw events the ingest turns into sessions: YouTube during
/// Deep work (a learned off-track rule) and Notes after it.
List<Map<String, Object?>> eveningEvents() {
  DateTime at(int h, int m) => DateTime(2026, 10, 19, h, m);
  return [
    eventMap(at(9, 10), 'com.example.video', 'Main', 'resumed'),
    eventMap(at(9, 40), 'com.example.video', 'Main', 'paused'),
    eventMap(at(10, 0), 'com.example.notes', 'Main', 'resumed'),
    eventMap(at(10, 45), 'com.example.notes', 'Main', 'paused'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppServices s;
  late SettingsProvider settings;
  late FakeBackgroundChannels channels;
  late FakeNudgeBridge nudges;
  late FakeUsageSource usage;
  late Directory dir;

  setUp(() async {
    usage = FakeUsageSource(events: eveningEvents());
    nudges = FakeNudgeBridge();
    s = await testServices(usage: usage, nudges: nudges, now: evening);
    await seedSampleDay(s, evening);
    settings = await testSettings();
    channels = FakeBackgroundChannels();
    dir = await Directory.systemTemp.createTemp('drift_background');
  });

  tearDown(() async {
    channels.dispose();
    if (s.db.isOpen) await s.db.close();
    await dir.delete(recursive: true);
  });

  FixedClock clock() => s.clock as FixedClock;

  Future<bool> runSteps() =>
      runBackgroundSteps(s, settings, bridge: channels.bridge, directory: () async => dir);

  group('runBackgroundSteps', () {
    test('ingests, writes both snapshots, posts the summary and books the next', () async {
      final ok = await runSteps();
      expect(ok, isTrue);

      // Ingest read Android's events and moved the cursor.
      expect(usage.queries, isNotEmpty);
      final sessions = await s.sessions.sessionsBetween(DateTime(2026, 10, 19), DateTime(2026, 10, 20));
      expect(sessions.map((x) => x.p), contains('com.example.video'));

      final widget = jsonDecode(File('${dir.path}/$widgetSnapshotFile').readAsStringSync()) as Map;
      expect(widget['v'], 1);
      expect(widget['driftMin'], greaterThan(0));
      expect(channels.of('refresh'), hasLength(1));

      final nudge = jsonDecode(File('${dir.path}/$nudgeSnapshotFile').readAsStringSync()) as Map;
      expect(nudge['v'], 1);
      // Snapshot only: the service is never started or stopped from here.
      expect((nudges.starts, nudges.stops), (0, 0));

      final post = channels.of('postSummary').single.arguments as Map;
      expect(post['title'], startsWith('Today: '));
      expect(post['lines'], contains('Deep work: 30 min drift'));
      expect(post['payload'], 'review:2026-10-19');

      // Posted first, then booked: tomorrow's, not today's again.
      final booked = channels.of('scheduleSummary').single.arguments as Map;
      expect(booked['epochMs'], DateTime(2026, 10, 20, 21, 30).millisecondsSinceEpoch);
      final order = [for (final (_, c) in channels.calls) c.method];
      expect(order.indexOf('postSummary'), lessThan(order.indexOf('scheduleSummary')));
    });

    test('at most one summary per day across runs', () async {
      await runSteps();
      clock().value = DateTime(2026, 10, 19, 22, 45);
      await runSteps();
      clock().value = DateTime(2026, 10, 19, 23, 45);
      await runSteps();
      expect(channels.of('postSummary'), hasLength(1));
      expect(channels.of('scheduleSummary'), hasLength(3));
    });

    test('a morning run posts nothing and books tonight', () async {
      clock().value = DateTime(2026, 10, 19, 10, 50);
      await runSteps();
      expect(channels.of('postSummary'), isEmpty);
      final booked = channels.of('scheduleSummary').single.arguments as Map;
      expect(booked['epochMs'], DateTime(2026, 10, 19, 21, 30).millisecondsSinceEpoch);
    });

    test('rebooks at the chosen minute, and cancels when switched off', () async {
      clock().value = DateTime(2026, 10, 19, 10, 50);
      await settings.setSummaryMinute(20 * 60 + 15);
      await runSteps();
      expect(
        (channels.of('scheduleSummary').single.arguments as Map)['epochMs'],
        DateTime(2026, 10, 19, 20, 15).millisecondsSinceEpoch,
      );

      await settings.setSummaryEnabled(false);
      clock().value = evening;
      await runSteps();
      expect(channels.of('cancelSummary'), hasLength(1));
      expect(channels.of('scheduleSummary'), hasLength(1));
      expect(channels.of('postSummary'), isEmpty);
    });

    test('a failing step does not stop the later ones', () async {
      channels.failing.add('refresh');
      // The widget redraw fails on the native side; the bridge logs it.
      final ok = await runSteps();
      expect(ok, isTrue);
      expect(channels.of('postSummary'), hasLength(1));
      expect(channels.of('scheduleSummary'), hasLength(1));
    });

    test('a failed widget write marks the run failed but still books', () async {
      final ok = await runBackgroundSteps(
        s,
        settings,
        bridge: channels.bridge,
        directory: () async => Directory('${dir.path}/missing/deeper'),
      );
      expect(ok, isFalse);
      expect(channels.of('postSummary'), hasLength(1));
      expect(channels.of('scheduleSummary'), hasLength(1));
    });
  });

  group('runHeadless', () {
    test('runs, closes the database and reports finished ok', () async {
      final ok = await runHeadless(
        open: () async => s,
        bridge: channels.bridge,
        directory: () async => dir,
      );
      expect(ok, isTrue);
      expect(s.db.isOpen, isFalse);
      expect(channels.of('finished').single.arguments, {'ok': true});
      expect(channels.of('postSummary'), hasLength(1));
    });

    test('reports finished false when the database does not open', () async {
      final ok = await runHeadless(
        open: () async => throw StateError('database is locked'),
        bridge: channels.bridge,
        directory: () async => dir,
      );
      expect(ok, isFalse);
      expect(channels.of('finished').single.arguments, {'ok': false});
      expect(channels.of('postSummary'), isEmpty);
    });

    test('reports finished false when a step fails, after closing', () async {
      final ok = await runHeadless(
        open: () async => s,
        bridge: channels.bridge,
        directory: () async => Directory('${dir.path}/missing/deeper'),
      );
      expect(ok, isFalse);
      expect(s.db.isOpen, isFalse);
      expect(channels.of('finished').single.arguments, {'ok': false});
    });

    test('reads its own settings', () async {
      SharedPreferences.setMockInitialValues({'summary_enabled_v1': false});
      await runHeadless(open: () async => s, bridge: channels.bridge, directory: () async => dir);
      expect(channels.of('postSummary'), isEmpty);
      expect(channels.of('cancelSummary'), hasLength(1));
    });

    test('a finished call the native side rejects is only logged', () async {
      channels.failing.add('finished');
      final ok = await runHeadless(open: () async => s, bridge: channels.bridge, directory: () async => dir);
      expect(ok, isTrue);
    });
  });

  group('listenForRuns', () {
    test('answers runBackground with the handler result', () async {
      channels.bridge.listenForRuns(() async => true);
      final reply = await channels.invokeFromNative(channels.bridge.background, 'runBackground', {'summary': true});
      expect(reply, isTrue);
    });

    test('a throwing handler answers false', () async {
      channels.bridge.listenForRuns(() async => throw StateError('boom'));
      final reply = await channels.invokeFromNative(channels.bridge.background, 'runBackground');
      expect(reply, isFalse);
    });

    test('overlapping runs share one handler call', () async {
      final gate = Completer<bool>();
      var calls = 0;
      channels.bridge.listenForRuns(() {
        calls++;
        return gate.future;
      });
      final first = channels.invokeFromNative(channels.bridge.background, 'runBackground');
      final second = channels.invokeFromNative(channels.bridge.background, 'runBackground');
      await Future<void>.delayed(Duration.zero);
      gate.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(calls, 1);

      // Once it is over, the next run calls the handler again.
      await channels.invokeFromNative(channels.bridge.background, 'runBackground');
      expect(calls, 2);
    });

    test('without a handler the worker sees notImplemented', () async {
      final reply = await channels.invokeFromNative(channels.bridge.background, 'runBackground');
      expect(isNotImplemented(reply), isTrue);
    });

    test('the live handler can run the same steps on the live services', () async {
      channels.bridge.listenForRuns(
        () => runBackgroundSteps(s, settings, bridge: channels.bridge, directory: () async => dir),
      );
      final reply = await channels.invokeFromNative(channels.bridge.background, 'runBackground');
      expect(reply, isTrue);
      // The live run keeps the app's database open.
      expect(s.db.isOpen, isTrue);
      expect(channels.of('postSummary'), hasLength(1));
      expect(await s.meta.getInt(summarySentDayKey), 20261019);
    });
  });

  group('launch payloads', () {
    test('takeLaunchPayload reads the cold-start payload', () async {
      channels.launchPayload = 'review:2026-10-19';
      expect(await channels.bridge.takeLaunchPayload(), 'review:2026-10-19');
    });

    test('a tap while open arrives on the stream', () async {
      final got = <String>[];
      final sub = channels.bridge.launchPayloads.listen(got.add);
      await channels.invokeFromNative(channels.bridge.notify, 'launchPayload', 'review:2026-10-18');
      await Future<void>.delayed(Duration.zero);
      expect(got, ['review:2026-10-18']);
      await sub.cancel();
    });

    test('awaitIdle returns when the native side answers or is missing', () async {
      await channels.bridge.awaitIdle();
      expect(channels.of('awaitIdle'), hasLength(1));
      channels.dispose();
      // No native side at all: logged, and the app still starts.
      await channels.bridge.awaitIdle(limit: const Duration(milliseconds: 50));
    });
  });
}
