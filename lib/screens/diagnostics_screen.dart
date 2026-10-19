import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/ingestor.dart';
import '../domain/plan_resolver.dart';
import '../providers/settings_provider.dart';
import '../theme/drift_theme.dart';
import '../widgets/undo_snackbar.dart';

/// One line of the report: a label, a value and whether it looks healthy
/// (null when there is no right or wrong, such as a count).
typedef DiagnosticLine = ({String key, String label, String value, bool? ok});

/// Collects what is needed to tell, without a USB cable, whether Drift is
/// working on the phone: permissions, the background saver and how much
/// data arrived.
Future<List<DiagnosticLine>> collectDiagnostics(
  AppServices s,
  SettingsProvider settings, {
  Future<PackageInfo> Function()? packageInfo,
}) async {
  final now = s.clock.now();
  final today = DayFrame.local(now);
  final info = await (packageInfo ?? PackageInfo.fromPlatform)();
  final usage = await s.usage.hasUsageAccess();
  final battery = await s.usage.isIgnoringBatteryOptimizations();
  final native = await s.usage.diagnostics();
  final workerMs = native['workerLastRunMs'] as int?;
  final bufferFiles = native['bufferFiles'] as int? ?? 0;
  final cursorMs = await s.meta.getInt(Ingestor.cursorKey);
  final notifications = await s.nudges.hasNotificationPermission();
  final overlay = await s.nudges.canDrawOverlays();
  final service = await s.nudges.serviceStatus();
  final running = service['running'] == true;
  final tickMs = service['lastTickMs'] as int?;
  final nudgeMs = service['lastNudgeMs'] as int?;
  final serviceError = service['lastError'] as String?;
  final events24h = await s.events.between(
    now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch,
    now.millisecondsSinceEpoch,
  );
  final sessionsToday = await s.sessions.sessionsBetween(today.start, today.end);
  final gaps = await s.sessions.gapsBetween(
    now.subtract(const Duration(days: 7)),
    now,
  );

  String ago(int? ms) {
    if (ms == null) return 'never';
    final d = now.difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 48) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  final workerAge = workerMs == null
      ? null
      : now.difference(DateTime.fromMillisecondsSinceEpoch(workerMs));
  return [
    (key: 'usage_access', label: 'Usage access', value: usage ? 'On' : 'Off', ok: usage),
    (
      key: 'battery_exempt',
      label: 'Battery limit',
      value: battery ? 'None' : 'Restricted',
      ok: battery,
    ),
    (
      key: 'worker_last_run',
      label: 'Hourly saver',
      value: ago(workerMs),
      ok: workerAge != null && workerAge < const Duration(hours: 3),
    ),
    (key: 'buffer_files', label: 'Files waiting', value: '$bufferFiles', ok: null),
    (
      key: 'background_run',
      label: 'Background update',
      value: native['backgroundLastRunMs'] == null
          ? 'never'
          : '${ago(native['backgroundLastRunMs'] as int?)}'
                '${native['backgroundLastOk'] == false ? ', failed' : ''}',
      ok: native['backgroundLastRunMs'] == null
          ? null
          : native['backgroundLastOk'] != false,
    ),
    if (native['backgroundLastError'] is String)
      (
        key: 'background_error',
        label: 'Background error',
        value: native['backgroundLastError'] as String,
        ok: false,
      ),
    (
      key: 'notifications',
      label: 'Notifications',
      value: notifications ? 'Allowed' : 'Off',
      ok: settings.nudgesEnabled ? notifications : null,
    ),
    (
      key: 'overlay',
      label: 'Display over apps',
      value: overlay ? 'Allowed' : 'Off',
      ok: settings.nudgesEnabled ? overlay : null,
    ),
    (
      key: 'nudge_service',
      label: 'Nudge service',
      value: !settings.nudgesEnabled
          ? 'Switched off'
          : running
          ? 'Running, checked ${ago(tickMs)}'
          : 'Not running',
      ok: settings.nudgesEnabled ? running : null,
    ),
    (key: 'last_nudge', label: 'Last nudge', value: ago(nudgeMs), ok: null),
    if (serviceError != null)
      (key: 'service_error', label: 'Service error', value: serviceError, ok: false),
    (key: 'last_ingest', label: 'Last read', value: ago(cursorMs), ok: null),
    (key: 'events_24h', label: 'Events, last 24 h', value: '${events24h.length}', ok: null),
    (key: 'sessions_today', label: 'Sessions today', value: '${sessionsToday.length}', ok: null),
    (key: 'gaps_7d', label: 'No-data gaps, 7 days', value: '${gaps.length}', ok: gaps.isEmpty),
    (key: 'theme', label: 'Theme', value: settings.theme.label, ok: null),
    (
      key: 'last_in_app_update',
      label: 'Last in-app update',
      value: settings.lastUpdateVersion == null
          ? 'none yet'
          : 'v${settings.lastUpdateVersion}, ${ago(settings.lastUpdateAt?.millisecondsSinceEpoch)}',
      ok: null,
    ),
    (
      key: 'version',
      label: 'Version',
      value: '${info.version} (${info.buildNumber})',
      ok: null,
    ),
  ];
}

/// The report Sandy pastes back: one `key: value` line each.
String diagnosticsReport(List<DiagnosticLine> lines) =>
    ['Drift diagnostics', for (final l in lines) '${l.key}: ${l.value}'].join('\n');

/// Diagnostics option A: status rows with coloured dots and a "Copy
/// report" button pinned at the bottom.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, this.packageInfo});

  /// Tests pass a fixed version; the app reads the installed one.
  final Future<PackageInfo> Function()? packageInfo;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<DiagnosticLine>? _lines;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = await collectDiagnostics(
      context.read<AppServices>(),
      context.read<SettingsProvider>(),
      packageInfo: widget.packageInfo,
    );
    if (mounted) setState(() => _lines = lines);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final lines = _lines;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: lines == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < lines.length; i++) ...[
                        if (i > 0) Divider(height: 1, indent: 16, color: c.line),
                        _Line(line: lines[i]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton.icon(
          onPressed: lines == null
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(
                    ClipboardData(text: diagnosticsReport(lines)),
                  );
                  showAppToastOn(
                    messenger,
                    'Report copied',
                    tone: AppToastTone.success,
                    icon: Icons.content_copy,
                  );
                },
          icon: const Icon(Icons.content_copy, size: 18),
          label: const Text('Copy report'),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line});

  final DiagnosticLine line;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final ok = line.ok;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          if (ok != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ok ? c.onTrack : c.offTrack,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(line.label, style: text.bodyLarge)),
          Text(
            line.value,
            style: text.bodyMedium?.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}
