import 'dart:math' as math;

import 'category_guess.dart' as guess;
import 'models.dart';

/// One planned block as the nudge service sees it: when it runs and which
/// apps the user has already judged for it.
class NudgeWindow {
  const NudgeWindow({
    required this.startMs,
    required this.endMs,
    required this.block,
    required this.anyApp,
    required this.on,
    required this.off,
  });

  final int startMs;
  final int endMs;
  final String block;
  final bool anyApp;
  final Set<String> on;
  final Set<String> off;

  Map<String, Object?> toJson() => {
    'startMs': startMs,
    'endMs': endMs,
    'block': block,
    'anyApp': anyApp,
    'on': on.toList()..sort(),
    'off': off.toList()..sort(),
  };

  factory NudgeWindow.fromJson(Map<String, dynamic> j) => NudgeWindow(
    startMs: (j['startMs'] as num).toInt(),
    endMs: (j['endMs'] as num).toInt(),
    block: j['block'] as String,
    anyApp: j['anyApp'] as bool? ?? false,
    on: {for (final p in j['on'] as List<dynamic>? ?? const []) p as String},
    off: {for (final p in j['off'] as List<dynamic>? ?? const []) p as String},
  );
}

/// Everything the Android nudge service needs, written by Dart to
/// nudge_snapshot.json in the app's files folder. Kotlin's NudgeDecider
/// applies [decideNudge]'s rule to it, so the plan logic lives here and
/// the service only looks things up.
class NudgeSnapshot {
  const NudgeSnapshot({
    required this.writtenAtMs,
    required this.enabled,
    required this.nudgeAfterMin,
    required this.repeatMin,
    required this.quietStartMin,
    required this.quietEndMin,
    required this.windows,
    this.guessOffCategories = guess.guessOffCategories,
    this.colors = const {},
    this.lock = false,
    this.status = false,
    this.reminders = false,
    this.offApps = const {},
    this.onApps = const {},
  });

  final int writtenAtMs;
  final bool enabled;
  final int nudgeAfterMin;
  final int repeatMin;
  final int quietStartMin;
  final int quietEndMin;
  final Set<String> guessOffCategories;
  final List<NudgeWindow> windows;

  /// The theme's colours as "#RRGGBB", so the overlay matches the app.
  final Map<String, String> colors;

  /// Focus lock: an app ruled off track for the block is locked at once
  /// instead of nudged after a wait. Written without bumping `v`, and
  /// read as false when absent, so older and newer builds agree.
  final bool lock;

  /// "Today in notifications": the block now and today's distracting time.
  final bool status;

  /// "Block reminders": heads-ups 5 minutes before and at each block start.
  final bool reminders;

  /// Packages with an off-track rule for any block: always distracting.
  final Set<String> offApps;

  /// Packages with an on-track rule and no off-track rule: never
  /// distracting, whatever their category guesses.
  final Set<String> onApps;

  /// A snapshot this old is ignored: the plan in it may no longer be the
  /// plan, and a wrong nudge is worse than none.
  static const maxAge = Duration(hours: 36);

  Map<String, Object?> toJson() => {
    'v': 1,
    'writtenAtMs': writtenAtMs,
    'enabled': enabled,
    'nudgeAfterMin': nudgeAfterMin,
    'repeatMin': repeatMin,
    'quietStartMin': quietStartMin,
    'quietEndMin': quietEndMin,
    'guessOffCategories': guessOffCategories.toList()..sort(),
    'windows': [for (final w in windows) w.toJson()],
    'colors': colors,
    'lock': lock,
    'status': status,
    'reminders': reminders,
    'offApps': offApps.toList()..sort(),
    'onApps': onApps.toList()..sort(),
  };

