import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../icons/drift_icons.dart';
import '../providers/settings_provider.dart';
import '../services/update_service.dart';
import '../theme/drift_theme.dart';
import '../widgets/settings_group.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/update_sheet.dart';
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
  const SettingsScreen({super.key, this.updateService, this.packageInfo});

  /// Tests inject a service with a fake HTTP client.
  final UpdateService? updateService;
  final Future<PackageInfo> Function()? packageInfo;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _checking = false;
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

  Future<void> _pickQuietHours() async {
    final settings = context.read<SettingsProvider>();
    TimeOfDay at(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60);
    Future<TimeOfDay?> pick(String help, int m) => showTimePicker(
      context: context,
      helpText: help,
      initialTime: at(m),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    final start = await pick('Quiet from', settings.quietStartMin);
    if (start == null || !mounted) return;
    final end = await pick('Quiet until', settings.quietEndMin);
    if (end == null) return;
    await settings.setQuietHours(
      start.hour * 60 + start.minute,
      end.hour * 60 + end.minute,
    );
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
              title: 'Nudges',
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
                    title: 'Nudge after',
                    value: '${settings.nudgeAfterMin} min',
                    onTap: () => _pickMinutes(
                      title: 'Nudge after this much drift',
                      options: const [2, 5, 10, 15, 30],
                      current: settings.nudgeAfterMin,
                      label: (m) => '$m min',
                      onPicked: settings.setNudgeAfterMin,
                    ),
                  ),
                  SettingsRow(
                    title: 'Repeat at most',
                    value: 'every ${settings.nudgeRepeatMin} min',
                    onTap: () => _pickMinutes(
                      title: 'Nudge again at most every',
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
                ],
                SettingsRow(
                  title: 'Learned rules',
                  subtitle: 'Apps you marked for each block',
                  onTap: () => _open(const RulesScreen()),
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
