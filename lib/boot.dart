import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'app_services.dart';
import 'platform/background_bridge.dart';
import 'providers/settings_provider.dart';
import 'theme/drift_theme.dart';
import 'theme/theme_id.dart';

/// What the app needs before its first real screen.
class BootResult {
  const BootResult(this.services, this.settings);

  final AppServices services;
  final SettingsProvider settings;
}

/// One named startup step, so a stall or failure says where it happened.
class BootStep {
  const BootStep(this.label, this.run, {this.limit = const Duration(seconds: 15)});

  final String label;
  final Future<void> Function() run;

  /// A step that has not finished by then counts as failed: the user gets
  /// an explanation instead of a launch screen that never goes away.
  final Duration limit;
}

/// Thrown when a step outlives its [BootStep.limit].
class BootTimeout implements Exception {
  const BootTimeout(this.label, this.limit);

  final String label;
  final Duration limit;

  @override
  String toString() =>
      'Timed out after ${limit.inSeconds} s while ${label.toLowerCase()}';
}

/// The real startup: settings, then the database and Android bridges.
Future<BootResult> realBoot(void Function(String label) onStep) async {
  final settings = SettingsProvider();
  late AppServices services;
  final steps = [
    // A background run in a headless engine may hold the database; opening
    // it beside that run would let the two overwrite each other. Android
    // stops the run after 60 s, so this can take that long, hence its own
    // limit.
    BootStep(
      'Finishing a background update',
      () => BackgroundBridge.instance.awaitIdle(),
      limit: const Duration(seconds: 75),
    ),
    BootStep('Reading your settings', settings.load),
    BootStep('Opening your data', () async => services = await AppServices.open()),
  ];
  for (final step in steps) {
    onStep(step.label);
    await step.run().timeout(
      step.limit,
      onTimeout: () => throw BootTimeout(step.label, step.limit),
    );
  }
  return BootResult(services, settings);
}

/// The plain-text report the error screen copies, for pasting back.
String bootReport(String step, Object error, StackTrace? stack) {
  final lines = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty);
  return [
    'Drift startup report',
    'step: $step',
    'error: $error',
    if (lines.isNotEmpty) 'stack:',
    ...lines.take(12),
  ].join('\n');
}

/// The app's root. It draws a screen at once, so Android's launch screen
/// always goes away, then runs the startup steps. If one fails or stalls
/// it shows what happened and lets the user copy a report and retry,
/// instead of hanging on the launch screen.
class BootApp extends StatefulWidget {
  const BootApp({super.key, this.boot = realBoot});

  /// Tests inject a boot that fails, stalls or succeeds.
  final Future<BootResult> Function(void Function(String label) onStep) boot;

  @override
  State<BootApp> createState() => _BootAppState();
}

class _BootAppState extends State<BootApp> {
  BootResult? _ready;
  String _step = 'Starting';
  Object? _error;
  StackTrace? _stack;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _stack = null;
      _step = 'Starting';
    });
    try {
      final ready = await widget.boot((label) {
        if (mounted) setState(() => _step = label);
      });
      if (mounted) setState(() => _ready = ready);
    } catch (e, st) {
      if (mounted) {
        setState(() {
          _error = e;
          _stack = st;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready != null) {
      return DriftApp(services: ready.services, settings: ready.settings);
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildDriftTheme(ThemeId.mono),
      home: _error == null
          ? _Starting(step: _step)
          : _StartupError(
              step: _step,
              report: bootReport(_step, _error!, _stack),
              error: _error.toString(),
              onRetry: _start,
            ),
    );
  }
}

class _Starting extends StatelessWidget {
  const _Starting({required this.step});

  final String step;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Drift', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 20),
            SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            ),
            const SizedBox(height: 14),
            Text(
              step,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({
    required this.step,
    required this.report,
    required this.error,
    required this.onRetry,
  });

  final String step;
  final String report;
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
          children: [
            Icon(Icons.error_outline, size: 36, color: c.offTrack),
            const SizedBox(height: 16),
            Text("Drift couldn't start", style: text.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'It stopped while ${step.toLowerCase()}. Copy the report and '
              'send it over, then try again.',
              style: text.bodyMedium?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  error,
                  style: text.bodySmall?.copyWith(fontFamily: 'monospace', color: c.text),
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: report));
                messenger.showSnackBar(const SnackBar(content: Text('Report copied')));
              },
              icon: const Icon(Icons.content_copy, size: 18),
              label: const Text('Copy report'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
