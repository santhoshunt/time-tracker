import '../platform/usage_source.dart';

/// The kinds of raw usage event Drift keeps. Each maps one-to-one to a
/// `k` string in [UsageEventKinds], which is what Kotlin sends and what
/// the `raw_events` table stores.
enum EventKind {
  resumed(UsageEventKinds.resumed),
  paused(UsageEventKinds.paused),
  stopped(UsageEventKinds.stopped),
  screenOn(UsageEventKinds.screenOn),
  screenOff(UsageEventKinds.screenOff),
  keyguardShown(UsageEventKinds.keyguardShown),
  keyguardHidden(UsageEventKinds.keyguardHidden),
  shutdown(UsageEventKinds.shutdown),
  startup(UsageEventKinds.startup);

  const EventKind(this.key);

  /// The wire and database spelling.
  final String key;

  static final Map<String, EventKind> _byKey = {
    for (final k in EventKind.values) k.key: k,
  };

  /// Null for a kind this version does not know, so a newer Kotlin side
  /// can add kinds without breaking an older Dart side.
  static EventKind? fromKey(String? key) => key == null ? null : _byKey[key];
}

/// One usage event as Android reported it. [t] is UTC milliseconds,
/// [p] the package and [c] the activity class (null for screen,
/// keyguard and power events).
class RawEvent {
  const RawEvent(this.t, this.p, this.c, this.kind);

  final int t;
  final String p;
  final String? c;
  final EventKind kind;

  /// Parses the `{"t", "p", "c", "k"}` map from the usage channel or a
  /// buffer file line. Returns null for an unknown kind or a malformed
  /// map, so one odd event is dropped instead of failing a whole batch.
  static RawEvent? fromMap(Map<dynamic, dynamic> map) {
    final t = map['t'];
    final p = map['p'];
    final c = map['c'];
    final kind = EventKind.fromKey(map['k'] is String ? map['k'] as String : null);
    if (t is! num || p is! String || kind == null) return null;
    if (c != null && c is! String) return null;
    return RawEvent(t.toInt(), p, c as String?, kind);
  }

  /// The channel and buffer-file shape, the inverse of [fromMap].
  Map<String, Object?> toMap() => {'t': t, 'p': p, 'c': c, 'k': kind.key};

  @override
  bool operator ==(Object other) =>
      other is RawEvent &&
      other.t == t &&
      other.p == p &&
      other.c == c &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(t, p, c, kind);

  @override
  String toString() => 'RawEvent($t, $p, $c, ${kind.key})';
}

/// A stretch of time one app was in the foreground. [id] is the
/// `sessions` row id once stored; overrides are keyed by it.
class Session {
  const Session({this.id, required this.p, required this.start, required this.end});

  final int? id;
  final String p;
  final DateTime start;
  final DateTime end;

  /// How long the app was in front.
  Duration get duration => end.difference(start);

  /// A copy with a stored id or a later end; package and start are the
  /// session's identity and never change.
  Session copyWith({int? id, DateTime? end}) =>
      Session(id: id ?? this.id, p: p, start: start, end: end ?? this.end);

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.id == id &&
      other.p == p &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(id, p, start, end);

  @override
  String toString() => 'Session($id, $p, $start, $end)';
}

/// Why the phone was not in use. [idleApp] covers time in a launcher,
/// in `com.android.systemui` or in Drift itself: the screen is on, but
/// no tracked app is in front.
enum IdleKind {
  screenOff('screenOff'),
  locked('locked'),
  shutdown('shutdown'),
  idleApp('idleApp');

  const IdleKind(this.key);

  /// The `idle_spans.kind` spelling.
  final String key;

  static IdleKind fromKey(String key) =>
      IdleKind.values.firstWhere((k) => k.key == key, orElse: () => IdleKind.screenOff);
}

/// Time the phone was idle. Inside a block it counts as on track.
class IdleSpan {
  const IdleSpan(this.start, this.end, this.kind);

  final DateTime start;
  final DateTime end;
  final IdleKind kind;

  @override
  bool operator ==(Object other) =>
      other is IdleSpan && other.start == start && other.end == end && other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);

  @override
  String toString() => 'IdleSpan(${kind.key}, $start, $end)';
}

/// Time Android no longer held events for and no buffer file covered.
/// It shows as "No data" and stays out of the score.
class GapSpan {
  const GapSpan(this.start, this.end);

  final DateTime start;
  final DateTime end;

