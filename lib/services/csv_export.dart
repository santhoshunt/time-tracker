import 'package:intl/intl.dart';

import '../app_services.dart';
import '../domain/models.dart';
import 'day_loader.dart';

/// Loads every day from [first] to [last] inclusive. The export takes the
/// Review tab's range loader; tests pass a simpler one.
typedef DaysLoader =
    Future<List<DayData>> Function(DateTime first, DateTime last);

/// One quoted CSV field: quotes doubled, and the whole field quoted when
/// it holds a comma, quote or line break.
String csvField(String v) {
  if (!v.contains(RegExp('[",\r\n]'))) return v;
  return '"${v.replaceAll('"', '""')}"';
}

const csvHeader = 'date,start,end,minutes,app,package,block,verdict';

/// The verdict as a stable word for spreadsheets.
String csvVerdict(Verdict v) => switch (v) {
  Verdict.onTrack => 'on_track',
  Verdict.offTrack => 'off_track',
  Verdict.neutral => 'neutral',
  Verdict.guessedOn => 'guessed_on_track',
  Verdict.guessedOff => 'guessed_off_track',
  Verdict.idle => 'idle',
  Verdict.unplanned => 'outside_plan',
  Verdict.noData => 'no_data',
};

/// Every classified slice of [days], one row each. Unplanned time with no
/// app in front (an empty evening) is left out, as on screen.
String buildCsv(List<DayData> days) {
  final date = DateFormat('yyyy-MM-dd');
  final time = DateFormat('HH:mm');
  final rows = <String>[csvHeader];
  for (final d in days) {
    for (final s in d.segments) {
      if (s.verdict == Verdict.unplanned && s.p == null) continue;
      rows.add(
        [
          date.format(s.start),
          time.format(s.start),
          time.format(s.end),
          (s.duration.inSeconds / 60).toStringAsFixed(1),
          csvField(s.p == null ? '' : d.labelOf(s.p)),
          csvField(s.p ?? ''),
          csvField(s.blockName ?? ''),
          csvVerdict(s.verdict),
        ].join(','),
      );
    }
  }
  return '${rows.join('\r\n')}\r\n';
}

/// Exports all history, from the first stored session to today, and
/// returns where the file went. Throws when nothing could be saved.
Future<String> exportAllCsv(AppServices s, DaysLoader load) async {
  final now = s.clock.now();
  final first = await s.db.rawQuery('SELECT MIN(start_ms) AS m FROM sessions');
  final ms = first.first['m'] as int?;
  final start = ms == null
      ? DateTime(now.year, now.month, now.day)
      : DateTime.fromMillisecondsSinceEpoch(ms);
  final days = await load(
    DateTime(start.year, start.month, start.day),
    DateTime(now.year, now.month, now.day),
  );
  final name = 'drift_${DateFormat('yyyyMMdd_HHmm').format(now)}.csv';
  return s.usage.saveCsv(name, buildCsv(days));
}

/// A day-by-day loader, used until a faster range loader is passed in.
DaysLoader dayByDay(AppServices s) => (first, last) async {
  final out = <DayData>[];
  for (var d = first; !d.isAfter(last); d = DateTime(d.year, d.month, d.day + 1)) {
    out.add(await loadDay(s, d));
  }
  return out;
};
