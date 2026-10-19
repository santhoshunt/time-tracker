import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native side of background runs and the evening summary: channels
/// `drift/background` (DriftBackground.kt), `drift/notify`
/// (NotifyBridge.kt) and `drift/widgets` (WidgetsChannel.kt).
///
/// Only one isolate may write the database at a time. A worker run goes to
/// the app's isolate when it is alive ([listenForRuns]) and to a headless
/// one otherwise, and the app calls [awaitIdle] before opening the
/// database so it never opens beside a headless run.
///
/// Every call is best effort: a missing or failing native side (tests, a
/// platform without the bridge) is logged and answered with the safe
/// default, because none of this may stop the app from starting.
class BackgroundBridge {
  BackgroundBridge({
    this.background = const MethodChannel('drift/background'),
    this.notify = const MethodChannel('drift/notify'),
    this.widgets = const MethodChannel('drift/widgets'),
  });

  /// The app's and the headless engine's bridge.
  static final instance = BackgroundBridge();

  final MethodChannel background;
  final MethodChannel notify;
  final MethodChannel widgets;

  Future<bool>? _run;
  StreamController<String>? _payloads;

  /// Returns once no headless run holds the database. The native side
  /// gives up after a minute and stops the run; [limit] is a further cap
  /// in case the native side never answers at all.
  Future<void> awaitIdle({Duration limit = const Duration(seconds: 70)}) async {
    try {
      await background.invokeMethod<void>('awaitIdle').timeout(limit);
    } catch (e) {
      debugPrint('awaitIdle: $e');
    }
  }

  /// Answers the worker's `runBackground` calls in the app's isolate with
  /// [handler], which runs the same steps as a headless run. Two calls that
  /// overlap (the hourly run and the summary run) share one run, since the
  /// second would only repeat the first. A handler that throws answers
  /// false, so the worker records a failed run instead of waiting.
  void listenForRuns(Future<bool> Function() handler) {
    background.setMethodCallHandler((call) async {
      if (call.method != 'runBackground') {
        throw MissingPluginException('No ${call.method} on drift/background');
      }
      final running = _run;
      if (running != null) return running;
      final run = _run = () async {
        try {
          return await handler();
        } catch (e, st) {
          debugPrint('Background run failed: $e\n$st');
          return false;
        }
      }();
      try {
        return await run;
      } finally {
        _run = null;
      }
    });
  }

  /// The headless run reports back, so the worker can destroy the engine.
  Future<void> finished(bool ok) async {
    try {
      await background.invokeMethod<void>('finished', {'ok': ok});
    } catch (e) {
      debugPrint('Background finish failed: $e');
    }
  }

  /// Books the evening summary for [at], replacing any earlier booking.
  Future<void> scheduleSummary(DateTime at) =>
      _call(notify, 'scheduleSummary', {'epochMs': at.millisecondsSinceEpoch});

  /// Cancels the booked evening summary.
  Future<void> cancelSummary() => _call(notify, 'cancelSummary');

  /// Posts the summary notification. A tap opens the app with [payload].
  /// False when it was not shown (no notification permission, or the
  /// native side failed), so the caller can try again later.
  Future<bool> postSummary({
    required String title,
    required List<String> lines,
    required String payload,
  }) async {
    try {
      return await notify.invokeMethod<bool>('postSummary', {
            'title': title,
            'lines': lines,
            'payload': payload,
          }) ??
          false;
    } catch (e) {
      debugPrint('postSummary failed: $e');
      return false;
    }
  }

  /// The payload of the summary tap that started the app, once; null when
  /// it started any other way.
  Future<String?> takeLaunchPayload() async {
    try {
      return await notify.invokeMethod<String>('takeLaunchPayload');
    } catch (e) {
      debugPrint('takeLaunchPayload failed: $e');
      return null;
    }
  }

  /// Payloads of summary taps while the app is already open. Listening
  /// installs the `drift/notify` handler that MainActivity.onNewIntent
  /// calls.
  Stream<String> get launchPayloads {
    final existing = _payloads;
    if (existing != null) return existing.stream;
    final controller = _payloads = StreamController<String>.broadcast();
    notify.setMethodCallHandler((call) async {
      if (call.method == 'launchPayload' && call.arguments is String) {
        controller.add(call.arguments as String);
      }
      return null;
    });
    return controller.stream;
  }

  /// Asks the home-screen widgets to redraw from the snapshot just written.
  Future<void> refreshWidgets() => _call(widgets, 'refresh');

  Future<void> _call(MethodChannel channel, String method, [Object? args]) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('${channel.name} $method failed: $e');
    }
  }
}
