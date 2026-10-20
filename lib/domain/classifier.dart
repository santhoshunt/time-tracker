import '../platform/usage_source.dart';
import 'app_groups.dart';
import 'category_guess.dart';
import 'models.dart';
import 'plan_resolver.dart';

/// Splits [day] (local) into classified segments and judges each against
/// the plan.
///
/// The day runs from its local midnight to the next one, so it is 23, 24
/// or 25 hours long, and only time up to [now] is returned. See
/// [classifyFrame] for the rules.
List<Segment> splitAndClassify({
  required DateTime day,
  required List<ResolvedBlock> blocks,
  required List<Session> sessions,
  required List<IdleSpan> idle,
  required List<GapSpan> gaps,
  required Map<(String, String), Verdict> rules,
  required Map<int, Verdict> overrides,
  required Map<String, String> categories,
  required DateTime now,
  AppGroups groups = AppGroups.none,
}) {
  final frame = DayFrame.local(day);
  return classifyFrame(
    dayStart: frame.start,
    dayEnd: frame.end,
    blocks: blocks,
    sessions: sessions,
    idle: idle,
    gaps: gaps,
    rules: rules,
    overrides: overrides,
    categories: categories,
    now: now,
    groups: groups,
  );
}

/// [splitAndClassify] with the day's bounds given directly, so a test can
/// run a 23- or 25-hour day on a machine whose zone has no such days.
///
/// Every instant from [dayStart] to the earlier of [dayEnd] and [now] is
/// in exactly one segment. Cuts fall at every block, session, idle and
/// gap edge. Where blocks overlap, the one that started last owns the
/// instant (on a tie, the first in [blocks]). Then:
/// - Gap time is [Verdict.noData]; gaps win over sessions, because a
///   session crossing a gap was stitched from incomplete events.
/// - Session time inside a block is judged by, in order: an override for
///   the session id, a rule for (block key, package), a group the block
///   uses ([AppGroups.blockVerdict]), the block's anyApp flag (on track),
///   membership of a Distracting group (off track), then the guess from
///   the app's category (missing category counts as `undefined`).
/// - Time inside a block with no session is [Verdict.idle], whether an
///   idle span covers it or nothing does: either way no app was in use.
/// - Time outside every block is [Verdict.unplanned], with the package
///   when an app was in use.
///
/// Neighbouring pieces with the same verdict, package, block and session
/// merge into one segment.
List<Segment> classifyFrame({
  required DateTime dayStart,
  required DateTime dayEnd,
  required List<ResolvedBlock> blocks,
  required List<Session> sessions,
  required List<IdleSpan> idle,
  required List<GapSpan> gaps,
  required Map<(String, String), Verdict> rules,
  required Map<int, Verdict> overrides,
  required Map<String, String> categories,
  required DateTime now,
  AppGroups groups = AppGroups.none,
}) {
  final fromMs = dayStart.millisecondsSinceEpoch;
  final toMs = (now.isBefore(dayEnd) ? now : dayEnd).millisecondsSinceEpoch;
  if (toMs <= fromMs) return const [];

  final cuts = <int>{fromMs, toMs};
  void addCut(DateTime t) {
    final ms = t.millisecondsSinceEpoch;
    if (ms > fromMs && ms < toMs) cuts.add(ms);
  }

  for (final b in blocks) {
    addCut(b.start);
    addCut(b.end);
  }
  for (final s in sessions) {
    addCut(s.start);
    addCut(s.end);
  }
  for (final i in idle) {
    addCut(i.start);
    addCut(i.end);
  }
  for (final g in gaps) {
    addCut(g.start);
    addCut(g.end);
  }
  final points = cuts.toList()..sort();

  bool covers(DateTime start, DateTime end, int a, int b) =>
      start.millisecondsSinceEpoch <= a && end.millisecondsSinceEpoch >= b;

  final segments = <Segment>[];
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i], b = points[i + 1];

    ResolvedBlock? block;
    for (final candidate in blocks) {
      if (covers(candidate.start, candidate.end, a, b) &&
          (block == null || candidate.start.isAfter(block.start))) {
        block = candidate;
      }
    }
    Session? session;
    for (final candidate in sessions) {
      if (covers(candidate.start, candidate.end, a, b) &&
          (session == null || candidate.start.isAfter(session.start))) {
        session = candidate;
      }
    }
    final inGap = gaps.any((g) => covers(g.start, g.end, a, b));

    final Segment piece;
    final start = DateTime.fromMillisecondsSinceEpoch(a, isUtc: dayStart.isUtc);
    final end = DateTime.fromMillisecondsSinceEpoch(b, isUtc: dayStart.isUtc);
    if (inGap) {
      piece = Segment(start: start, end: end, verdict: Verdict.noData, blockName: block?.name);
    } else if (block == null) {
      piece = Segment(
        p: session?.p,
        start: start,
        end: end,
        verdict: Verdict.unplanned,
        sessionId: session?.id,
      );
    } else if (session == null) {
      piece = Segment(start: start, end: end, verdict: Verdict.idle, blockName: block.name);
    } else {
      piece = Segment(
        p: session.p,
        start: start,
        end: end,
        verdict: _judge(session, block, rules, overrides, categories, groups),
        blockName: block.name,
        sessionId: session.id,
      );
    }
    _appendMerging(segments, piece);
  }
  return segments;
}

Verdict _judge(
  Session session,
  ResolvedBlock block,
  Map<(String, String), Verdict> rules,
  Map<int, Verdict> overrides,
  Map<String, String> categories,
  AppGroups groups,
) {
  final id = session.id;
  final override = id == null ? null : overrides[id];
  if (override == Verdict.onTrack || override == Verdict.offTrack) return override!;
  final key = blockKey(block.name);
  final rule = rules[(key, session.p)];
  if (rule == Verdict.onTrack || rule == Verdict.offTrack) return rule!;
  final grouped = groups.blockVerdict(key, session.p);
  if (grouped != null) return grouped;
  if (block.anyApp) return Verdict.onTrack;
  // A Distracting group is a standing answer, so it is drift, not a guess.
  if (groups.isDistractingMember(session.p)) return Verdict.offTrack;
  return guessFor(categories[session.p] ?? AppCategories.undefined);
}

void _appendMerging(List<Segment> segments, Segment piece) {
  if (segments.isNotEmpty) {
    final last = segments.last;
    if (last.end == piece.start &&
        last.verdict == piece.verdict &&
        last.p == piece.p &&
        last.blockName == piece.blockName &&
        last.sessionId == piece.sessionId) {
      segments[segments.length - 1] = Segment(
        p: last.p,
        start: last.start,
        end: piece.end,
        verdict: last.verdict,
        blockName: last.blockName,
        sessionId: last.sessionId,
      );
      return;
    }
  }
  segments.add(piece);
}