  @override
  bool operator ==(Object other) =>
      other is GapSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'GapSpan($start, $end)';
}

/// A block as the user wrote it. Times are minutes from local midnight
/// so a block keeps its wall-clock time across time-zone changes.
///
/// [repeatMask] has bit 0 for Monday through bit 6 for Sunday. When it is
/// 0 the block is a one-off on [date] (yyyy-MM-dd). [skipDates] lists
/// dates a repeating block sits out, written by "This day only" edits.
/// [anyApp] means every app counts as on track inside the block.
class PlanBlock {
  const PlanBlock({
    this.id,
    required this.name,
    required this.startMin,
    required this.endMin,
    this.colorIdx = 0,
    this.repeatMask = 0,
    this.date,
    this.skipDates = const [],
    this.anyApp = false,
  });

  final int? id;
  final String name;
  final int startMin;
  final int endMin;
  final int colorIdx;
  final int repeatMask;
  final String? date;
  final List<String> skipDates;
  final bool anyApp;

  /// Every day of the week, Monday to Sunday.
  static const everyDay = 0x7F;

  /// Monday to Friday.
  static const weekdays = 0x1F;

  /// A copy with the given fields changed, for editor drafts. A null
  /// argument keeps the current value, so [date] cannot be cleared here.
  PlanBlock copyWith({
    int? id,
    String? name,
    int? startMin,
    int? endMin,
    int? colorIdx,
    int? repeatMask,
    String? date,
    List<String>? skipDates,
    bool? anyApp,
  }) =>
      PlanBlock(
        id: id ?? this.id,
        name: name ?? this.name,
        startMin: startMin ?? this.startMin,
        endMin: endMin ?? this.endMin,
        colorIdx: colorIdx ?? this.colorIdx,
        repeatMask: repeatMask ?? this.repeatMask,
        date: date ?? this.date,
        skipDates: skipDates ?? this.skipDates,
        anyApp: anyApp ?? this.anyApp,
      );

  /// The shape stored in `templates.blocks_json` and
  /// `day_plans.blocks_json`.
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'startMin': startMin,
        'endMin': endMin,
        'colorIdx': colorIdx,
        'repeatMask': repeatMask,
        'date': date,
        'skipDates': skipDates,
        'anyApp': anyApp,
      };

  /// The inverse of [toJson]. Missing fields take their defaults, so a
  /// template saved by an older version still loads.
  factory PlanBlock.fromJson(Map<String, dynamic> json) => PlanBlock(
        id: (json['id'] as num?)?.toInt(),
        name: json['name'] as String? ?? '',
        startMin: (json['startMin'] as num?)?.toInt() ?? 0,
        endMin: (json['endMin'] as num?)?.toInt() ?? 0,
        colorIdx: (json['colorIdx'] as num?)?.toInt() ?? 0,
        repeatMask: (json['repeatMask'] as num?)?.toInt() ?? 0,
        date: json['date'] as String?,
        skipDates: [
          for (final d in (json['skipDates'] as List<dynamic>? ?? const [])) d as String,
        ],
        anyApp: json['anyApp'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is PlanBlock &&
      other.id == id &&
      other.name == name &&
      other.startMin == startMin &&
      other.endMin == endMin &&
      other.colorIdx == colorIdx &&
      other.repeatMask == repeatMask &&
      other.date == date &&
      other.anyApp == anyApp &&
      other.skipDates.length == skipDates.length &&
      Iterable<int>.generate(skipDates.length).every((i) => other.skipDates[i] == skipDates[i]);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        startMin,
        endMin,
        colorIdx,
        repeatMask,
        date,
        Object.hashAll(skipDates),
        anyApp,
      );

  @override
  String toString() => 'PlanBlock($id, $name, $startMin-$endMin, mask $repeatMask, $date)';
}

/// A saved set of blocks the Plan tab can apply to a day in one tap.
class PlanTemplate {
  const PlanTemplate({this.id, required this.name, required this.blocks});

  /// The `templates` row id, null before saving.
  final int? id;

  /// Unique; saving under an existing name replaces that template.
  final String name;

  /// The blocks as they were when saved, ids included.
  final List<PlanBlock> blocks;
}

/// A block placed on a real day, with instants instead of minutes.
class ResolvedBlock {
  const ResolvedBlock({
    required this.name,
    required this.start,
    required this.end,
    this.anyApp = false,
    this.colorIdx = 0,
  });

