import '../app_services.dart';
import '../domain/models.dart';
import 'period_loader.dart';

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

  /// Least guessed use of an app in a block, across the day, before Drift
  /// asks about it. A second's glimpse is not worth a question.
  static const askAfter = Duration(minutes: 1);

  /// Segments that still wait for the user's answer, oldest first, one
  /// per (block, app) pair used for at least [askAfter] that day.
  List<Segment> get unanswered {
    final first = <(String, String), Segment>{};
    final used = <(String, String), Duration>{};
    for (final s in segments) {
      final guessed =
          s.verdict == Verdict.guessedOn || s.verdict == Verdict.guessedOff;
      if (!guessed || s.p == null || s.blockName == null) continue;
      final key = (blockKey(s.blockName!), s.p!);
      first.putIfAbsent(key, () => s);
      used[key] = (used[key] ?? Duration.zero) + s.duration;
    }
    return [
      for (final MapEntry(:key, :value) in first.entries)
        if (used[key]! >= askAfter) value,
    ];
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

/// Loads and classifies [day] (any time on it) from the database. It is
/// [loadDays] for a single day, so Today and Review can never disagree.
/// Past days use their frozen plan when one exists, so later edits to a
/// repeating block do not rewrite history.
Future<DayData> loadDay(AppServices s, DateTime day) async =>
    (await loadDays(s, day, day)).single;
