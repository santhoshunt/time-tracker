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
import 'theme_picker_screen.dart';

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
