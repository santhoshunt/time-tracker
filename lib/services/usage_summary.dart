import 'dart:math' as math;

import 'package:flutter/material.dart' show DateTimeRange;

import '../app_services.dart';
import '../domain/models.dart';
import '../platform/usage_source.dart';
import 'day_loader.dart';

/// One app's foreground time in a period.
class AppUsage {
  const AppUsage({
    required this.p,
    required this.label,
    required this.category,
    required this.ms,
  });

  final String p;
  final String label;
  final String category;
  final int ms;

  int get minutes => (ms / Duration.millisecondsPerMinute).round();
}

/// One category's time and its apps, largest first.
class CategoryUsage {
  const CategoryUsage({
    required this.category,
    required this.ms,
    required this.apps,
  });

  final String category;
  final int ms;
  final List<AppUsage> apps;

  int get minutes => (ms / Duration.millisecondsPerMinute).round();
}

/// Where the phone time in a period went, plan or no plan: the Usage tab.
class UsageSummary {
  const UsageSummary({
    required this.range,
    required this.totalMs,
    required this.categories,
  });

  final DateTimeRange range;
  final int totalMs;

  /// Largest first; categories with no time are left out.
  final List<CategoryUsage> categories;

  int get totalMinutes => (totalMs / Duration.millisecondsPerMinute).round();

  bool get isEmpty => totalMs <= 0;
}

/// Sessions overlapping [from, to), clipped to it and to now, limited to
/// apps the user can open (as [withoutSystemApps] does, keeping everything
/// while the apps table is still empty) and without Drift itself.
Future<List<Session>> _countedSessions(
  AppServices s,
  DateTime from,
  DateTime to,
  Set<String> launchable,
) async {
  final now = s.clock.now();
  final end = now.isBefore(to) ? now : to;
  if (!end.isAfter(from)) return const [];
  final out = <Session>[];
  for (final x in await s.sessions.sessionsBetween(from, end)) {
    if (x.p == driftPackage) continue;
    if (launchable.isNotEmpty && !launchable.contains(x.p)) continue;
    final a = x.start.isBefore(from) ? from : x.start;
    final b = x.end.isAfter(end) ? end : x.end;
    if (b.isAfter(a)) out.add(Session(id: x.id, p: x.p, start: a, end: b));
  }
  return out;
}

/// Per-app and per-category time from [first] to [lastInclusive] (local
/// days, both ends included), ignoring the plan entirely.
///
/// Read straight from the `sessions` table, so it needs one range query
/// whatever the period's length. A package missing from the apps table is
/// counted under [AppCategories.undefined] with its package as the label.
Future<UsageSummary> loadUsage(
  AppServices s,
  DateTime first,
  DateTime lastInclusive,
) async {
  final from = DateTime(first.year, first.month, first.day);
  final to = DateTime(
    lastInclusive.year,
    lastInclusive.month,
    lastInclusive.day + 1,
  );
  final range = DateTimeRange(
    start: from,
    end: DateTime(lastInclusive.year, lastInclusive.month, lastInclusive.day),
  );
  final apps = await s.apps.all();
  final info = {for (final a in apps) a.p: a};
  final sessions = await _countedSessions(s, from, to, info.keys.toSet());

  final byApp = <String, int>{};
  for (final x in sessions) {
    byApp[x.p] = (byApp[x.p] ?? 0) + x.duration.inMilliseconds;
  }
  final byCategory = <String, List<AppUsage>>{};
  for (final MapEntry(key: p, value: ms) in byApp.entries) {
    final a = info[p];
    final category = a?.category ?? AppCategories.undefined;
    (byCategory[category] ??= []).add(
      AppUsage(p: p, label: a?.label ?? p, category: category, ms: ms),
    );
  }
  int largestFirst(int a, int b, String ka, String kb) {
    final byMs = b.compareTo(a);
    return byMs != 0 ? byMs : ka.compareTo(kb);
  }

  final categories = [
    for (final MapEntry(:key, :value) in byCategory.entries)
      CategoryUsage(
        category: key,
        ms: value.fold(0, (sum, a) => sum + a.ms),
        apps: value
          ..sort((a, b) => largestFirst(a.ms, b.ms, a.label, b.label)),
      ),
  ]..sort((a, b) => largestFirst(a.ms, b.ms, a.category, b.category));
  return UsageSummary(
    range: range,
    totalMs: categories.fold(0, (sum, c) => sum + c.ms),
    categories: categories,
  );
}

