import 'package:flutter/material.dart' show DateTimeRange;

import '../domain/models.dart';
import 'day_loader.dart';

/// The four Review periods, in tab order.
enum ReviewPeriod { day, week, month, year }

/// A day's share of the score, as the Review charts need it.
class DayPoint {
  const DayPoint({
    required this.day,
    required this.percent,
    required this.plannedMin,
    required this.fullPlannedMin,
    required this.onMin,
    required this.idleMin,
    required this.offMin,
    required this.noDataMin,
  });

  /// Local midnight.
  final DateTime day;

  /// The day's score, null when nothing known was planned up to now.
  final int? percent;

  /// Block time up to now.
  final int plannedMin;

  /// Block time over the whole day, including what is still ahead.
  final int fullPlannedMin;

  /// On-track time inside blocks (answered and guessed), idle excluded.
  final int onMin;

  /// Idle time inside blocks; counts as on track.
  final int idleMin;

  /// Off-track and guessed-off time inside blocks.
  final int offMin;

  /// Time inside blocks with no data.
  final int noDataMin;

  /// Whether any block is planned on this day.
  bool get hasPlan => fullPlannedMin > 0;
}

/// Totals for a run of days: the minute-weighted score, the worst day,
/// the best streak and where the drift went.
class PeriodSummary {
  const PeriodSummary({
    required this.days,
    required this.plannedMin,
    required this.offMin,
    required this.idleMin,
    required this.noDataMin,
    required this.percent,
    required this.topDrift,
    required this.driftByBlock,
    required this.worstDay,
    required this.bestDay,
    required this.bestStreak,
    required this.labels,
  });

  /// One point per day, oldest first.
  final List<DayPoint> days;

  final int plannedMin;
  final int offMin;
  final int idleMin;
  final int noDataMin;

  /// round(100 x (planned - noData - off) / (planned - noData)) over all
  /// days, so a long day weighs more than a short one. Null when nothing
  /// known was planned.
  final int? percent;

  /// Off-track minutes per package across all days, largest first.
  final List<(String, int)> topDrift;

  /// Off-track minutes per block name across all days, largest first.
  final List<(String, int)> driftByBlock;

  /// The lowest-scoring day with a score; the earliest on a tie.
  final DayPoint? worstDay;

  /// The highest-scoring day with a score; the earliest on a tie.
  final DayPoint? bestDay;

  /// The most scored days in a row at 75% or more. Days without a score
  /// (nothing planned, no data, still ahead) neither extend nor break a
  /// streak, so a weekend off does not end a good week.
  final int bestStreak;

  /// Package to app name for every package in [topDrift].
  final Map<String, String> labels;

  /// Per-day scores, oldest first.
  List<int?> get dayScores => [for (final d in days) d.percent];

  /// Whether any day in the period has a block.
  bool get hasPlan => days.any((d) => d.hasPlan);

  String labelOf(String p) => labels[p] ?? p;
}

/// The score a day or period needs to count as a good one.
const goodPercent = 75;

/// The score below which a day or period counts as a poor one.
const fairPercent = 60;