  final String name;
  final DateTime start;
  final DateTime end;
  final bool anyApp;
  final int colorIdx;

  @override
  bool operator ==(Object other) =>
      other is ResolvedBlock &&
      other.name == name &&
      other.start == start &&
      other.end == end &&
      other.anyApp == anyApp &&
      other.colorIdx == colorIdx;

  @override
  int get hashCode => Object.hash(name, start, end, anyApp, colorIdx);

  @override
  String toString() => 'ResolvedBlock($name, $start, $end)';
}

/// How a slice of the day went against the plan. The guessed verdicts
/// come from the app's category and show amber until the user answers.
///
/// [neutral] is an answer: the app is fine in that block without being
/// on track. It scores like on track but holds only for that block, so
/// the app still counts as distracting across the day.
enum Verdict { onTrack, offTrack, neutral, guessedOn, guessedOff, idle, unplanned, noData }

/// One classified slice of a day. [p] is null for idle, unplanned idle
/// and no-data time; [sessionId] links back to the session for asks.
class Segment {
  const Segment({
    this.p,
    required this.start,
    required this.end,
    required this.verdict,
    this.blockName,
    this.sessionId,
  });

  final String? p;
  final DateTime start;
  final DateTime end;
  final Verdict verdict;
  final String? blockName;
  final int? sessionId;

  /// The slice's length; sums of these give the day's totals.
  Duration get duration => end.difference(start);

  @override
  bool operator ==(Object other) =>
      other is Segment &&
      other.p == p &&
      other.start == start &&
      other.end == end &&
      other.verdict == verdict &&
      other.blockName == blockName &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(p, start, end, verdict, blockName, sessionId);

  @override
  String toString() =>
      'Segment(${verdict.name}, $p, $start, $end, $blockName, $sessionId)';
}

/// The day's score card. [percent] is the share of planned, known time
/// that was on track.
class DayScore {
  const DayScore({
    required this.plannedMin,
    required this.offMin,
    required this.idleMin,
    required this.noDataMin,
    required this.percent,
  });

  /// Block time up to now, overlapping blocks counted once.
  final int plannedMin;

  /// Off-track and guessed-off time inside blocks.
  final int offMin;

  /// Idle time inside blocks; already counted as on track.
  final int idleMin;

  /// Time inside blocks with no data; left out of [percent].
  final int noDataMin;

  /// 0 to 100.
  final int percent;

  @override
  bool operator ==(Object other) =>
      other is DayScore &&
      other.plannedMin == plannedMin &&
      other.offMin == offMin &&
      other.idleMin == idleMin &&
      other.noDataMin == noDataMin &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(plannedMin, offMin, idleMin, noDataMin, percent);

  @override
  String toString() =>
      'DayScore(planned $plannedMin, off $offMin, idle $idleMin, noData $noDataMin, $percent%)';
}

/// A launchable app as the block editor lists it.
class AppInfo {
  const AppInfo({required this.p, required this.label, required this.category});

  final String p;
  final String label;
  final String category;

  /// Parses a `listApps` map. An unknown category becomes `undefined`,
  /// which guesses on track.
  static AppInfo? fromMap(Map<dynamic, dynamic> map) {
    final p = map['p'];
    if (p is! String || p.isEmpty) return null;
    final label = map['label'];
    final category = map['category'];
    return AppInfo(
      p: p,
      label: label is String ? label : p,
      category: category is String && AppCategories.all.contains(category)
          ? category
          : AppCategories.undefined,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppInfo && other.p == p && other.label == label && other.category == category;

  @override
  int get hashCode => Object.hash(p, label, category);

  @override
  String toString() => 'AppInfo($p, $label, $category)';
}

/// The key `app_rules` stores for a block: its name trimmed and
/// lower-cased, so "Deep work" and "deep work " share learned rules.
String blockKey(String name) => name.trim().toLowerCase();

/// yyyy-MM-dd of [day] in its own zone, the form `blocks.date`,
/// `skip_dates` and `day_plans.date` use.
String dateKey(DateTime day) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}';
}

/// Local midnight at the start of [t]'s day. Built from the calendar
/// fields, never by subtracting hours, so 23- and 25-hour days work.
DateTime localDayStart(DateTime t) {
  final local = t.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Local midnight at the end of [t]'s day.
DateTime localDayEnd(DateTime t) {
  final local = t.toLocal();
  return DateTime(local.year, local.month, local.day + 1);
}
