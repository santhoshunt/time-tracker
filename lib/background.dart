import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';

import 'app_services.dart';
import 'platform/background_bridge.dart';
import 'providers/settings_provider.dart';
import 'services/evening_summary.dart';
import 'services/nudge_sync.dart';
import 'services/widget_snapshot.dart';
import 'theme/drift_theme.dart';

/// The headless engine's entry point (DriftBackground.kt): one background
/// run with Drift closed, then a report back so the worker can destroy the
/// engine. Never draws anything.
///
/// DriftBackground names this library, not main.dart, as the entry point's
/// home. lib/app.dart imports this file for [runBackgroundSteps], which
/// keeps it, and with it this function, in the release build.
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dart-side plugin registration (path_provider, shared_preferences) runs
  // by itself only for main(); a second entry point has to ask.
  DartPluginRegistrant.ensureInitialized();
  await runHeadless();
}

/// [backgroundMain] without the engine set-up, for tests. Opens its own
/// settings and services, runs [runBackgroundSteps], closes the database
/// (this isolate is about to go) and always reports `finished`, also when
/// opening failed, so the worker never waits out its timeout. True when
/// every step ran.
Future<bool> runHeadless({
  Future<AppServices> Function() open = AppServices.open,
  BackgroundBridge? bridge,
  Future<Directory> Function()? directory,
}) async {
  final b = bridge ?? BackgroundBridge.instance;
  AppServices? services;
  var ok = false;
  try {
    final settings = SettingsProvider();
    await settings.load();
    services = await open();
    ok = await runBackgroundSteps(services, settings, bridge: b, directory: directory);
  } catch (e, st) {
    debugPrint('Background run failed: $e\n$st');
    ok = false;
  } finally {
    try {
      await services?.db.close();
    } catch (e) {
      debugPrint('Background database close failed: $e');
    }
    await b.finished(ok);
  }
  return ok;
}

/// One background run's steps, in the headless isolate or the app's own
/// (the `listenForRuns` handler in lib/app.dart, which passes the live
/// services and must not close them):
///
/// 1. ingest new usage
/// 2. write the widget snapshot and redraw the widgets
/// 3. write the nudge snapshot, without touching the nudge service
/// 4. post the evening summary when it is due
/// 5. book the next summary
///
/// The summary is posted before the booking, so a run at the summary time
/// books tomorrow's and not today's again. One step failing never stops
/// the later ones; every step is safe to repeat, so the next run fixes
/// what this one missed. True when all of them ran.
Future<bool> runBackgroundSteps(
  AppServices services,
  SettingsProvider settings, {
  BackgroundBridge? bridge,
  Future<Directory> Function()? directory,
}) async {
  final b = bridge ?? BackgroundBridge.instance;
  final colors = DriftColors.of(settings.theme);
  var ok = true;

  Future<void> step(String name, Future<Object?> Function() run) async {
    try {
      final result = await run();
      if (result == false) ok = false;
    } catch (e, st) {
      ok = false;
      debugPrint('Background $name failed: $e\n$st');
    }
  }

  // ingest() logs and swallows its own failure and answers null then.
  await step('ingest', () async => await services.ingest() != null);
  await step(
    'widget snapshot',
    () => writeWidgetSnapshot(services, settings, directory: directory, bridge: b),
  );
  await step(
    'nudge snapshot',
    () => syncNudges(services, settings, colors, directory: directory, startService: false),
  );
  await step('summary', () async {
    await maybePostSummary(services, settings, bridge: b);
    return null;
  });
  await step('summary booking', () => bookNextSummary(services, settings, bridge: b));
  return ok;
}
