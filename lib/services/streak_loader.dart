import '../app_services.dart';
import 'period_loader.dart';
import 'review_summary.dart';

/// This week so far and the run of good days: Today's week card.
class WeekProgress {
  const WeekProgress({
    required this.week,
    required this.weekPercent,
    required this.streak,
  });

  /// The seven days of the week holding today, oldest first.
  final List<DayPoint> week;

  /// The week's score so far, minute-weighted as on Review; null before
  /// anything planned has happened.
  final int? weekPercent;

  /// Good days in a row up to today ([currentStreak]).
  final int streak;

  /// Whether any day this week has a block; the card hides otherwise.
  bool get hasPlan => week.any((d) => d.hasPlan);
}

/// How many days one streak query loads, and the most it looks back.
const _chunkDays = 28;
const _maxChunks = 13;

/// Loads [today]'s week and the current streak.
///
/// The streak loads 28 days at a time, going back only while every scored
/// day so far was a good one, so a usual week costs one or two queries and
/// a year-long run at most thirteen.
Future<WeekProgress> loadWeekProgress(
  AppServices s,
  DateTime today, {
  required int firstWeekday,
}) async {
  final day = DateTime(today.year, today.month, today.day);
  final range = weekOf(day, firstWeekday: firstWeekday);
  final week = summarize(await loadDays(s, range.start, range.end));

  final points = <DayPoint>[];
  var end = day;
  for (var i = 0; i < _maxChunks; i++) {
    final start = DateTime(end.year, end.month, end.day - (_chunkDays - 1));
    final chunk = summarize(await loadDays(s, start, end)).days;
    points.insertAll(0, chunk);
    final broke = chunk.any(
      (p) => p.day != day && p.percent != null && p.percent! < goodPercent,
    );
    if (broke) break;
    end = DateTime(start.year, start.month, start.day - 1);
  }
  return WeekProgress(
    week: week.days,
    weekPercent: week.percent,
    streak: currentStreak(points, day),
  );
}
