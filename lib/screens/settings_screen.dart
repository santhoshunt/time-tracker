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

part 'settings_pages.dart';

/// "22:00 to 07:00", or "Off" when start and end are the same.
String quietHoursLabel(int start, int end) {
  if (start == end) return 'Off';
  return '${_hm(start)} to ${_hm(end)}';
}

String _hm(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

/// Settings option B: Learned rules and App groups on top under Apps, with
/// the to-sort badge on Learned rules; every other setting sits on a
/// category page (settings_pages.dart) whose row sums it up.
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
  late final AppServices _services = context.read<AppServices>();
  String? _version;
  DriftIcon? _icon;
  int? _groups;

  @override
  void initState() {
    super.initState();
    (widget.packageInfo ?? PackageInfo.fromPlatform)().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
    // A group made from the block editor on Plan changes the count too.
    _services.revision.addListener(_loadSummaries);
    _loadSummaries();
  }

  @override
  void dispose() {
    _services.revision.removeListener(_loadSummaries);
    super.dispose();
  }

  /// The icon and the group count the rows show, read again after every
  /// page closes and every revision.
  Future<void> _loadSummaries() async {
    final alias = await _services.icons.current();
    final groups = await _services.groups.all();
    if (mounted) {
      setState(() {
        _icon = DriftIcon.fromAlias(alias);
        _groups = groups.length;
      });
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _loadSummaries();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final c = context.drift;
    final groups = _groups;
    final version = _version;

    Widget category(IconData icon, String title, String summary, Widget page) =>
        SettingsRow(
          leading: Icon(icon, color: c.textSecondary),
          title: title,
          subtitle: summary,
          onTap: () => _open(page),
        );

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
            SettingsGroup(
              title: 'Apps',
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: _services.toSort,
                  builder: (context, n, _) => SettingsRow(
                    leading: Icon(Icons.rule, color: c.textSecondary),
                    title: 'Learned rules',
                    subtitle: 'Apps you marked for each block',
                    badge: n,
                    onTap: () => _open(const RulesScreen()),
                  ),
                ),
                SettingsRow(
                  leading: Icon(Icons.apps, color: c.textSecondary),
                  title: 'App groups',
                  subtitle: switch (groups) {
                    null || 0 => 'Productive and distracting apps, picked as one',
                    1 => '1 group',
                    _ => '$groups groups',
                  },
                  onTap: () => _open(const AppGroupsScreen()),
                ),
              ],
            ),
            SettingsGroup(
              title: 'More',
              children: [
                category(
                  Icons.notifications_active_outlined,
                  'Nudges',
                  settings.nudgesEnabled
                      ? 'On, first after ${settings.nudgeAfterMin} min'
                      : 'Off',
                  const _NudgesPage(),
                ),
                category(
                  Icons.message_outlined,
                  'Notifications',
                  _notificationsSummary(settings),
                  const _NotificationsPage(),
                ),
                category(
                  Icons.flag_outlined,
                  'Goals and week',
                  '${settings.weeklyTarget == 0 ? 'No weekly target' : '${settings.weeklyTarget}% weekly target'}'
                      ' · starts ${_weekday(settings.firstWeekday)}',
                  const _GoalsPage(),
                ),
                category(
                  Icons.palette_outlined,
                  'Appearance',
                  [settings.theme.label, if (_icon != null) _icon!.label]
                      .join(' · '),
                  const _AppearancePage(),
                ),
                category(
                  Icons.cloud_outlined,
                  'Backup and data',
                  'Google Drive backup, CSV export',
                  _BackupPage(daysLoader: widget.daysLoader),
                ),
                category(
                  Icons.info_outline,
                  'About',
                  version == null
                      ? 'Updates and diagnostics'
                      : '${versionLabel(version)} · updates and diagnostics',
                  _AboutPage(
                    version: version,
                    updateService: widget.updateService,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _notificationsSummary(SettingsProvider s) {
    final on = [
      if (s.summaryEnabled) 'Summary around ${_hm(s.summaryMinute)}',
      if (s.todayNotifications) 'Today',
      if (s.blockReminders) 'Block reminders',
    ];
    return on.isEmpty ? 'All off' : on.join(' · ');
  }
}

String _weekday(int d) => d == DateTime.sunday ? 'Sunday' : 'Monday';
