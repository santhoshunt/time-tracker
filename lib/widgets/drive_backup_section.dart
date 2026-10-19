import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../providers/settings_provider.dart';
import '../services/backup_codec.dart';
import '../services/drive_backup_service.dart';
import '../theme/drift_theme.dart';
import 'settings_group.dart';
import 'undo_snackbar.dart';

/// The Settings "Backup" group, option A: Google Drive, Back up now,
/// Automatic backup, Restore from Drive and Disconnect, with a banner
/// when the last backup failed.
///
/// Reads [AppServices] and [SettingsProvider] from the tree. Scheduled
/// uploads run silently from app start and resume, so the one thing this
/// group must never hide is a recorded failure.
class DriveBackupSection extends StatefulWidget {
  const DriveBackupSection({super.key, required this.service});

  /// The app's one service, shared with the scheduled check so a tap and a
  /// scheduled upload join each other.
  final DriveBackupService service;

  @override
  State<DriveBackupSection> createState() => _DriveBackupSectionState();
}

class _DriveBackupSectionState extends State<DriveBackupSection> {
  bool _loading = true;
  String? _email;
  String _freq = 'daily';
  DateTime? _lastBackup;
  String? _lastError;
  bool _uploading = false;
  bool _restoring = false;

  /// Why the last tap on Connect failed, shown under the Connect row.
  String? _connectError;
  Timer? _clockTick;

  DriveBackupService get _svc => widget.service;

