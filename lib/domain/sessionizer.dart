import 'models.dart';

/// What [buildSessions] found: app sessions and idle spans, each sorted by
/// start. They never overlap within one list; an idle span of one kind
/// can overlap another kind (screen off while locked).
class SessionizeResult {
  const SessionizeResult(this.sessions, this.idle);

  /// App sessions, without ids until stored.
  final List<Session> sessions;

  /// Screen-off, locked, shutdown and idle-app spans.
  final List<IdleSpan> idle;
}

/// How long after an app's last activity pauses a resume of the same app
/// still counts as the same session. Android reports a switch between two
/// activities of one app as "A paused, B resumed, A stopped", so the pause
/// lands a few milliseconds before the resume; without this window every
/// in-app screen change would split the session.
const sameAppResumeWindow = Duration(seconds: 5);

/// Turns raw usage events into app sessions and idle spans.
///
/// Rules, in the order they matter:
/// - Events are de-duplicated on (t, p, c, kind), because the buffer
///   files and the direct query overlap, then sorted by time. Ties keep
///   their input order, which is the order Android reported them in.
/// - A package's session runs from its first resumed activity until none
///   of its activities is resumed. A resume of the same package within
///   [sameAppResumeWindow] of that point continues the session.
/// - A session with no pause closes at the next resume of another
///   package, at screenOff, keyguardShown or shutdown, or at [now].
/// - screenOff to screenOn and keyguardShown to keyguardHidden give idle
///   spans. shutdown to startup gives a shutdown span.
/// - A startup with no shutdown before it (a crash or a battery pull)
///   closes everything at the last event before it, and the time between
///   becomes a shutdown span.
/// - Sessions of [idlePackages] (launchers, System UI, Drift itself)
///   become [IdleKind.idleApp] spans instead of sessions.
///
/// Spans of zero length are dropped. Anything still open at the end
/// closes at [now], so the session in front right now is included.
SessionizeResult buildSessions(
  List<RawEvent> events, {
  required Set<String> idlePackages,
  required DateTime now,
}) {
  return _Sessionizer(idlePackages, now.millisecondsSinceEpoch).run(events);
}

class _OpenApp {
  _OpenApp(this.startMs, String cls) : classes = {cls};

  final int startMs;
  final Set<String> classes;

  /// When the last resumed activity paused; the session ends here unless
  /// the same app resumes again within [sameAppResumeWindow].
  int? pendingCloseMs;
}

class _Sessionizer {
  _Sessionizer(this.idlePackages, this.nowMs);

  final Set<String> idlePackages;
  final int nowMs;

  final _open = <String, _OpenApp>{};
  final _sessions = <Session>[];
  final _idle = <IdleSpan>[];
  int? _screenOffSince;
  int? _lockedSince;
  int? _shutdownSince;

  SessionizeResult run(List<RawEvent> input) {
    int? lastT;
    for (final e in _dedupeAndSort(input)) {
      final cls = e.c ?? '';
      switch (e.kind) {
        case EventKind.resumed:
          _resume(e.p, cls, e.t);
        case EventKind.paused:
        case EventKind.stopped:
          final open = _open[e.p];
          if (open != null && open.pendingCloseMs == null && open.classes.remove(cls)) {
            if (open.classes.isEmpty) open.pendingCloseMs = e.t;
          }
        case EventKind.screenOff:
          _closeAllApps(e.t);
          _screenOffSince ??= e.t;
        case EventKind.screenOn:
          _closeScreenOff(e.t);
        case EventKind.keyguardShown:
          _closeAllApps(e.t);
          _lockedSince ??= e.t;
        case EventKind.keyguardHidden:
          _closeLocked(e.t);
        case EventKind.shutdown:
          _closeEverything(e.t);
          _shutdownSince ??= e.t;
        case EventKind.startup:
          final since = _shutdownSince;
          if (since != null) {
            _addIdle(since, e.t, IdleKind.shutdown);
            _shutdownSince = null;
          } else if (lastT != null) {
            _closeEverything(lastT);
            _addIdle(lastT, e.t, IdleKind.shutdown);
          }
      }
      lastT = e.t;
    }
    _closeEverything(nowMs);
    final since = _shutdownSince;
    if (since != null) _addIdle(since, nowMs, IdleKind.shutdown);

    _sessions.sort((a, b) => a.start.compareTo(b.start));
    _idle.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.kind.index.compareTo(b.kind.index);
    });
    return SessionizeResult(List.unmodifiable(_sessions), List.unmodifiable(_idle));
  }

  void _resume(String p, String cls, int t) {
    for (final other in _open.keys.where((k) => k != p).toList()) {
      _closeApp(other, t);
    }
    final open = _open[p];
    if (open == null) {
      _open[p] = _OpenApp(t, cls);
      return;
    }
    final pending = open.pendingCloseMs;
    if (pending == null) {
      open.classes.add(cls);
    } else if (t - pending <= sameAppResumeWindow.inMilliseconds) {
      open.pendingCloseMs = null;
      open.classes.add(cls);
    } else {
      _closeApp(p, t);
      _open[p] = _OpenApp(t, cls);
    }
  }

  /// Closes [p] at [atMs], or at its pending close if that came first.
  void _closeApp(String p, int atMs) {
    final open = _open.remove(p);
    if (open == null) return;
    final pending = open.pendingCloseMs;
    final end = pending != null && pending < atMs ? pending : atMs;
    if (end <= open.startMs) return;
    final start = _dt(open.startMs);
    if (idlePackages.contains(p)) {
      _idle.add(IdleSpan(start, _dt(end), IdleKind.idleApp));
    } else {
      _sessions.add(Session(p: p, start: start, end: _dt(end)));
    }
  }

  void _closeAllApps(int atMs) {
    for (final p in _open.keys.toList()) {
      _closeApp(p, atMs);
    }
  }

  void _closeScreenOff(int atMs) {
    final since = _screenOffSince;
    if (since == null) return;
    _addIdle(since, atMs, IdleKind.screenOff);
    _screenOffSince = null;
  }

  void _closeLocked(int atMs) {
    final since = _lockedSince;
    if (since == null) return;
    _addIdle(since, atMs, IdleKind.locked);
    _lockedSince = null;
  }

  void _closeEverything(int atMs) {
    _closeAllApps(atMs);
    _closeScreenOff(atMs);
    _closeLocked(atMs);
  }

  void _addIdle(int startMs, int endMs, IdleKind kind) {
    if (endMs <= startMs) return;
    _idle.add(IdleSpan(_dt(startMs), _dt(endMs), kind));
  }

  static DateTime _dt(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  /// Drops repeats and sorts by time. `List.sort` is not stable, so ties
  /// are broken by input position to keep Android's own ordering.
  static List<RawEvent> _dedupeAndSort(List<RawEvent> input) {
    final seen = <RawEvent>{};
    final unique = <(int, RawEvent)>[];
    for (final e in input) {
      if (seen.add(e)) unique.add((unique.length, e));
    }
    unique.sort((a, b) {
      final byTime = a.$2.t.compareTo(b.$2.t);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return [for (final u in unique) u.$2];
  }
}
