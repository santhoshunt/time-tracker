import 'models.dart';

/// The day's score from its classified [segments] and resolved [blocks].
///
/// - Planned time is the union of block time up to [now], so overlapping
///   blocks are not counted twice and today only counts what has passed.
/// - Off time is offTrack plus guessedOff inside blocks: an unanswered
///   guess counts by its guess.
/// - Idle time inside blocks counts as on track; it is reported, not
///   subtracted.
/// - No-data time inside blocks leaves both sides of the ratio, since
///   nothing is known about it.
///
/// percent = round(100 x (planned - noData - off) / (planned - noData)).
/// Returns null when no known planned time has passed yet, because
/// neither 0 nor 100 would be true.
///
/// Sums run in milliseconds and round to minutes only at the end.
DayScore? scoreDay(List<Segment> segments, List<ResolvedBlock> blocks, DateTime now) {
  final nowMs = now.millisecondsSinceEpoch;

  final spans = <(int, int)>[
    for (final b in blocks)
      (b.start.millisecondsSinceEpoch, _min(b.end.millisecondsSinceEpoch, nowMs)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  var plannedMs = 0;
  int? runStart, runEnd;
  for (final (s, e) in spans) {
    if (e <= s) continue;
    if (runEnd == null || s > runEnd) {
      if (runStart != null) plannedMs += runEnd! - runStart;
      runStart = s;
      runEnd = e;
    } else if (e > runEnd) {
      runEnd = e;
    }
  }
  if (runStart != null) plannedMs += runEnd! - runStart;

  var offMs = 0, idleMs = 0, noDataMs = 0;
  for (final seg in segments) {
    if (seg.blockName == null) continue;
    final ms = _min(seg.end.millisecondsSinceEpoch, nowMs) - seg.start.millisecondsSinceEpoch;
    if (ms <= 0) continue;
    switch (seg.verdict) {
      case Verdict.offTrack:
      case Verdict.guessedOff:
        offMs += ms;
      case Verdict.idle:
        idleMs += ms;
      case Verdict.noData:
        noDataMs += ms;
      case Verdict.onTrack:
      case Verdict.guessedOn:
      case Verdict.unplanned:
        break;
    }
  }

  final knownMs = plannedMs - noDataMs;
  if (knownMs <= 0) return null;
  final percent = (100 * (knownMs - offMs) / knownMs).round().clamp(0, 100);
  return DayScore(
    plannedMin: _minutes(plannedMs),
    offMin: _minutes(offMs),
    idleMin: _minutes(idleMs),
    noDataMin: _minutes(noDataMs),
    percent: percent,
  );
}

int _min(int a, int b) => a < b ? a : b;

int _minutes(int ms) => (ms / Duration.millisecondsPerMinute).round();
