import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../icons/drift_icons.dart';
import '../providers/settings_provider.dart';
import '../services/csv_export.dart';
import '../services/drive_backup_service.dart';
import '../services/update_service.dart';
import '../theme/drift_theme.dart';
import '../widgets/drive_backup_section.dart';
import '../widgets/settings_group.dart';
import '../widgets/time_wheel.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/update_sheet.dart';
import 'app_groups_screen.dart';
import 'diagnostics_screen.dart';
import 'icon_picker_screen.dart';
import 'rules_screen.dart';
import 'theme_picker_screen.dart';

/// "22:00 to 07:00", or "Off" when start and end are the same.
String quietHoursLabel(int start, int end) {
  if (start == end) return 'Off';
  String hm(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  return '${hm(start)} to ${hm(end)}';
}

/// Settings option A: grouped rows. Appearance (Theme, App icon), Updates
/// (Check for updates, Check on launch) and Help (Diagnostics). Each
/// picker opens its own page.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.updateService,
    this.packageInfo,
    this.daysLoader,
  });

  /// Tests inject a service with a fake HTTP client.
  final UpdateService? updateService;
  final Future<PackageInfo> Function()? packageInfo;

  /// How the export loads history; the home shell passes the Review tab's
  /// fast range loader.
  final DaysLoader? daysLoader;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _checking = false;
  bool _exporting = false;
  String? _version;
  DriftIcon? _icon;

  bool get _installsInApp =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    (widget.packageInfo ?? PackageInfo.fromPlatform)().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    final alias = await context.read<AppServices>().icons.current();
    if (mounted) setState(() => _icon = DriftIcon.fromAlias(alias));
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _loadIcon();
  }

  Future<void> _pickMinutes({
    required String title,
    required List<int> options,
    required int current,
    required String Function(int) label,
    required Future<void> Function(int) onPicked,
    String? help,
  }) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: RadioGroup<int>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(context, v),
          // Scrolls on short screens and with large text instead of
          // overflowing.
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              if (help != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    help,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.drift.textSecondary,
                    ),
                  ),
                ),
              for (final o in options)
                RadioListTile<int>(value: o, title: Text(label(o))),
              const SizedBox(height: 8),
            ],
          ),
          ),
        ),
      ),
    );
    if (picked != null) await onPicked(picked);
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    final services = context.read<AppServices>();
    try {
      final where = await exportAllCsv(
        services,
        widget.daysLoader ?? dayByDay(services),
      );
      showAppToastOn(
        messenger,
        'Saved to $where',
        tone: AppToastTone.success,
        icon: Icons.download_done,
      );
    } catch (e) {
      showAppToastOn(
        messenger,
        "Couldn't save the export. Try again.",
        tone: AppToastTone.error,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  static String _hm(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  /// The summary time, on the same wheel as the block editor. Android may
  /// deliver it a few minutes late, hence "Around" in the row.
  Future<void> _pickSummaryTime() async {
    final settings = context.read<SettingsProvider>();
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => TimeWheelSheet(
        title: 'Evening summary at',
        initial: settings.summaryMinute,
        allowMidnightEnd: false,
      ),
    );
    if (picked == null) return;
    await settings.setSummaryMinute(picked);
    if (!settings.summaryEnabled) await settings.setSummaryEnabled(true);
  }

  /// Quiet hours option A: From and Until wheels in one sheet, the same
  /// wheels as the block editor (the Material clock dial was hard to read).
  Future<void> _pickQuietHours() async {
    final settings = context.read<SettingsProvider>();
    final picked = await showQuietHoursSheet(
      context,
      start: settings.quietStartMin,
      end: settings.quietEndMin,
    );
    if (picked == null) return;
    await settings.setQuietHours(picked.$1, picked.$2);
  }

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await (widget.updateService ?? UpdateService()).check();
      if (!mounted) return;
      setState(() => _checking = false);
      switch (result) {
        case UpToDate(:final currentVersion):
          showAppToastOn(
            messenger,
            "You're on the latest version (${versionLabel(currentVersion)}).",
            tone: AppToastTone.success,
            icon: Icons.verified_outlined,
          );
        case UpdateAvailable(:final updates) when _installsInApp:
          availableUpdate.value = updates;
          await showUpdateSheet(context, updates);
        case UpdateAvailable(:final latestTag):
          showAppToastOn(
            messenger,
            'Version $latestTag is out. The release page on GitHub has the APK.',
            tone: AppToastTone.info,
          );
        case CheckFailed(:final message):
          showAppToastOn(messenger, message, tone: AppToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final c = context.drift;
    final icon = _icon;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
            SettingsGroup(
              title: 'Nudges and notifications',
              children: [
                SettingsRow(
                  title: 'Live nudges',
                  subtitle: 'When you drift from your plan',
                  onTap: () =>
                      settings.setNudgesEnabled(!settings.nudgesEnabled),
                  trailing: Switch(
                    value: settings.nudgesEnabled,
                    onChanged: settings.setNudgesEnabled,
                  ),
                ),
                if (settings.nudgesEnabled) ...[
                  SettingsRow(
                    title: 'First nudge after',
                    value: '${settings.nudgeAfterMin} min',
                    onTap: () => _pickMinutes(
                      title: 'First nudge after this much drift',
                      help:
                          'How long you can stay on an off-track app before '
                          'Drift nudges you.',
                      options: const [2, 5, 10, 15, 30],
                      current: settings.nudgeAfterMin,
                      label: (m) => '$m min',
                      onPicked: settings.setNudgeAfterMin,
                    ),
                  ),
                  SettingsRow(
                    title: 'Nudge again after',
                    value: '${settings.nudgeRepeatMin} min',
                    onTap: () => _pickMinutes(
                      title: 'Wait this long before nudging again',
                      help:
                          'After a nudge, Drift stays quiet this long even if '
                          'you stay off track. "5 more minutes" overrides it '
                          'for that app.',
                      options: const [5, 10, 15, 30, 60],
                      current: settings.nudgeRepeatMin,
                      label: (m) => '$m min',
                      onPicked: settings.setNudgeRepeatMin,
                    ),
                  ),
                  SettingsRow(
                    title: 'Quiet hours',
                    value: quietHoursLabel(
                      settings.quietStartMin,
                      settings.quietEndMin,
                    ),
                    onTap: _pickQuietHours,
                  ),
                  SettingsRow(
                    title: 'Lock instead of nudge',
                    subtitle:
                        'Apps you marked off track lock in every block. Hold '
                        '3 seconds to open one for 5 minutes.',
                    onTap: () => settings.setFocusLock(!settings.focusLock),
                    trailing: Switch(
                      value: settings.focusLock,
                      onChanged: settings.setFocusLock,
                    ),
                  ),
                ],
                SettingsRow(
                  title: 'Evening summary',
                  subtitle: settings.summaryEnabled
                      ? 'Around ${_hm(settings.summaryMinute)}, drift per block'
                      : 'Off',
                  onTap: _pickSummaryTime,
                  trailing: Switch(
                    value: settings.summaryEnabled,
                    onChanged: settings.setSummaryEnabled,
                  ),
                ),
                SettingsRow(
                  title: 'Today in notifications',
                  subtitle:
                      'Your current block, and distracting time against all '
                      'app time',
                  onTap: () => settings.setTodayNotifications(
                    !settings.todayNotifications,
                  ),
                  trailing: Switch(
                    value: settings.todayNotifications,
                    onChanged: settings.setTodayNotifications,
                  ),
                ),
                SettingsRow(
                  title: 'Block reminders',
                  subtitle: '5 minutes before a block, and when it starts',
                  onTap: () =>
                      settings.setBlockReminders(!settings.blockReminders),
                  trailing: Switch(
                    value: settings.blockReminders,
                    onChanged: settings.setBlockReminders,
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: context.read<AppServices>().toSort,
                  builder: (context, n, _) => SettingsRow(
                    title: 'Learned rules',
                    subtitle: 'Apps you marked for each block',
                    value: n > 0 ? '$n to sort' : null,
                    onTap: () => _open(const RulesScreen()),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Appearance',
              children: [
                SettingsRow(
                  title: 'Theme',
                  value: settings.theme.label,
                  onTap: () => _open(const ThemePickerScreen()),
                ),
                SettingsRow(
                  title: 'App icon',
                  value: icon?.label,
                  leading: icon == null ? null : DriftIconTile(icon, 28),
                  onTap: () => _open(const IconPickerScreen()),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Goals',
              children: [
                SettingsRow(
                  title: 'Weekly target',
                  value: settings.weeklyTarget == 0
                      ? 'Off'
                      : '${settings.weeklyTarget}%',
                  onTap: () => _pickMinutes(
                    title: 'Weekly target',
                    help:
                        "The share of the week's planned time you want on "
                        'track. Today and Review show how close you are.',
                    options: const [0, 60, 70, 75, 80, 85, 90],
                    current: settings.weeklyTarget,
                    label: (p) => p == 0 ? 'Off' : '$p%',
                    onPicked: settings.setWeeklyTarget,
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Data',
              children: [
                SettingsRow(
                  title: 'App groups',
                  subtitle: 'Productive and distracting apps, picked as one',
                  onTap: () => _open(const AppGroupsScreen()),
                ),
                SettingsRow(
                  title: 'Week starts on',
                  value: settings.firstWeekday == DateTime.sunday
                      ? 'Sunday'
                      : 'Monday',
                  onTap: () => _pickMinutes(
                    title: 'Week starts on',
                    options: const [DateTime.monday, DateTime.sunday],
                    current: settings.firstWeekday,
                    label: (d) => d == DateTime.sunday ? 'Sunday' : 'Monday',
                    onPicked: settings.setFirstWeekday,
                  ),
                ),
                SettingsRow(
                  title: 'Export to CSV',
                  value: 'to Downloads',
                  onTap: _export,
                  trailing: _exporting
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: c.accent,
                          ),
                        )
                      : null,
                ),
              ],
            ),
            DriveBackupSection(service: context.read<DriveBackupService>()),
            SettingsGroup(
              title: 'Updates',
              children: [
                SettingsRow(
                  title: 'Check for updates',
                  value: _version == null ? null : versionLabel(_version!),
                  onTap: _checkForUpdates,
                  trailing: _checking
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: c.accent,
                          ),
                        )
                      : null,
                ),
                if (_installsInApp || kDebugMode)
                  SettingsRow(
                    title: 'Check on launch',
                    subtitle: 'Once a day, from GitHub releases',
                    onTap: () =>
                        settings.setUpdateOnLaunch(!settings.updateOnLaunch),
                    trailing: Switch(
                      value: settings.updateOnLaunch,
                      onChanged: settings.setUpdateOnLaunch,
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              title: 'Help',
              children: [
                SettingsRow(
                  title: 'Diagnostics',
                  subtitle: 'Copy a report to send after installing',
                  onTap: () => _open(const DiagnosticsScreen()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
