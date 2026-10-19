import 'dart:convert';

import 'models.dart';

/// One calendar day as a span of instants, plus the mapping from
/// "minutes since local midnight" to an instant on that day.
///
/// The app always uses [DayFrame.local]. Tests build frames by hand to
/// cover 23- and 25-hour days, because the test machine's zone (IST) has
/// no daylight-saving changes to exercise.
class DayFrame {
  DayFrame({required this.start, required this.end, required this.wallClock});

  /// The frame for [date]'s calendar day in the device's zone. Both ends
  /// are local midnights built from calendar fields, so the day is as
  /// long as the zone makes it, and a wall-clock minute that falls in a
  /// skipped hour lands wherever Dart's local constructor puts it.
  factory DayFrame.local(DateTime date) {
    final y = date.year, m = date.month, d = date.day;
    return DayFrame(
      start: DateTime(y, m, d),
      end: DateTime(y, m, d + 1),
      wallClock: (minute) => DateTime(y, m, d, 0, minute),
    );
  }

  final DateTime start;
  final DateTime end;

  /// Maps a wall-clock minute strictly inside the day to its instant.
  /// [at] handles the two ends itself.
  final DateTime Function(int minute) wallClock;

  /// The instant for [minute] after midnight. 0 or less is the day's
  /// start and 1440 or more is the next midnight, whatever the day's
  /// length.
  DateTime at(int minute) {
    if (minute <= 0) return start;
    if (minute >= 1440) return end;
    return wallClock(minute);
  }
}

/// The live blocks that apply on [date]: repeating blocks whose weekday
/// bit is set and whose [PlanBlock.skipDates] do not hold the date, and
/// one-off blocks dated that day.
List<PlanBlock> activeBlocks(DateTime date, List<PlanBlock> blocks) {
  final key = dateKey(date);
  final bit = 1 << (date.weekday - 1);
  return [
    for (final b in blocks)
      if (!b.skipDates.contains(key) &&
          (b.repeatMask == 0 ? b.date == key : (b.repeatMask & bit) != 0))
        b,
  ];
}

/// Places already-chosen blocks on [frame]. Blocks that end at or before
/// their start are skipped (the editor rejects them, but a hand-edited
/// or old row must not break the day). Overlapping blocks are all kept;
/// the classifier decides which one owns each instant.
List<ResolvedBlock> placeBlocks(List<PlanBlock> blocks, DayFrame frame) {
  final placed = <ResolvedBlock>[];
  for (final b in blocks) {
    if (b.endMin <= b.startMin) continue;
    final start = frame.at(b.startMin);
    final end = frame.at(b.endMin);
    if (!end.isAfter(start)) continue;
    placed.add(ResolvedBlock(
      name: b.name,
      start: start,
      end: end,
      anyApp: b.anyApp,
      colorIdx: b.colorIdx,
    ));
  }
  placed.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    final byEnd = a.end.compareTo(b.end);
    return byEnd != 0 ? byEnd : a.name.compareTo(b.name);
  });
  return placed;
}

/// The plan for [date] in local time.
///
/// A frozen plan, the JSON list of [PlanBlock]s stored in `day_plans`
/// once the day ended, wins over the live blocks, so editing a repeating
/// block later never rewrites history. The frozen blocks were already
/// chosen for that date and are placed as they are. A frozen value that
/// does not parse falls back to the live blocks.
List<ResolvedBlock> resolvePlan(
  DateTime date,
  List<PlanBlock> blocks, {
  String? frozenJson,
}) {
  final frame = DayFrame.local(date);
  final frozen = frozenJson == null ? null : decodeFrozenPlan(frozenJson);
  if (frozen != null) return placeBlocks(frozen, frame);
  return placeBlocks(activeBlocks(date, blocks), frame);
}

/// The `day_plans.blocks_json` text for [blocks].
String encodeFrozenPlan(List<PlanBlock> blocks) =>
    jsonEncode([for (final b in blocks) b.toJson()]);

/// Parses `day_plans.blocks_json`, or returns null when it is not a JSON
/// list of block objects.
List<PlanBlock>? decodeFrozenPlan(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    return [
      for (final item in decoded) PlanBlock.fromJson(item as Map<String, dynamic>),
    ];
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}
