import 'package:flutter/foundation.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../platform/background_bridge.dart';
import '../providers/settings_provider.dart';
import '../widgets/score_card.dart' show formatMinutes;
import 'day_loader.dart';

/// Meta key holding the local day (yyyyMMdd as an int) the summary was
/// last posted for. In the database, not SharedPreferences, so the app's
/// isolate and a headless one read the same value.
const summarySentDayKey = 'summary_sent_day';

/// The notification lists at most this many blocks; a sixth line would be
/// cut off by most launchers anyway.
const summaryMaxLines = 5;

/// The evening summary for [day]: the title "Today: 74% on track, 55 min
/// drift" and one line per block that has started, "Deep work: 40 min
/// drift" or "Gym: no drift". Null when nothing was planned up to now,
/// because a score of nothing says nothing.
///
/// With more than [summaryMaxLines] blocks the ones that drifted most are
/// kept, still in plan order, since those are what the review is for.
({String title, List<String> lines})? buildSummary(DayData day) {
  final score = day.score;
  if (score == null) return null;
  final drift = score.offMin == 0 ? 'no drift' : '${formatMinutes(score.offMin)} drift';
  final title = 'Today: ${score.percent}% on track, $drift';

  final nowMs = day.now.millisecondsSinceEpoch;
  // Block names in plan order, once each: a name used twice (two Meetings)
  // is one line, as Review groups it.
  final names = <String>[];
  for (final b in [...day.blocks]..sort((a, b) => a.start.compareTo(b.start))) {
    if (!b.start.isBefore(day.now)) continue;
    if (!names.contains(b.name)) names.add(b.name);
  }
  // Summed in milliseconds and rounded once, as scoreDay does, so the
  // lines add up to the title.
  final offMs = <String, int>{};
  for (final s in day.segments) {
    final name = s.blockName;
    if (name == null) continue;
    if (s.verdict != Verdict.offTrack && s.verdict != Verdict.guessedOff) continue;
    final end = s.end.millisecondsSinceEpoch < nowMs ? s.end.millisecondsSinceEpoch : nowMs;
    final ms = end - s.start.millisecondsSinceEpoch;
    if (ms > 0) offMs[name] = (offMs[name] ?? 0) + ms;
  }
  int minutesOf(String name) =>
      ((offMs[name] ?? 0) / Duration.millisecondsPerMinute).round();

  var shown = names;
  if (names.length > summaryMaxLines) {
    final ranked = [...names]..sort((a, b) {
      final byDrift = minutesOf(b).compareTo(minutesOf(a));
      return byDrift != 0 ? byDrift : names.indexOf(a).compareTo(names.indexOf(b));
    });
    final keep = ranked.take(summaryMaxLines).toSet();
    shown = [for (final n in names) if (keep.contains(n)) n];
  }
  final lines = [
    for (final name in shown)
      minutesOf(name) == 0
          ? '$name: no drift'
          : '$name: ${formatMinutes(minutesOf(name))} drift',
  ];
  return (title: title, lines: lines);
}

/// The next summary moment after [now]: today at [minuteOfDay] when that
/// is still ahead, otherwise tomorrow. Built from calendar fields, never by
/// adding 24 hours, so it stays on the wall-clock minute across a daylight
/// saving change.
DateTime nextSummaryTime(DateTime now, int minuteOfDay) {
  final today = _summaryOn(now, minuteOfDay);
  if (today.isAfter(now)) return today;
  return DateTime(now.year, now.month, now.day + 1, minuteOfDay ~/ 60, minuteOfDay % 60);
}

DateTime _summaryOn(DateTime day, int minuteOfDay) =>
    DateTime(day.year, day.month, day.day, minuteOfDay ~/ 60, minuteOfDay % 60);

/// What a summary tap carries: Review opens on [day].
String summaryPayload(DateTime day) => 'review:${dateKey(day)}';

/// The day a summary tap asked for, or null for any other payload.
DateTime? reviewDayOf(String? payload) {
  if (payload == null || !payload.startsWith('review:')) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(payload.substring(7));
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

int _dayNumber(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

/// Posts today's summary when it is due: switched on, at or past today's
/// summary minute, and not yet posted today. A run after midnight is a new
/// day whose summary is not due yet, so a missed evening is skipped rather
/// than posted the next morning.
///
/// The day is marked only after Android showed the notification, so a run
/// killed half-way, or one without the notification permission, leaves
/// the next run to try again. True when it posted.
Future<bool> maybePostSummary(
  AppServices s,
  SettingsProvider settings, {
  BackgroundBridge? bridge,
}) async {
  if (!settings.summaryEnabled) return false;
  final now = s.clock.now();
  if (now.isBefore(_summaryOn(now, settings.summaryMinute))) return false;
  final today = _dayNumber(now);
  if (await s.meta.getInt(summarySentDayKey) == today) return false;

  final day = await loadDay(s, now);
  final summary = buildSummary(day);
  if (summary == null) return false;
  final posted = await (bridge ?? BackgroundBridge.instance).postSummary(
    title: summary.title,
    lines: summary.lines,
    payload: summaryPayload(day.day),
  );
  if (posted) await s.meta.setInt(summarySentDayKey, today);
  return posted;
}

/// Books the next summary at the chosen minute, or cancels it when the
/// summary is off. Safe to repeat: the booking replaces the last one. Run
/// on every background run, on app start and when the setting changes.
Future<void> bookNextSummary(
  AppServices s,
  SettingsProvider settings, {
  BackgroundBridge? bridge,
}) async {
  final b = bridge ?? BackgroundBridge.instance;
  try {
    if (!settings.summaryEnabled) {
      await b.cancelSummary();
      return;
    }
    await b.scheduleSummary(nextSummaryTime(s.clock.now(), settings.summaryMinute));
  } catch (e) {
    debugPrint('Summary booking failed: $e');
  }
}