  @override
  void initState() {
    super.initState();
    _load();
    // "Last backup: Just now" goes stale while Settings stays open.
    _clockTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    String? email;
    try {
      email = await _svc.connectedEmail();
    } catch (_) {
      email = null;
    }
    final freq = await _svc.getFrequency();
    final last = await _svc.lastBackupAt();
    final error = await _svc.lastError();
    if (!mounted) return;
    setState(() {
      _email = email;
      _freq = freq;
      _lastBackup = last;
      _lastError = error;
      _loading = false;
    });
  }

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _svc.connect();
      _connectError = null;
    } on DriveAuthException catch (e) {
      // Kept under the Connect row too: "isn't set up for this build"
      // must outlast a toast.
      if (mounted) setState(() => _connectError = e.message);
      showAppToastOn(
        messenger,
        e.message,
        tone: AppToastTone.error,
        duration: const Duration(seconds: 5),
      );
      return;
    } catch (e) {
      debugPrint('Drive connect failed: $e');
      showAppToastOn(
        messenger,
        "Couldn't connect Google Drive. Try again.",
        tone: AppToastTone.error,
      );
      return;
    }
    // Last backup and error are account-scoped: read them all again.
    if (mounted) await _load();
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Google Drive?'),
        content: const Text(
          'Backups from this phone stop. Backups already in your Drive stay '
          'there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _svc.disconnect();
    if (mounted) await _load();
  }

  Future<void> _backupNow() async {
    if (_uploading || _restoring) return;
    final messenger = ScaffoldMessenger.of(context);
    final services = context.read<AppServices>();
    final settings = context.read<SettingsProvider>();
    setState(() => _uploading = true);
    try {
      await _svc.uploadNow(services, settings, interactive: true);
      final last = await _svc.lastBackupAt();
      if (mounted) {
        setState(() {
          _lastBackup = last;
          _lastError = null;
        });
      }
      showAppToastOn(
        messenger,
        'Saved to Drive',
        tone: AppToastTone.success,
        icon: Icons.cloud_done_outlined,
      );
    } catch (e) {
      // uploadNow recorded the failure too; mirror it so the banner shows
      // without leaving Settings. Offline gets the toast only.
      if (mounted && e is! DriveOfflineException) {
        setState(() => _lastError = '$e');
      }
      showAppToastOn(
        messenger,
        'Drive backup failed: $e',
        tone: AppToastTone.error,
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickFrequency() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: RadioGroup<String>(
          groupValue: _freq,
          onChanged: (v) => Navigator.pop(context, v),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'Automatic backup',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'Checked when Drift opens or comes back to the front. '
                    'Daily waits at least 23 hours, weekly 6 days.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.drift.textSecondary,
                    ),
                  ),
                ),
                for (final f in DriveBackupService.frequencies)
                  RadioListTile<String>(
                    value: f,
                    title: Text(DriveBackupService.freqLabel(f)),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _freq = picked);
    await _svc.setFrequency(picked);
  }

  Future<void> _restore() async {
    if (_uploading || _restoring) return;
    final messenger = ScaffoldMessenger.of(context);
    final services = context.read<AppServices>();
    final settings = context.read<SettingsProvider>();
    setState(() => _restoring = true);
    try {
      // Downloaded first, so the confirmation can name the backup's date.
      final backup = await _svc.downloadLatest(interactive: true);
      if (!mounted) return;
      // No spinner behind the question; it comes back for the import.
      setState(() => _restoring = false);
      final when = DriveBackupService.formatBackupDate(backup.createdAt);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore from Drive?'),
          content: Text(
            'Replace everything on this phone with the backup from $when? '
            "This can't be undone.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      setState(() => _restoring = true);
      await _svc.restore(backup, services, settings);
      // Fills in the days since the backup from this phone's own history.
      unawaited(services.ingest());
      showAppToastOn(
        messenger,
        'Restored the backup from $when',
        tone: AppToastTone.success,
        icon: Icons.cloud_download_outlined,
      );
    } on DriveAuthException catch (e) {
      showAppToastOn(messenger, e.message, tone: AppToastTone.error);
    } on DriveOfflineException catch (e) {
      showAppToastOn(messenger, e.message, tone: AppToastTone.error);
    } on BackupFormatException catch (e) {
      showAppToastOn(
        messenger,
        'Restore failed: ${e.message}',
        tone: AppToastTone.error,
      );
    } on FormatException catch (e) {
      showAppToastOn(
        messenger,
        'Restore failed: ${e.message}',
        tone: AppToastTone.error,
      );
    } catch (e) {
      debugPrint('Drive restore failed: $e');
      showAppToastOn(
        messenger,
        "Restore failed. Nothing on this phone was changed.",
        tone: AppToastTone.error,
      );
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    if (_loading) {
      return const SettingsGroup(
        title: 'Backup',
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        ],
      );
    }
    Widget spinner() => const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2.5),
    );
    final email = _email;
    return SettingsGroup(
      title: 'Backup',
      children: [
        if (_lastError != null) _ErrorBanner(
          message: _lastError!,
          onReconnect: _lastError == kDriveReconnectMessage ? _connect : null,
        ),
        if (email == null)
          SettingsRow(
            leading: Icon(Icons.cloud_off_outlined, color: c.textSecondary),
            title: 'Connect Google Drive',
            subtitle:
                _connectError ?? 'Off until connected. Nothing is uploaded.',
            onTap: _connect,
          )
        else ...[
          SettingsRow(
            leading: Icon(Icons.cloud_done_outlined, color: c.accent),
            title: 'Google Drive',
            subtitle: email,
          ),
          SettingsRow(
            leading: Icon(Icons.cloud_upload_outlined, color: c.textSecondary),
            title: 'Back up now',
            subtitle:
                'Last backup: ${DriveBackupService.formatLastBackup(_lastBackup)}',
            trailing: _uploading ? spinner() : null,
            onTap: _uploading ? null : _backupNow,
          ),
          SettingsRow(
            leading: Icon(Icons.schedule_outlined, color: c.textSecondary),
            title: 'Automatic backup',
            value: DriveBackupService.freqLabel(_freq),
            onTap: _pickFrequency,
          ),
          SettingsRow(
            leading: Icon(
              Icons.cloud_download_outlined,
              color: c.textSecondary,
            ),
            title: 'Restore from Drive',
            subtitle: 'Replaces everything on this phone',
            trailing: _restoring ? spinner() : null,
            onTap: _restoring ? null : _restore,
          ),
          SettingsRow(
            leading: Icon(Icons.link_off, color: c.textSecondary),
            title: 'Disconnect',
            onTap: _disconnect,
          ),
        ],
      ],
    );
  }
}

/// The failure banner: a coloured outline and icon carry the warning; the
/// text stays in the theme's text colour, never on a coloured fill.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.onReconnect});

  final String message;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.offTrack.withValues(alpha: 0.7)),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 18, color: c.offTrack),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message == kDriveReconnectMessage
                    ? message
                    : 'The last Drive backup failed: $message',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: c.text),
              ),
            ),
            if (onReconnect != null)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.accent),
                onPressed: onReconnect,
                child: const Text('Reconnect'),
              ),
          ],
        ),
      ),
    );
  }
}
