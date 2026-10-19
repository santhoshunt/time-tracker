import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_services.dart';
import '../platform/background_bridge.dart';
import '../providers/settings_provider.dart';
import '../theme/drift_theme.dart';
// drawnLanePieces is marked @visibleForTesting in its own file; the
// widgets need the very same merge the Today lane draws, so it is reused
// here rather than copied.
// ignore: invalid_use_of_visible_for_testing_member
import '../widgets/timeline_lanes.dart' show drawnLanePieces;
import 'day_loader.dart';

/// The file the home-screen widgets read (DriftWidgets.kt), in filesDir.
const widgetSnapshotFile = 'widget_snapshot.json';

/// `#RRGGBB`, the form Kotlin's Color.parseColor reads.
String hexColor(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// What the widgets draw for [day], version 1.
///
/// Times are epoch milliseconds, so Kotlin works out the current block and
/// the time left at render time; a widget redrawn 30 minutes later is
/// still right without Dart. Lane pieces come pre-merged through
/// [drawnLanePieces], so the widget strip matches the Today lane.
Map<String, Object?> buildWidgetSnapshot(DayData day, DriftColors c) {
  final score = day.score;
  return {
    'v': 1,
    'computedAtMs': day.now.millisecondsSinceEpoch,
    'dayStartMs': day.day.millisecondsSinceEpoch,
    'blocks': [
      for (final b in day.blocks)
        {
          'name': b.name,
          'startMs': b.start.millisecondsSinceEpoch,
          'endMs': b.end.millisecondsSinceEpoch,
        },
    ],
    'pieces': [
      // ignore: invalid_use_of_visible_for_testing_member
      for (final piece in drawnLanePieces(day.segments))
        {
          'startMs': piece.start.millisecondsSinceEpoch,
          'endMs': piece.end.millisecondsSinceEpoch,
          'verdict': piece.verdict.name,
        },
    ],
    'percent': score?.percent,
    'driftMin': score?.offMin ?? 0,
    'plannedMin': score?.plannedMin ?? 0,
    'colors': {
      'bg': hexColor(c.bg),
      'card': hexColor(c.card),
      'line': hexColor(c.line),
      'text': hexColor(c.text),
      'textSecondary': hexColor(c.textSecondary),
      'accent': hexColor(c.accent),
      'onTrack': hexColor(c.onTrack),
      'offTrack': hexColor(c.offTrack),
      'guessed': hexColor(c.guessed),
    },
  };
}

/// Writes today's snapshot (to a temporary file, then renamed, so a
/// widget never reads half a file) and asks the widgets to redraw.
/// Failures are logged: the widgets keep the previous snapshot until the
/// next write. True when the file was written.
Future<bool> writeWidgetSnapshot(
  AppServices s,
  SettingsProvider settings, {
  Future<Directory> Function()? directory,
  BackgroundBridge? bridge,
}) async {
  try {
    final day = await loadDay(s, s.clock.now());
    final snapshot = buildWidgetSnapshot(day, DriftColors.of(settings.theme));
    final dir = await (directory ?? getApplicationSupportDirectory)();
    final target = File(p.join(dir.path, widgetSnapshotFile));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(snapshot), flush: true);
    await tmp.rename(target.path);
  } catch (e, st) {
    debugPrint('Widget snapshot failed: $e\n$st');
    return false;
  }
  await (bridge ?? BackgroundBridge.instance).refreshWidgets();
  return true;
}
