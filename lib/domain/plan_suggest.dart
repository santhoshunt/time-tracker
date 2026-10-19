import 'plan_resolver.dart';
import 'models.dart';

/// How many weeks back [suggestPlan] looks for the same weekday.
const suggestWeeks = 4;

/// Blocks to offer on an empty [date], from what was planned on the same
/// weekday over the last [suggestWeeks] weeks.
///
/// Each past day uses its frozen plan when [frozenByDate] (yyyy-MM-dd to
/// `day_plans.blocks_json`) has one, and the live blocks otherwise. Days
/// with no blocks are left out, so a week off does not outvote the rest.
/// A slot, the same name (as [blockKey] compares it) and the same times,
/// is offered when it appears on at least half of the days that remain,
/// rounded up. Offered slots that overlap keep the one seen more often,
/// then the more recent. The newest copy of a slot gives its name, colour
/// and "any app" setting.
///
/// Returns one-off blocks dated [date], in start order; empty when no past
/// weekday had a plan, or when a repeating block was taken off [date]
/// ("This day only"): that day was emptied on purpose, and offering the
/// block straight back would undo the choice.
List<PlanBlock> suggestPlan(
  DateTime date,
  List<PlanBlock> live,
  Map<String, String> frozenByDate,
) {
  final target = dateKey(date);
  if (live.any((b) => b.skipDates.contains(target))) return const [];
  final days = <List<PlanBlock>>[];
  for (var w = 1; w <= suggestWeeks; w++) {
    final day = DateTime(date.year, date.month, date.day - 7 * w);
    final frozen = frozenByDate[dateKey(day)];
    final blocks =
        (frozen == null ? null : decodeFrozenPlan(frozen)) ??
        activeBlocks(day, live);
    final valid = [
      for (final b in blocks)
        if (b.endMin > b.startMin) b,
    ];
    if (valid.isNotEmpty) days.add(valid);
  }
  if (days.isEmpty) return const [];

  // days[0] is the most recent week.
  final seen = <(String, int, int), _Slot>{};
  for (final (age, blocks) in days.indexed) {
    final once = <(String, int, int)>{};
    for (final b in blocks) {
      final key = (blockKey(b.name), b.startMin, b.endMin);
      if (!once.add(key)) continue;
      final slot = seen.putIfAbsent(key, () => _Slot(b, age));
      slot.count++;
    }
  }
  final needed = (days.length + 1) ~/ 2;
  final ranked = [
    for (final s in seen.values)
      if (s.count >= needed) s,
  ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      final byAge = a.age.compareTo(b.age);
      if (byAge != 0) return byAge;
      return a.block.startMin.compareTo(b.block.startMin);
    });

  final kept = <PlanBlock>[];
  for (final s in ranked) {
    final b = s.block;
    if (kept.any((k) => k.startMin < b.endMin && b.startMin < k.endMin)) {
      continue;
    }
    kept.add(b);
  }
  return [
    for (final b in kept)
      PlanBlock(
        name: b.name,
        startMin: b.startMin,
        endMin: b.endMin,
        colorIdx: b.colorIdx,
        anyApp: b.anyApp,
        date: target,
      ),
  ]..sort((a, b) => a.startMin.compareTo(b.startMin));
}

class _Slot {
  _Slot(this.block, this.age);

  /// The newest copy, since weeks are visited newest first.
  final PlanBlock block;

  /// Weeks back of the newest copy, 0 for last week.
  final int age;
  int count = 0;
}