/// Minutes an app spent inside one block on a day, or outside every block
/// when [block] is null.
class BlockShare {
  const BlockShare({
    required this.block,
    required this.minutes,
    required this.offTrack,
  });

  final String? block;
  final int minutes;

  /// True when this time counted as drift (ruled or guessed off track).
  final bool offTrack;
}

/// Everything the app page shows.
class AppDetail {
  const AppDetail({
    required this.p,
    required this.label,
    required this.category,
    required this.dayMinutes,
    required this.lastSevenDays,
    required this.daySpans,
    required this.byBlock,
  });

  final String p;
  final String label;
  final String category;

  /// Minutes on the day asked for.
  final int dayMinutes;

  /// (local midnight, minutes) for the day and the six before it, oldest
  /// first.
  final List<(DateTime, int)> lastSevenDays;

  /// When the app was in front on the day, oldest first.
  final List<(DateTime, DateTime)> daySpans;

  /// Inside each block first (largest first), then outside blocks.
  final List<BlockShare> byBlock;
}

/// The app page for [p] on [day]: its week, its runs that day, and how its
/// time on that day fell against the plan.
Future<AppDetail> loadAppDetail(AppServices s, String p, DateTime day) async {
  final d = DateTime(day.year, day.month, day.day);
  final weekStart = DateTime(d.year, d.month, d.day - 6);
  final dayEnd = DateTime(d.year, d.month, d.day + 1);
  final apps = await s.apps.all();
  final info = {for (final a in apps) a.p: a};
  final sessions = [
    for (final x in await _countedSessions(
      s,
      weekStart,
      dayEnd,
      info.keys.toSet(),
    ))
      if (x.p == p) x,
  ];

  final perDay = <(DateTime, int)>[];
  final spans = <(DateTime, DateTime)>[];
  var dayMs = 0;
  for (var i = 0; i < 7; i++) {
    final a = DateTime(weekStart.year, weekStart.month, weekStart.day + i);
    final b = DateTime(a.year, a.month, a.day + 1);
    var ms = 0;
    for (final x in sessions) {
      final from = x.start.isBefore(a) ? a : x.start;
      final to = x.end.isAfter(b) ? b : x.end;
      if (to.isAfter(from)) {
        ms += to.difference(from).inMilliseconds;
        if (i == 6) spans.add((from, to));
      }
    }
    if (i == 6) dayMs = ms;
    perDay.add((a, (ms / Duration.millisecondsPerMinute).round()));
  }

  final data = await loadDay(s, d);
  final inBlock = <String, (int, bool)>{};
  var outsideMs = 0;
  for (final seg in data.segments) {
    if (seg.p != p) continue;
    final ms = seg.duration.inMilliseconds;
    final name = seg.blockName;
    if (name == null) {
      outsideMs += ms;
      continue;
    }
    final off =
        seg.verdict == Verdict.offTrack || seg.verdict == Verdict.guessedOff;
    final (sum, wasOff) = inBlock[name] ?? (0, false);
    inBlock[name] = (sum + ms, wasOff || off);
  }
  int mins(int ms) => (ms / Duration.millisecondsPerMinute).round();
  final shares = [
    for (final MapEntry(:key, value: (ms, off)) in inBlock.entries)
      if (mins(ms) > 0) BlockShare(block: key, minutes: mins(ms), offTrack: off),
  ]..sort((a, b) => b.minutes.compareTo(a.minutes));
  if (mins(outsideMs) > 0) {
    shares.add(
      BlockShare(block: null, minutes: mins(outsideMs), offTrack: false),
    );
  }

  final a = info[p];
  return AppDetail(
    p: p,
    label: a?.label ?? p,
    category: a?.category ?? AppCategories.undefined,
    dayMinutes: mins(dayMs),
    lastSevenDays: perDay,
    daySpans: spans,
    byBlock: shares,
  );
}

/// The largest of [values], at least 1, for scaling bars.
int maxOf(Iterable<int> values) => values.fold(1, math.max);
