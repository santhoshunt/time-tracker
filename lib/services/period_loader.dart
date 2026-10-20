import '../app_services.dart';
import '../domain/classifier.dart';
import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../domain/scorer.dart';
import '../domain/system_apps.dart';
import 'day_loader.dart';

/// Loads and classifies every local day from [first] to [lastInclusive]
/// (any time on each), oldest first.
///
/// The range is read with one query per table (sessions, idle spans,
/// gaps, overrides, rules, apps, live blocks and frozen plans) and then
/// split per day with the functions [loadDay] uses, so a whole year loads
/// in a few queries instead of a few thousand.
///
/// [loadDay] is this function for one day, so Today and Review agree.
/// A past day that has plan blocks but no stored session, idle span or
/// gap touching it comes back with its blocks, no segments and no score. Such a day predates tracking (before install, or before
/// Android's history reached), and the classifier would otherwise call
/// all of its block time idle, which scores 100%.
///
/// Days after today come back with their plan and no score.
Future<List<DayData>> loadDays(
  AppServices s,
  DateTime first,
  DateTime lastInclusive,
) async {
  final now = s.clock.now();
  final from = DateTime(first.year, first.month, first.day);
  final to = DateTime(
    lastInclusive.year,
    lastInclusive.month,
    lastInclusive.day + 1,
  );
  if (!to.isAfter(from)) return const [];

  final liveBlocks = await s.plans.allBlocks();
  final frozen = await _frozenPlans(s, from, to);
  final sessions = await s.sessions.sessionsBetween(from, to);
  final idle = await s.sessions.idleBetween(from, to);
  final gaps = await s.sessions.gapsBetween(from, to);
  final rules = await s.rules.allRules();
  final groups = await s.groups.snapshot();
  final overrides = await s.rules.overridesBetween(from, to);
  final apps = await s.apps.all();
  final categories = {for (final a in apps) a.p: a.category};
  final labels = {for (final a in apps) a.p: a.label};
  final launchable = {for (final a in apps) a.p};

  final sessionsByDay = _byDay(sessions, (x) => x.start, (x) => x.end, from, to);
  final idleByDay = _byDay(idle, (x) => x.start, (x) => x.end, from, to);
  final gapsByDay = _byDay(gaps, (x) => x.start, (x) => x.end, from, to);

  final out = <DayData>[];
  for (var i = 0; ; i++) {
    final day = DateTime(from.year, from.month, from.day + i);
    if (!day.isBefore(to)) break;
    final blocks = resolvePlan(
      day,
      liveBlocks,
      frozenJson: frozen[dateKey(day)],
    );
    final dayIdle = [...?idleByDay[day]];
    // Google Play services, permission dialogs and the like count as
    // background time, as the lock screen does.
    final daySessions = withoutSystemApps(
      sessionsByDay[day] ?? const <Session>[],
      launchable,
      dayIdle,
    );
    final dayGaps = gapsByDay[day] ?? const <GapSpan>[];

    final untracked = blocks.isNotEmpty &&
        now.isAfter(day) &&
        daySessions.isEmpty &&
        dayIdle.isEmpty &&
        dayGaps.isEmpty;
    if (untracked) {
      out.add(DayData(
        day: day,
        blocks: blocks,
        segments: const [],
        score: null,
        labels: labels,
        now: now,
      ));
      continue;
    }

    final segments = splitAndClassify(
      day: day,
      blocks: blocks,
      sessions: daySessions,
      idle: dayIdle,
      gaps: dayGaps,
      rules: rules,
      overrides: overrides,
      categories: categories,
      now: now,
      groups: groups,
    );
    out.add(DayData(
      day: day,
      blocks: blocks,
      segments: segments,
      score: scoreDay(segments, blocks, now),
      labels: labels,
      now: now,
    ));
  }
  return out;
}

/// Frozen plan JSON by `yyyy-MM-dd` for every frozen day in [from, to).
/// `day_plans.date` sorts as text in date order, so one range query does.
Future<Map<String, String>> _frozenPlans(
  AppServices s,
  DateTime from,
  DateTime to,
) async {
  final rows = await s.db.query(
    'day_plans',
    columns: ['date', 'blocks_json'],
    where: 'date >= ? AND date < ?',
    whereArgs: [dateKey(from), dateKey(to)],
  );
  return {
    for (final r in rows) r['date'] as String: r['blocks_json'] as String,
  };
}

/// Puts each item into every local day in [from, to) it overlaps, with
/// the same test the repositories use (starts before the day ends and
/// ends after it starts). [items] keep their order inside each day, which
/// the classifier's tie-break relies on.
Map<DateTime, List<T>> _byDay<T>(
  List<T> items,
  DateTime Function(T) start,
  DateTime Function(T) end,
  DateTime from,
  DateTime to,
) {
  final out = <DateTime, List<T>>{};
  for (final item in items) {
    final a = start(item);
    final b = end(item);
    var day = localDayStart(a.isBefore(from) ? from : a);
    while (day.isBefore(to) && day.isBefore(b)) {
      final next = DateTime(day.year, day.month, day.day + 1);
      if (a.isBefore(next) && b.isAfter(day)) {
        (out[day] ??= <T>[]).add(item);
      }
      day = next;
    }
  }
  return out;
}
