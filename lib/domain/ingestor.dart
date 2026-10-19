import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../data/repositories/app_repository.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/meta_repository.dart';
import '../data/repositories/plan_repository.dart';
import '../data/repositories/session_repository.dart';
import '../platform/usage_source.dart';
import 'clock.dart';
import 'models.dart';
import 'plan_resolver.dart';
import 'sessionizer.dart';

/// What one [Ingestor.run] did, for Diagnostics and tests.
class IngestResult {
  const IngestResult({
    required this.eventsAdded,
    required this.daysRebuilt,
    required this.gapsAdded,
  });

  /// Raw events that were new to the database.
  final int eventsAdded;

  /// Local days whose sessions and idle spans were rebuilt.
  final int daysRebuilt;

  /// New no-data gaps recorded.
  final int gapsAdded;

  @override
  String toString() =>
      'IngestResult(events $eventsAdded, days $daysRebuilt, gaps $gapsAdded)';
}

/// Reads a buffer file's text. Injected so tests can keep files in memory.
typedef BufferFileReader = Future<String> Function(String path);

/// Pulls usage events from Android into the database and rebuilds the
/// sessions they affect. The Today tab runs it on open and on resume.
///
/// Every step is idempotent and the cursor is written last, so a run that
/// dies part way is repaired by the next one: events are de-duplicated by
/// the UNIQUE key, sessions are rebuilt from raw events, gaps merge on
/// their start and a frozen plan is never overwritten.
class Ingestor {
  Ingestor({
    required this.source,
    required this.events,
    required this.sessions,
    required this.plans,
    required this.apps,
    required this.meta,
    required this.clock,
    required this.extraIdlePackages,
    BufferFileReader? readBufferFile,
  }) : _readBufferFile = readBufferFile ?? _readFile;

  final UsageSource source;
  final EventRepository events;
  final SessionRepository sessions;
  final PlanRepository plans;
  final AppRepository apps;
  final MetaRepository meta;
  final Clock clock;

  /// Packages whose foreground time is idle besides the launchers that
  /// [UsageSource.homePackages] reports: Drift's own package and
  /// `com.android.systemui`.
  final Set<String> extraIdlePackages;

  final BufferFileReader _readBufferFile;

  /// `meta` key holding the end of the last successful ingest (UTC ms).
  static const cursorKey = 'ingest_cursor_ms';

  /// `meta` key holding when the apps table was last refreshed (UTC ms).
  static const appsRefreshedKey = 'apps_refreshed_ms';

  /// How far before the cursor the direct query starts again, so events
  /// Android writes late (it batches them) are not missed.
  static const queryOverlap = Duration(hours: 2);

  /// The direct query never reaches further back than this.
  static const maxLookback = Duration(days: 7);

  /// Events read before the first rebuilt day, so a session that started
  /// the evening before is rebuilt with its real start.
  static const rebuildLeadIn = Duration(hours: 12);

  /// Raw events are kept for this many local days before today.
  static const keepRawDays = 3;

  static final _bufferName = RegExp(r'^(\d+)-(\d+)\.jsonl$');

