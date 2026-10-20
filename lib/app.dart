import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'providers/settings_provider.dart';
import 'screens/onboarding_screen.dart';
import 'screens/plan_screen.dart';
import 'screens/review_v3_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'screens/usage_screen.dart';
// Also keeps backgroundMain, the headless engine's entry point, in the AOT
// build: without an import from main.dart's tree it would be dropped.
import 'background.dart';
import 'platform/background_bridge.dart';
import 'services/day_loader.dart';
import 'services/drive_backup_service.dart';
import 'services/evening_summary.dart';
import 'services/widget_snapshot.dart';
import 'services/period_loader.dart';
import 'services/nudge_sync.dart';
import 'services/unsorted_loader.dart';
import 'services/update_installer.dart';
import 'services/update_launch_check.dart';
import 'widgets/ask_sheet.dart';
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
        Provider<DriveBackupService>(create: (_) => DriveBackupService()),
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
    final services = context.read<AppServices>();
    final settings = context.read<SettingsProvider>();
    _steps = setupSteps(services.usage, services.nudges);
    missingSteps(_steps, skipped: settings.skippedSetup).then((missing) {
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
      final settings = context.read<SettingsProvider>();
      return OnboardingScreen(
        steps: _steps,
        skipped: settings.skippedSetup,
        onSkip: settings.skipSetup,
        onDone: () => setState(() => _needsSetup = false),
      );
    }
    return const HomeShell();
  }
}

/// The five bottom tabs: Today, Plan, Review, Usage, Settings. Reads new usage
/// and checks for updates on start and every time the app comes back.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;
  bool _asking = false;

  /// Counts recounts of [AppServices.toSort], so a slow one that finishes
  /// after a newer one is dropped.
  int _countGeneration = 0;
  late final AppServices _services;
  late final SettingsProvider _settings;
  late final DriveBackupService _drive;
  StreamSubscription<String>? _payloads;

  /// The day an evening summary tap asked to open in Review.
  final _openReviewDay = ValueNotifier<DateTime?>(null);

  /// What the summary booking was last made from, so unrelated settings
  /// changes don't rebook it.
  (bool, int)? _bookedSummary;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _settings = context.read<SettingsProvider>();
    _drive = context.read<DriveBackupService>();
    WidgetsBinding.instance.addObserver(this);
    _services.revision.addListener(_onDataChanged);
    _settings.addListener(_syncNudges);
    _settings.addListener(_bookSummary);
    // A background run while the app is open happens here, in this
    // isolate, so the database never has two writers.
    BackgroundBridge.instance.listenForRuns(
      () => runBackgroundSteps(_services, _settings),
    );
    // Before the first frame, or a summary tap while the app is open is lost.
    _payloads = BackgroundBridge.instance.launchPayloads.listen(_onPayload);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStart());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _services.revision.removeListener(_onDataChanged);
    _settings.removeListener(_syncNudges);
    _settings.removeListener(_bookSummary);
    _payloads?.cancel();
    _openReviewDay.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _readAndAsk();
    runLaunchUpdateCheck(_settings, isAndroid: _isAndroid);
    unawaited(_drive.checkAndRunScheduled(_services, _settings));
  }

  /// Payloads of the tabs the Today notifications open
  /// (TodayNotifications.kt).
  static const tabPayloads = {'tab:today': 0, 'tab:usage': 3};

  /// A Today notification carries `tab:today` or `tab:usage`; an evening
  /// summary tap carries `review:YYYY-MM-DD`: open that day.
  void _onPayload(String payload) {
    final tab = tabPayloads[payload];
    if (tab != null) {
      if (mounted) setState(() => _tab = tab);
      return;
    }
    final day = reviewDayOf(payload);
    if (day == null || !mounted) return;
    setState(() => _tab = 2);
    _openReviewDay.value = day;
  }

  void _bookSummary() {
    final key = (_settings.summaryEnabled, _settings.summaryMinute);
    if (key == _bookedSummary) return;
    _bookedSummary = key;
    unawaited(bookNextSummary(_services, _settings));
  }

  /// The plan, the rules or the usage changed: refresh the badge, the
  /// snapshot the nudge service reads and the home-screen widgets.
  Future<void> _onDataChanged() async {
    _syncNudges();
    unawaited(writeWidgetSnapshot(_services, _settings));
    final generation = ++_countGeneration;
    final unsorted = await loadUnsorted(_services);
    if (mounted && generation == _countGeneration) {
      _services.toSort.value = unsorted.length;
    }
  }

  void _syncNudges() {
    if (!mounted) return;
    syncNudges(_services, _settings, context.drift);
  }

  /// Reads new usage, then asks about guessed apps, one sheet at a time.
  Future<void> _readAndAsk() async {
    await _services.ingest();
    if (!mounted || _asking) return;
    final day = await loadDay(_services, _services.clock.now());
    if (!mounted || day.unanswered.isEmpty) return;
    _asking = true;
    try {
      await showAskQueue(context, _services, day);
    } finally {
      _asking = false;
    }
  }

  Future<void> _onStart() async {
    final services = _services;
    final settings = _settings;
    final messenger = ScaffoldMessenger.of(context);
    _syncNudges();
    _bookSummary();
    _readAndAsk();
    unawaited(_drive.checkAndRunScheduled(services, settings));
    final cold = await BackgroundBridge.instance.takeLaunchPayload();
    if (cold != null) _onPayload(cold);
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
          ReviewV3Screen(
            firstWeekday: context.watch<SettingsProvider>().firstWeekday,
            openDay: _openReviewDay,
          ),
          const UsageScreen(),
          SettingsScreen(daysLoader: (first, last) => loadDays(_services, first, last)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: 'Today',
          ),
          const NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Plan',
          ),
          const NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Review',
          ),
          const NavigationDestination(
            icon: Icon(Icons.donut_large_outlined),
            selectedIcon: Icon(Icons.donut_large),
            label: 'Usage',
          ),
          NavigationDestination(
            icon: _ToSortBadge(
              count: _services.toSort,
              child: const Icon(Icons.settings_outlined),
            ),
            selectedIcon: _ToSortBadge(
              count: _services.toSort,
              child: const Icon(Icons.settings),
            ),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// [child] with a badge holding [count] while it is above zero.
class _ToSortBadge extends StatelessWidget {
  const _ToSortBadge({required this.count, required this.child});

  final ValueListenable<int> count;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: count,
    builder: (context, n, child) => Badge(
      isLabelVisible: n > 0,
      label: Text('$n'),
      child: child,
    ),
    child: child,
  );
}