/// Sums [days] into a [PeriodSummary].
PeriodSummary summarize(List<DayData> days) {
  var planned = 0, off = 0, idle = 0, noData = 0;
  final drift = <String, int>{};
  final byBlock = <String, int>{};
  final labels = <String, String>{};
  final points = <DayPoint>[];

  for (final d in days) {
    final s = d.score;
    if (s != null) {
      planned += s.plannedMin;
      off += s.offMin;
      idle += s.idleMin;
      noData += s.noDataMin;
    }
    for (final (p, m) in d.topDrift) {
      drift[p] = (drift[p] ?? 0) + m;
      labels[p] = d.labelOf(p);
    }
    for (final seg in d.segments) {
      final name = seg.blockName;
      if (name == null) continue;
      if (seg.verdict != Verdict.offTrack && seg.verdict != Verdict.guessedOff) {
        continue;
      }
      byBlock[name] = (byBlock[name] ?? 0) + seg.duration.inMinutes;
    }
    points.add(DayPoint(
      day: d.day,
      percent: s?.percent,
      plannedMin: s?.plannedMin ?? 0,
      fullPlannedMin: _unionMinutes(d.blocks),
      onMin: s == null
          ? 0
          : (s.plannedMin - s.offMin - s.idleMin - s.noDataMin).clamp(0, s.plannedMin),
      idleMin: s?.idleMin ?? 0,
      offMin: s?.offMin ?? 0,
      noDataMin: s?.noDataMin ?? 0,
    ));
  }

  final known = planned - noData;
  final percent =
      known <= 0 ? null : (100 * (known - off) / known).round().clamp(0, 100);

  DayPoint? worst, best;
  var streak = 0, bestStreak = 0;
  for (final p in points) {
    final v = p.percent;
    if (v == null) continue;
    if (worst == null || v < worst.percent!) worst = p;
    if (best == null || v > best.percent!) best = p;
    streak = v >= goodPercent ? streak + 1 : 0;
    if (streak > bestStreak) bestStreak = streak;
  }

  List<(String, int)> sorted(Map<String, int> m) => [
        for (final e in m.entries)
          if (e.value > 0) (e.key, e.value),
      ]..sort((a, b) {
          final byMin = b.$2.compareTo(a.$2);
          return byMin != 0 ? byMin : a.$1.compareTo(b.$1);
        });

  return PeriodSummary(
    days: points,
    plannedMin: planned,
    offMin: off,
    idleMin: idle,
    noDataMin: noData,
    percent: percent,
    topDrift: sorted(drift),
    driftByBlock: sorted(byBlock),
    worstDay: worst,
    bestDay: best,
    bestStreak: bestStreak,
    labels: labels,
  );
}

/// Good days in a row up to [today], from [points] oldest first.
///
/// Counts back from the newest scored day on or before [today]. Days with
/// no score are skipped, as in [PeriodSummary.bestStreak], and today only
/// adds to the run once it scores [goodPercent] or more: a day still in
/// progress never breaks a streak the earlier days built.
int currentStreak(List<DayPoint> points, DateTime today) {
  var streak = 0;
  for (final p in points.reversed) {
    if (p.day.isAfter(today)) continue;
    final v = p.percent;
    if (v == null) continue;
    if (v >= goodPercent) {
      streak++;
    } else if (p.day == today) {
      continue;
    } else {
      break;
    }
  }
  return streak;
}

/// [now]'s score minus [previous]'s, or null when either has no score.
int? deltaPercent(PeriodSummary now, PeriodSummary previous) {
  final a = now.percent, b = previous.percent;
  if (a == null || b == null) return null;
  return a - b;
}

/// One summary per calendar month in [days], oldest first, keyed by the
/// month's first day.
List<(DateTime, PeriodSummary)> summarizeByMonth(List<DayData> days) {
  final groups = <DateTime, List<DayData>>{};
  for (final d in days) {
    (groups[DateTime(d.day.year, d.day.month)] ??= []).add(d);
  }
  final keys = groups.keys.toList()..sort();
  return [for (final k in keys) (k, summarize(groups[k]!))];
}

/// The colour bucket for a score: good (75 and up), fair (60 to 74),
/// poor (under 60), or none without a score.
enum ScoreBucket { good, fair, poor, none }

ScoreBucket bucketOf(int? percent) {
  if (percent == null) return ScoreBucket.none;
  if (percent >= goodPercent) return ScoreBucket.good;
  if (percent >= fairPercent) return ScoreBucket.fair;
  return ScoreBucket.poor;
}

// Period helpers. Every range runs from local midnight of its first day to
// local midnight of its last day, both inclusive, the way date pickers
// use DateTimeRange.

DateTime _midnight(DateTime t) => DateTime(t.year, t.month, t.day);

/// The day [day] falls on, as a one-day range.
DateTimeRange dayOf(DateTime day) {
  final d = _midnight(day);
  return DateTimeRange(start: d, end: d);
}

