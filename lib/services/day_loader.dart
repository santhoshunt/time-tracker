import '../app_services.dart';
import '../domain/classifier.dart';
import '../domain/models.dart';
import '../domain/plan_resolver.dart';
import '../domain/scorer.dart';

/// Everything one screen needs to draw a day: the plan placed on that day,
/// the classified time and the score.
class DayData {
  const DayData({
    required this.day,
    required this.blocks,
    required this.segments,
    required this.score,
    required this.labels,
    required this.now,
  });

  /// Local midnight of the day shown.
  final DateTime day;
  final List<ResolvedBlock> blocks;
  final List<Segment> segments;

  /// Null when nothing was planned up to now.
  final DayScore? score;

  /// Package to app name, for every package seen in [segments].
  final Map<String, String> labels;

  /// The moment the data was computed; only time before it is classified.
  final DateTime now;

  String labelOf(String? p) => p == null ? '' : (labels[p] ?? p);

  /// Segments that still wait for the user's answer, oldest first, one
  /// per (block, app) pair.
  List<Segment> get unanswered {
    final seen = <(String, String)>{};
    final out = <Segment>[];
    for (final s in segments) {
      final guessed =
          s.verdict == Verdict.guessedOn || s.verdict == Verdict.guessedOff;
      if (!guessed || s.p == null || s.blockName == null) continue;
      if (seen.add((blockKey(s.blockName!), s.p!))) out.add(s);
    }
    return out;
  }

  /// Off-track minutes per app (guessed off included), largest first.
  List<(String, int)> get topDrift {
    final mins = <String, int>{};
    for (final s in segments) {
      if (s.p == null) continue;
      if (s.verdict != Verdict.offTrack && s.verdict != Verdict.guessedOff) {
        continue;
      }
      mins[s.p!] = (mins[s.p!] ?? 0) + s.duration.inMinutes;
    }
    final list = [
      for (final e in mins.entries)
        if (e.value > 0) (e.key, e.value),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return list;
  }
}

/// Loads and classifies [day] (any time on it) from the database. Past
/// days use their frozen plan when one exists, so later edits to a
/// repeating block do not rewrite history.
Future<DayData> loadDay(AppServices s, DateTime day) async {
  final now = s.clock.now();
  final frame = DayFrame.local(day);
  final frozen = await s.plans.frozenPlan(frame.start);
  final blocks = resolvePlan(
    frame.start,
    await s.plans.allBlocks(),
    frozenJson: frozen,
  );
  final sessions = await s.sessions.sessionsBetween(frame.start, frame.end);
  final idle = await s.sessions.idleBetween(frame.start, frame.end);
  final gaps = await s.sessions.gapsBetween(frame.start, frame.end);
  final rules = await s.rules.allRules();
  final overrides = await s.rules.overridesBetween(frame.start, frame.end);
  final apps = await s.apps.all();
  final categories = {for (final a in apps) a.p: a.category};
  final labels = {for (final a in apps) a.p: a.label};

  final segments = splitAndClassify(
    day: frame.start,
    blocks: blocks,
    sessions: sessions,
    idle: idle,
    gaps: gaps,
    rules: rules,
    overrides: overrides,
    categories: categories,
    now: now,
  );
  return DayData(
    day: frame.start,
    blocks: blocks,
    segments: segments,
    score: scoreDay(segments, blocks, now),
    labels: labels,
    now: now,
  );
}