  factory NudgeSnapshot.fromJson(Map<String, dynamic> j) => NudgeSnapshot(
    writtenAtMs: (j['writtenAtMs'] as num).toInt(),
    enabled: j['enabled'] as bool? ?? false,
    nudgeAfterMin: (j['nudgeAfterMin'] as num?)?.toInt() ?? 5,
    repeatMin: (j['repeatMin'] as num?)?.toInt() ?? 15,
    quietStartMin: (j['quietStartMin'] as num?)?.toInt() ?? 0,
    quietEndMin: (j['quietEndMin'] as num?)?.toInt() ?? 0,
    guessOffCategories: {
      for (final c in j['guessOffCategories'] as List<dynamic>? ?? const [])
        c as String,
    },
    windows: [
      for (final w in j['windows'] as List<dynamic>? ?? const [])
        NudgeWindow.fromJson(w as Map<String, dynamic>),
    ],
    colors: {
      for (final e in (j['colors'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: e.value as String,
    },
    lock: j['lock'] as bool? ?? false,
    status: j['status'] as bool? ?? false,
    reminders: j['reminders'] as bool? ?? false,
    offApps: {for (final p in j['offApps'] as List<dynamic>? ?? const []) p as String},
    onApps: {for (final p in j['onApps'] as List<dynamic>? ?? const []) p as String},
  );
}

/// The apps the distracting-time count treats specially, from the learned
/// rules: (always distracting, never distracting). An off-track rule for
/// any block wins over an on-track rule for another.
(Set<String>, Set<String>) distractingRuleSets(Map<(String, String), Verdict> rules) {
  final off = <String>{};
  final on = <String>{};
  for (final MapEntry(key: (_, p), :value) in rules.entries) {
    if (value == Verdict.offTrack) off.add(p);
    if (value == Verdict.onTrack) on.add(p);
  }
  return (off, on.difference(off));
}

/// What [decideNudge] concluded.
sealed class NudgeDecision {
  const NudgeDecision();
}

class NoNudge extends NudgeDecision {
  const NoNudge();
}

class Nudge extends NudgeDecision {
  const Nudge({
    required this.block,
    required this.minutesOff,
    required this.minutesLeft,
    this.lock = false,
  });

  final String block;
  final int minutesOff;
  final int minutesLeft;

  /// Show the lock card (hold to open) instead of the nudge.
  final bool lock;
}

/// Whether to nudge now. The same rule as NudgeDecider.kt, checked
/// against the same cases in test/fixtures/nudge_cases.json.
///
/// [nowLocalMin] is the local minute of the day, passed in so the rule
/// stays pure. [continuousMs] is how long [pkg] has been in front without
/// a break.
NudgeDecision decideNudge(
  NudgeSnapshot s, {
  required int nowMs,
  required int nowLocalMin,
  required String pkg,
  required String category,
  required int continuousMs,
  int? lastNudgeMs,
  int? snoozedUntilMs,
}) {
  if (!s.enabled) return const NoNudge();
  if (nowMs - s.writtenAtMs > NudgeSnapshot.maxAge.inMilliseconds) {
    return const NoNudge();
  }
  if (_inQuietHours(nowLocalMin, s.quietStartMin, s.quietEndMin)) {
    return const NoNudge();
  }
  NudgeWindow? window;
  for (final w in s.windows) {
    if (w.startMs <= nowMs && nowMs < w.endMs) window = w;
  }
  if (window == null) return const NoNudge();
  if (window.anyApp || window.on.contains(pkg)) return const NoNudge();
  final ruledOff = window.off.contains(pkg);
  final off = ruledOff || s.guessOffCategories.contains(category);
  if (!off) return const NoNudge();
  // Only an app the user ruled off locks. A guess from the category alone
  // could lock a messaging app nobody was asked about, so it keeps the
  // nudge and both waits.
  final lock = s.lock && ruledOff;
  if (!lock) {
    if (continuousMs < s.nudgeAfterMin * 60000) return const NoNudge();
    if (lastNudgeMs != null && nowMs - lastNudgeMs < s.repeatMin * 60000) {
      return const NoNudge();
    }
  }
  if (snoozedUntilMs != null && snoozedUntilMs > nowMs) {
    return const NoNudge();
  }
  return Nudge(
    block: window.block,
    minutesOff: continuousMs ~/ 60000,
    minutesLeft: ((window.endMs - nowMs) / 60000).ceil(),
    lock: lock,
  );
}

/// Quiet hours run from [start] up to [end], wrapping past midnight when
/// [end] is earlier. Equal ends mean there are no quiet hours.
bool _inQuietHours(int minute, int start, int end) {
  if (start == end) return false;
  return start < end
      ? minute >= start && minute < end
      : minute >= start || minute < end;
}

/// Builds the windows for [blocks] (today's and tomorrow's, already placed
/// on their days) from the learned rules, keeping only what has not ended
/// by [now].
List<NudgeWindow> nudgeWindows({
  required List<ResolvedBlock> blocks,
  required Map<(String, String), Verdict> rules,
  required DateTime now,
}) {
  final byKey = <String, (Set<String>, Set<String>)>{};
  for (final MapEntry(key: (key, p), :value) in rules.entries) {
    final sets = byKey.putIfAbsent(key, () => (<String>{}, <String>{}));
    if (value == Verdict.onTrack) sets.$1.add(p);
    if (value == Verdict.offTrack) sets.$2.add(p);
  }
  final nowMs = now.millisecondsSinceEpoch;
  return [
    for (final b in blocks)
      if (b.end.millisecondsSinceEpoch > nowMs)
        NudgeWindow(
          startMs: math.max(b.start.millisecondsSinceEpoch, 0),
          endMs: b.end.millisecondsSinceEpoch,
          block: b.name,
          anyApp: b.anyApp,
          on: byKey[blockKey(b.name)]?.$1 ?? const {},
          off: byKey[blockKey(b.name)]?.$2 ?? const {},
        ),
  ];
}
