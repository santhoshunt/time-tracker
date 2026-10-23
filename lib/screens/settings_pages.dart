part of 'settings_screen.dart';

/// One Settings category on its own page: a titled app bar over the same
/// padded list as the Settings root.
class SettingsGroupPage extends StatelessWidget {
  const SettingsGroupPage({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(title),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: children,
        ),
      ),
    );
  }
}

/// A sheet of radio options; [onPicked] gets the one tapped.
Future<void> _pickOption({
  required BuildContext context,
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

/// A row that flips [value] when tapped anywhere, with the switch on the
/// right.
SettingsRow _switchRow({
  required String title,
  String? subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) => SettingsRow(
  title: title,
  subtitle: subtitle,
  onTap: () => onChanged(!value),
  trailing: Switch(value: value, onChanged: onChanged),
);

/// Live nudges, when they start and repeat, quiet hours and focus lock.
class _NudgesPage extends StatelessWidget {
  const _NudgesPage();

  /// Quiet hours option A: From and Until wheels in one sheet, the same
  /// wheels as the block editor (the Material clock dial was hard to read).
  Future<void> _pickQuietHours(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final picked = await showQuietHoursSheet(
      context,
      start: settings.quietStartMin,
      end: settings.quietEndMin,
    );
    if (picked == null) return;
    await settings.setQuietHours(picked.$1, picked.$2);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return SettingsGroupPage(
      title: 'Nudges',
      children: [
        SettingsGroup(
          title: 'When you drift from your plan',
          children: [
            _switchRow(
              title: 'Live nudges',
              subtitle: 'A nudge while you stay on an off-track app',
              value: settings.nudgesEnabled,
              onChanged: settings.setNudgesEnabled,
            ),
            if (settings.nudgesEnabled) ...[
              SettingsRow(
                title: 'First nudge after',
                value: '${settings.nudgeAfterMin} min',
                onTap: () => _pickOption(
                  context: context,
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
                onTap: () => _pickOption(
                  context: context,
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
                onTap: () => _pickQuietHours(context),
              ),
              _switchRow(
                title: 'Lock instead of nudge',
                subtitle:
                    'Apps you marked off track lock in every block. Hold '
                    '3 seconds to open one for 5 minutes.',
                value: settings.focusLock,
                onChanged: settings.setFocusLock,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// The evening summary, Today in the notification shade and block
/// reminders.
class _NotificationsPage extends StatelessWidget {
  const _NotificationsPage();

  /// The summary time, on the same wheel as the block editor. Android may
  /// deliver it a few minutes late, hence "Around" in the row.
  Future<void> _pickSummaryTime(BuildContext context) async {
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return SettingsGroupPage(
      title: 'Notifications',
      children: [
        SettingsGroup(
          title: 'What Drift tells you',
          children: [
            SettingsRow(
              title: 'Evening summary',
              subtitle: settings.summaryEnabled
                  ? 'Around ${_hm(settings.summaryMinute)}, drift per block'
                  : 'Off',
              onTap: () => _pickSummaryTime(context),
              trailing: Switch(
                value: settings.summaryEnabled,
                onChanged: settings.setSummaryEnabled,
              ),
            ),
            _switchRow(
              title: 'Today in notifications',
              subtitle:
                  'Your current block, and distracting time against all '
                  'app time',
              value: settings.todayNotifications,
              onChanged: settings.setTodayNotifications,
            ),
            _switchRow(
              title: 'Block reminders',
              subtitle: '5 minutes before a block, and when it starts',
              value: settings.blockReminders,
              onChanged: settings.setBlockReminders,
            ),
          ],
        ),
      ],
    );
  }
}

/// The weekly target and the first day of the week.
class _GoalsPage extends StatelessWidget {
  const _GoalsPage();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return SettingsGroupPage(
      title: 'Goals and week',
      children: [
        SettingsGroup(
          title: 'Goals',
          children: [
            SettingsRow(
              title: 'Weekly target',
              value: settings.weeklyTarget == 0
                  ? 'Off'
                  : '${settings.weeklyTarget}%',
              onTap: () => _pickOption(
                context: context,
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
            SettingsRow(
              title: 'Week starts on',
              value: _weekday(settings.firstWeekday),
              onTap: () => _pickOption(
                context: context,
                title: 'Week starts on',
                options: const [DateTime.monday, DateTime.sunday],
                current: settings.firstWeekday,
                label: _weekday,
                onPicked: settings.setFirstWeekday,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Theme and app icon. Each picker opens its own page.
class _AppearancePage extends StatefulWidget {
  const _AppearancePage();

  @override
  State<_AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<_AppearancePage> {
  DriftIcon? _icon;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final icon = _icon;
    return SettingsGroupPage(
      title: 'Appearance',
      children: [
        SettingsGroup(
          title: 'Look',
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
      ],
    );
  }
}

/// Google Drive backup and the CSV export.
class _BackupPage extends StatefulWidget {
  const _BackupPage({this.daysLoader});

  final DaysLoader? daysLoader;

  @override
  State<_BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<_BackupPage> {
  bool _exporting = false;

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

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return SettingsGroupPage(
      title: 'Backup and data',
      children: [
        DriveBackupSection(service: context.read<DriveBackupService>()),
        SettingsGroup(
          title: 'Data',
          children: [
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
      ],
    );
  }
}

/// The version, update checks and diagnostics.
class _AboutPage extends StatefulWidget {
  const _AboutPage({this.version, this.updateService});

  final String? version;
  final UpdateService? updateService;

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  bool _checking = false;

  bool get _installsInApp =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
    final version = widget.version;
    return SettingsGroupPage(
      title: 'About',
      children: [
        SettingsGroup(
          title: 'Updates',
          children: [
            SettingsRow(
              title: 'Check for updates',
              value: version == null ? null : versionLabel(version),
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
              _switchRow(
                title: 'Check on launch',
                subtitle: 'Once a day, from GitHub releases',
                value: settings.updateOnLaunch,
                onChanged: settings.setUpdateOnLaunch,
              ),
          ],
        ),
        SettingsGroup(
          title: 'Help',
          children: [
            SettingsRow(
              title: 'Diagnostics',
              subtitle: 'Copy a report to send after installing',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
