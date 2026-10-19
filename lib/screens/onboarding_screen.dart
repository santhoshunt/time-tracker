import 'package:flutter/material.dart';

import '../platform/usage_source.dart';
import '../theme/drift_theme.dart';

/// One setup step: a permission Drift needs, how to check it and how to
/// send the user to the Android screen that grants it.
class SetupStep {
  const SetupStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.isDone,
    required this.open,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final Future<bool> Function() isDone;
  final Future<void> Function() open;
}

/// The steps for this release, in order. Pages come only from steps that
/// are not done yet, so a permission added in a later release shows up
/// on its own after the update.
List<SetupStep> setupSteps(UsageSource usage) => [
  SetupStep(
    icon: Icons.visibility_outlined,
    title: 'See which app is open',
    body:
        'Android opens Settings. Find Drift and switch on Usage access. '
        'Drift reads app names and times only, and keeps them on this phone.',
    action: 'Open settings',
    isDone: usage.hasUsageAccess,
    open: usage.openUsageAccessSettings,
  ),
  SetupStep(
    icon: Icons.battery_charging_full_outlined,
    title: 'Keep Drift running',
    body:
        'Drift saves your app history once an hour in the background. '
        'Allow it to run without battery limits so nothing is lost.',
    action: 'Allow',
    isDone: usage.isIgnoringBatteryOptimizations,
    open: usage.requestIgnoreBatteryOptimizations,
  ),
];

/// Returns the steps still missing, in order.
Future<List<SetupStep>> missingSteps(List<SetupStep> steps) async {
  final missing = <SetupStep>[];
  for (final s in steps) {
    if (!await s.isDone()) missing.add(s);
  }
  return missing;
}

/// Setup option B: one page per missing permission. Rechecks every step
/// when the app comes back from Android settings and calls [onDone] once
/// nothing is missing.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.steps,
    required this.onDone,
  });

  final List<SetupStep> steps;
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  List<SetupStep>? _missing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final missing = await missingSteps(widget.steps);
    if (!mounted) return;
    if (missing.isEmpty) {
      widget.onDone();
      return;
    }
    setState(() => _missing = missing);
  }

  @override
  Widget build(BuildContext context) {
    final missing = _missing;
    final c = context.drift;
    if (missing == null) {
      return Scaffold(backgroundColor: c.bg);
    }
    final step = missing.first;
    final index = widget.steps.indexOf(step);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              Text(
                'Step ${index + 1} of ${widget.steps.length}',
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
              const Spacer(flex: 2),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.card,
                  border: Border.all(color: c.line),
                ),
                child: Icon(step.icon, size: 36, color: c.accent),
              ),
              const SizedBox(height: 28),
              Text(
                step.title,
                textAlign: TextAlign.center,
                style: text.titleLarge?.copyWith(color: c.text),
              ),
              const SizedBox(height: 12),
              Text(
                step.body,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: c.textSecondary),
              ),
              const Spacer(flex: 3),
              _Dots(count: widget.steps.length, active: index),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: step.open,
                  child: Text(step.action),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == active ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == active ? c.accent : c.line,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
