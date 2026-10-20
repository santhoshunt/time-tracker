import '../app_services.dart';
import '../domain/models.dart';
import 'period_loader.dart';

/// How many days back, today included, Drift looks for apps to sort.
const unsortedDays = 14;

/// One (block, app) pair Drift has only guessed about, as the Not sorted
/// tab shows it.
class UnsortedPair {
  const UnsortedPair({
    required this.blockName,
    required this.p,
    required this.label,
    required this.guess,
    required this.start,
  });

  /// The block's own spelling on the day the app was last used in it.
  final String blockName;
  final String p;
  final String label;

  /// [Verdict.guessedOn] or [Verdict.guessedOff].
  final Verdict guess;

  /// When the newest guessed use started; the list sorts on it.
  final DateTime start;

  (String, String) get id => (blockKey(blockName), p);
}

/// Every guessed (block, app) pair from the last [unsortedDays] days, one
/// per pair (the newest use wins), newest first. The Not sorted tab lists
/// these and the Settings badge counts them, so the two always agree.
Future<List<UnsortedPair>> loadUnsorted(AppServices s) async {
  final now = s.clock.now();
  final days = await loadDays(
    s,
    DateTime(now.year, now.month, now.day - (unsortedDays - 1)),
    now,
  );
  final byPair = <(String, String), UnsortedPair>{};
  for (final day in days) {
    for (final seg in day.unanswered) {
      final u = UnsortedPair(
        blockName: seg.blockName!.trim(),
        p: seg.p!,
        label: day.labelOf(seg.p),
        guess: seg.verdict,
        start: seg.start,
      );
      final seen = byPair[u.id];
      if (seen == null || u.start.isAfter(seen.start)) byPair[u.id] = u;
    }
  }
  return byPair.values.toList()..sort((a, b) => b.start.compareTo(a.start));
}