  /// Runs one ingest. Steps, in order:
  /// 1. Drain buffer files: parse, insert and commit each, then delete the
  ///    committed ones. A file that fails to parse or commit is kept for
  ///    the next run.
  /// 2. Query Android from max(cursor - [queryOverlap], now -
  ///    [maxLookback]) to now and insert.
  /// 3. If Android's earliest event (or the query start) is later than
  ///    the cursor, record the parts of that span no buffer file covered
  ///    as gaps.
  /// 4. Rebuild sessions and idle spans for every local day from the
  ///    first touched one to today, in one pass that starts
  ///    [rebuildLeadIn] earlier. With a cursor, the first rebuilt day is
  ///    never older than [keepRawDays] before the cursor's day, the
  ///    oldest day whose raw events are known to be complete.
  /// 5. Prune raw events older than [keepRawDays] local days.
  /// 6. Freeze the plan of every ended day in that range (and yesterday)
  ///    that has no frozen plan yet.
  /// 7. Advance the cursor to now.
  /// 8. Refresh the apps table, at most once per local day.
  Future<IngestResult> run() async {
    final now = clock.now();
    final nowMs = now.millisecondsSinceEpoch;
    final cursor = await meta.getInt(cursorKey);
    var added = 0;
    int? touchedFromMs;
    final covered = <(int, int)>[];

    // 1. Buffer files.
    final committed = <String>[];
    for (final path in await source.drainBuffer()) {
      final span = _spanFromName(path);
      if (span != null) covered.add(span);
      try {
        final parsed = _parseLines(await _readBufferFile(path));
        final n = await events.insertAll(parsed);
        added += n;
        committed.add(path);
        if (parsed.isNotEmpty) {
          final minT = parsed.map((e) => e.t).reduce(math.min);
          final maxT = parsed.map((e) => e.t).reduce(math.max);
          if (span == null) covered.add((minT, maxT));
          if (n > 0) touchedFromMs = _minOrNull(touchedFromMs, minT);
        }
      } on Object {
        // Kept on disk; the next run retries it.
      }
    }
    if (committed.isNotEmpty) await source.deleteBuffer(committed);

    // 2. Direct query.
    final lookbackMs = nowMs - maxLookback.inMilliseconds;
    final queryFromMs = cursor == null
        ? lookbackMs
        : math.max(cursor - queryOverlap.inMilliseconds, lookbackMs);
    final queried = [
      for (final m in await source.queryEvents(fromMs: queryFromMs, toMs: nowMs))
        ?RawEvent.fromMap(m),
    ];
    added += await events.insertAll(queried);
    touchedFromMs = _minOrNull(touchedFromMs, queryFromMs);

    // 3. Gaps.
    var gapsAdded = 0;
    if (cursor != null) {
      final earliest = await source.earliestEventMs();
      if (earliest != null) {
        final gapEnd = math.max(earliest, queryFromMs);
        for (final (s, e) in _subtract((cursor, gapEnd), covered)) {
          final isNew = await sessions.addGap(GapSpan(
            DateTime.fromMillisecondsSinceEpoch(s),
            DateTime.fromMillisecondsSinceEpoch(e),
          ));
          if (isNew) gapsAdded++;
        }
      }
    }

    // 4. Rebuild. Never earlier than the oldest day the previous run's
    // prune left whole: a buffer file that Kotlin failed to delete comes
    // back on every run, and once its day is pruned its events look new
    // again. Rebuilding that day from those few events would wipe the
    // day's other sessions and their overrides.
    final today = localDayStart(now);
    var rebuildFromMs = touchedFromMs;
    if (cursor != null) {
      final cursorDay = localDayStart(DateTime.fromMillisecondsSinceEpoch(cursor));
      final intactFrom = DateTime(cursorDay.year, cursorDay.month, cursorDay.day - keepRawDays);
      rebuildFromMs = math.max(rebuildFromMs, intactFrom.millisecondsSinceEpoch);
    }
    final firstDay = localDayStart(DateTime.fromMillisecondsSinceEpoch(rebuildFromMs));
    final idlePackages = {...extraIdlePackages, ...await source.homePackages()};
    final built = buildSessions(
      await events.between(
        firstDay.subtract(rebuildLeadIn).millisecondsSinceEpoch,
        nowMs + 1,
      ),
      idlePackages: idlePackages,
      now: now,
    );
    var daysRebuilt = 0;
    for (var day = firstDay; !day.isAfter(today); day = _nextDay(day)) {
      final end = _nextDay(day);
      bool inDay(DateTime t) => !t.isBefore(day) && t.isBefore(end);
      await sessions.replaceDay(
        day,
        end,
        [for (final s in built.sessions) if (inDay(s.start)) s],
        [for (final i in built.idle) if (inDay(i.start)) i],
      );
      daysRebuilt++;
    }

    // 5. Prune.
    await events.pruneBefore(
      DateTime(today.year, today.month, today.day - keepRawDays).millisecondsSinceEpoch,
    );

    // 6. Freeze ended days.
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final liveBlocks = await plans.allBlocks();
    for (var day = firstDay.isBefore(yesterday) ? firstDay : yesterday;
        day.isBefore(today);
        day = _nextDay(day)) {
      await plans.freezePlan(day, encodeFrozenPlan(activeBlocks(day, liveBlocks)));
    }

    // 7. Cursor.
    await meta.setInt(cursorKey, nowMs);

    // 8. Apps, once a day.
    final refreshed = await meta.getInt(appsRefreshedKey);
    if (refreshed == null ||
        localDayStart(DateTime.fromMillisecondsSinceEpoch(refreshed)) != today) {
      final list = [
        for (final m in await source.listApps()) ?AppInfo.fromMap(m),
      ];
      await apps.upsertAll(list, now);
      await meta.setInt(appsRefreshedKey, nowMs);
    }

    return IngestResult(eventsAdded: added, daysRebuilt: daysRebuilt, gapsAdded: gapsAdded);
  }

  /// One event map per line. A line that is not a JSON object fails the
  /// whole file, so it is kept rather than half-committed; an object with
  /// an unknown kind is just dropped.
  static List<RawEvent> _parseLines(String text) {
    final out = <RawEvent>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) throw FormatException('Not an event object', line);
      final event = RawEvent.fromMap(decoded);
      if (event != null) out.add(event);
    }
    return out;
  }

  /// The span a buffer file covers, from its `<fromMs>-<toMs>.jsonl`
  /// name, or null if the name has another shape.
  static (int, int)? _spanFromName(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final m = _bufferName.firstMatch(name);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  /// The parts of [span] that none of [covered] overlaps.
  static List<(int, int)> _subtract((int, int) span, List<(int, int)> covered) {
    var pieces = <(int, int)>[if (span.$2 > span.$1) span];
    for (final (cs, ce) in covered) {
      pieces = [
        for (final (s, e) in pieces) ...[
          if (cs > s) (s, math.min(e, cs)),
          if (ce < e) (math.max(s, ce), e),
        ],
      ].where((p) => p.$2 > p.$1).toList();
    }
    return pieces;
  }

  static int _minOrNull(int? a, int b) => a == null ? b : math.min(a, b);

  static DateTime _nextDay(DateTime day) => DateTime(day.year, day.month, day.day + 1);

  static Future<String> _readFile(String path) => File(path).readAsString();
}
