import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'providers/settings_provider.dart';
import 'screens/onboarding_screen.dart';
import 'screens/plan_screen.dart';
import 'screens/review_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'services/update_installer.dart';
import 'services/update_launch_check.dart';
import 'theme/drift_theme.dart';
import 'widgets/undo_snackbar.dart';

/// The app root: services and settings at the top of the tree, the theme
/// Sandy picked, and the setup pages until every permission is granted.
class DriftApp extends StatelessWidget {
  const DriftApp({super.key, required this.services, required this.settings});

  final AppServices services;
  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Drift',
          debugShowCheckedModeBanner: false,
          theme: buildDriftTheme(settings.theme),
          home: const _SetupGate(),
        ),
      ),
    );
  }
}

/// Shows the setup pages while a permission is missing, then the tabs.
/// Pages follow missing permissions, not versions, so a permission added
/// in a later release appears on its own after the update.
class _SetupGate extends StatefulWidget {
  const _SetupGate();

  @override
  State<_SetupGate> createState() => _SetupGateState();
}

class _SetupGateState extends State<_SetupGate> {
  bool? _needsSetup;
  late final List<SetupStep> _steps;

  @override
  void initState() {
    super.initState();
    _steps = setupSteps(context.read<AppServices>().usage);
    missingSteps(_steps).then((missing) {
      if (mounted) setState(() => _needsSetup = missing.isNotEmpty);
    });
  }

  @override
  Widget build(BuildContext context) {
    final needsSetup = _needsSetup;
    if (needsSetup == null) {
      return Scaffold(backgroundColor: context.drift.bg);
    }
    if (needsSetup) {
      return OnboardingScreen(
        steps: _steps,
        onDone: () => setState(() => _needsSetup = false),
      );
    }
    return const HomeShell();
  }
}

/// The four bottom tabs: Today, Plan, Review, Settings. Reads new usage
/// and checks for updates on start and every time the app comes back.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStart());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    context.read<AppServices>().ingest();
    runLaunchUpdateCheck(context.read<SettingsProvider>(), isAndroid: _isAndroid);
  }

  Future<void> _onStart() async {
    final services = context.read<AppServices>();
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    services.ingest();
    final message = await takeUpdateResultMessage(settings);
    if (message != null) {
      final info = await PackageInfo.fromPlatform();
      await settings.recordUpdateSuccess(info.version, services.clock.now());
      showAppToastOn(
        messenger,
        message,
        tone: AppToastTone.success,
        icon: Icons.system_update_alt,
        actionLabel: 'Settings',
        onAction: ChannelUpdateInstaller.instance.openInstallSettings,
        duration: const Duration(seconds: 10),
      );
    }
    await runLaunchUpdateCheck(settings, isAndroid: _isAndroid);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TodayScreen(onPlan: () => setState(() => _tab = 1)),
          const PlanScreen(),
          const ReviewScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Plan',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Review',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