/// The seven days holding [day], starting on [firstWeekday]
/// ([DateTime.monday] to [DateTime.sunday]).
DateTimeRange weekOf(DateTime day, {int firstWeekday = DateTime.monday}) {
  final back = (day.weekday - firstWeekday + 7) % 7;
  final start = DateTime(day.year, day.month, day.day - back);
  return DateTimeRange(
    start: start,
    end: DateTime(start.year, start.month, start.day + 6),
  );
}

/// The calendar month holding [day].
DateTimeRange monthOf(DateTime day) => DateTimeRange(
      start: DateTime(day.year, day.month, 1),
      end: DateTime(day.year, day.month + 1, 0),
    );

/// The calendar year holding [day].
DateTimeRange yearOf(DateTime day) => DateTimeRange(
      start: DateTime(day.year, 1, 1),
      end: DateTime(day.year, 12, 31),
    );

/// The [period] holding [day].
DateTimeRange periodOf(
  ReviewPeriod period,
  DateTime day, {
  int firstWeekday = DateTime.monday,
}) =>
    switch (period) {
      ReviewPeriod.day => dayOf(day),
      ReviewPeriod.week => weekOf(day, firstWeekday: firstWeekday),
      ReviewPeriod.month => monthOf(day),
      ReviewPeriod.year => yearOf(day),
    };

/// The first day of the [period] [n] periods after the one holding [day]
/// (before it when [n] is negative). Months and years step from day 1,
/// so one month after 31 January is in February, not March.
DateTime stepPeriod(
  ReviewPeriod period,
  DateTime day,
  int n, {
  int firstWeekday = DateTime.monday,
}) {
  switch (period) {
    case ReviewPeriod.day:
      return DateTime(day.year, day.month, day.day + n);
    case ReviewPeriod.week:
      final s = weekOf(day, firstWeekday: firstWeekday).start;
      return DateTime(s.year, s.month, s.day + 7 * n);
    case ReviewPeriod.month:
      return DateTime(day.year, day.month + n, 1);
    case ReviewPeriod.year:
      return DateTime(day.year + n, 1, 1);
  }
}

/// How many [period]s [day]'s period lies before [today]'s; negative when
/// it lies after. Counted on calendar dates, so 23- and 25-hour days do
/// not shift it.
int periodsBetween(
  ReviewPeriod period,
  DateTime day,
  DateTime today, {
  int firstWeekday = DateTime.monday,
}) {
  int dayNumber(DateTime t) =>
      DateTime.utc(t.year, t.month, t.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  switch (period) {
    case ReviewPeriod.day:
      return dayNumber(today) - dayNumber(day);
    case ReviewPeriod.week:
      final a = weekOf(day, firstWeekday: firstWeekday).start;
      final b = weekOf(today, firstWeekday: firstWeekday).start;
      return (dayNumber(b) - dayNumber(a)) ~/ 7;
    case ReviewPeriod.month:
      return (today.year - day.year) * 12 + today.month - day.month;
    case ReviewPeriod.year:
      return today.year - day.year;
  }
}

/// Number of days in [range], counting both ends.
int daysIn(DateTimeRange range) {
  var n = 0;
  for (var d = range.start; !d.isAfter(range.end); n++) {
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return n;
}

/// Union of the blocks' time in whole minutes, overlaps counted once.
int _unionMinutes(List<ResolvedBlock> blocks) {
  final spans = [
    for (final b in blocks)
      (b.start.millisecondsSinceEpoch, b.end.millisecondsSinceEpoch),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  var total = 0;
  int? runStart, runEnd;
  for (final (s, e) in spans) {
    if (e <= s) continue;
    if (runEnd == null || s > runEnd) {
      if (runStart != null) total += runEnd! - runStart;
      runStart = s;
      runEnd = e;
    } else if (e > runEnd) {
      runEnd = e;
    }
  }
  if (runStart != null) total += runEnd! - runStart;
  return (total / Duration.millisecondsPerMinute).round();
}
