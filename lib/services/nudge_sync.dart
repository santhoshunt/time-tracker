import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_services.dart';
import '../domain/nudge_snapshot.dart';
import '../domain/plan_resolver.dart';
import '../providers/settings_provider.dart';
import '../theme/drift_theme.dart';

/// The file the Android nudge service reads (NudgeService.kt).
const nudgeSnapshotFile = 'nudge_snapshot.json';

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The snapshot for the rest of today and all of tomorrow, from the live
/// plan, the learned rules and the nudge settings.
Future<NudgeSnapshot> buildNudgeSnapshot(
  AppServices s,
  SettingsProvider settings,
  DriftColors colors,
) async {
  final now = s.clock.now();
  final today = DayFrame.local(now);
  final all = await s.plans.allBlocks();
  final blocks = [
    ...resolvePlan(today.start, all),
    ...resolvePlan(today.end, all),
  ];
  final rules = await s.rules.allRules();
  final (offApps, onApps) = distractingRuleSets(rules);
  return NudgeSnapshot(
    writtenAtMs: now.millisecondsSinceEpoch,
    enabled: settings.nudgesEnabled,
    nudgeAfterMin: settings.nudgeAfterMin,
    repeatMin: settings.nudgeRepeatMin,
    quietStartMin: settings.quietStartMin,
    quietEndMin: settings.quietEndMin,
    lock: settings.focusLock,
    status: settings.todayNotifications,
    reminders: settings.blockReminders,
    offApps: offApps,
    onApps: onApps,
    windows: nudgeWindows(blocks: blocks, rules: rules, now: now),
    colors: {
      'bg': _hex(colors.bg),
      'card': _hex(colors.card),
      'text': _hex(colors.text),
      'textSecondary': _hex(colors.textSecondary),
      'accent': _hex(colors.accent),
      'onAccent': _hex(colors.onAccent),
      'offTrack': _hex(colors.offTrack),
    },
  );
}

/// Writes the snapshot (to a temporary file, then renamed, so the service
/// never reads half a file) and starts or stops the service to match the
/// settings. Failures are logged: a missed sync only means the service
/// works from the previous snapshot until the next one.
///
/// [startService] false writes the snapshot only, for background runs
/// (lib/background.dart): Android 12+ refuses a foreground-service start
/// from the background, and a stop there would undo the user's choice.
/// The app's own isolate starts and stops the service.
Future<void> syncNudges(
  AppServices s,
  SettingsProvider settings,
  DriftColors colors, {
  Future<Directory> Function()? directory,
  bool startService = true,
}) async {
  try {
    final snapshot = await buildNudgeSnapshot(s, settings, colors);
    final dir = await (directory ?? getApplicationSupportDirectory)();
    final target = File(p.join(dir.path, nudgeSnapshotFile));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    await tmp.rename(target.path);

    if (!startService) return;
    // The service draws the Today notifications and books the reminders
    // too, so any of the three keeps it running.
    final wanted = settings.nudgesEnabled ||
        settings.todayNotifications ||
        settings.blockReminders;
    if (wanted && await s.usage.hasUsageAccess()) {
      await s.nudges.startService();
    } else {
      await s.nudges.stopService();
    }
  } catch (e, st) {
    debugPrint('Nudge sync failed: $e\n$st');
  }
}
