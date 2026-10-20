package io.github.santhoshunt.drift

/**
 * The session rules of lib/domain/sessionizer.dart, line for line, so the
 * Today notification counts app time exactly as the Usage tab does. Only
 * sessions come out; idle spans are not needed here.
 *
 * Plain Kotlin with no Android types: DayUsageTest runs it on
 * test/fixtures/usage_count_cases.json, the file the Dart copy is tested
 * with. Change the fixture first, then both copies.
 */
object DaySessionizer {
    /** sameAppResumeWindow in the Dart copy. */
    const val SAME_APP_RESUME_MS = 5_000L

    data class Session(val pkg: String, val startMs: Long, val endMs: Long)

    private class Open(val startMs: Long, cls: String) {
        val classes = HashSet<String>().apply { add(cls) }
        var pendingCloseMs: Long? = null
    }

    fun sessions(events: List<ForegroundRun.Event>, idle: Set<String>, nowMs: Long): List<Session> {
        val open = LinkedHashMap<String, Open>()
        val out = ArrayList<Session>()

        fun closeApp(p: String, atMs: Long) {
            val o = open.remove(p) ?: return
            val pending = o.pendingCloseMs
            val end = if (pending != null && pending < atMs) pending else atMs
            if (end <= o.startMs) return
            if (p !in idle) out.add(Session(p, o.startMs, end))
        }

        fun closeAll(atMs: Long) {
            for (p in open.keys.toList()) closeApp(p, atMs)
        }

        var lastT: Long? = null
        var shutdownSince: Long? = null
        for (e in dedupeAndSort(events)) {
            val cls = e.cls ?: ""
            when (e.kind) {
                "resumed" -> {
                    for (other in open.keys.filter { it != e.pkg }) closeApp(other, e.t)
                    val o = open[e.pkg]
                    if (o == null) {
                        open[e.pkg] = Open(e.t, cls)
                    } else {
                        val pending = o.pendingCloseMs
                        if (pending == null) {
                            o.classes.add(cls)
                        } else if (e.t - pending <= SAME_APP_RESUME_MS) {
                            o.pendingCloseMs = null
                            o.classes.add(cls)
                        } else {
                            closeApp(e.pkg, e.t)
                            open[e.pkg] = Open(e.t, cls)
                        }
                    }
                }
                "paused", "stopped" -> {
                    val o = open[e.pkg]
                    if (o != null && o.pendingCloseMs == null && o.classes.remove(cls)) {
                        if (o.classes.isEmpty()) o.pendingCloseMs = e.t
                    }
                }
                "screenOff", "keyguardShown" -> closeAll(e.t)
                "shutdown" -> {
                    closeAll(e.t)
                    if (shutdownSince == null) shutdownSince = e.t
                }
                "startup" -> {
                    if (shutdownSince != null) {
                        shutdownSince = null
                    } else if (lastT != null) {
                        closeAll(lastT)
                    }
                }
            }
            lastT = e.t
        }
        closeAll(nowMs)
        return out.sortedBy { it.startMs }
    }

    /** Drops repeats on (t, pkg, cls, kind) and sorts by time; sortedBy is
     * stable, so ties keep Android's order, as the Dart copy does. */
    private fun dedupeAndSort(input: List<ForegroundRun.Event>): List<ForegroundRun.Event> {
        val seen = HashSet<ForegroundRun.Event>()
        return input.filter { seen.add(it) }.sortedBy { it.t }
    }
}

/**
 * Today's app time and its distracting share, as countDayUsage in
 * lib/domain/day_usage.dart works them out.
 */
object DayUsage {
    const val DRIFT_PACKAGE = "io.github.santhoshunt.drift"

    data class Counted(val totalMs: Long, val distractingMs: Long)

    /** An off-track rule for any block makes an app distracting; otherwise
     * a guessed-off category does, unless an on-track rule claims it. */
    fun isDistracting(
        pkg: String,
        category: String,
        offApps: Set<String>,
        onApps: Set<String>,
        guessOff: Set<String>,
    ): Boolean = pkg in offApps || (pkg !in onApps && category in guessOff)

    /** [events] may start before [dayStartMs]: the caller reads extra
     * history so an app already open at midnight is seen, and sessions are
     * clipped to [dayStartMs, nowMs] here. */
    fun count(
        events: List<ForegroundRun.Event>,
        dayStartMs: Long,
        nowMs: Long,
        idle: Set<String>,
        launchable: Set<String>,
        categoryOf: (String) -> String,
        offApps: Set<String>,
        onApps: Set<String>,
        guessOff: Set<String>,
    ): Counted {
        var total = 0L
        var distracting = 0L
        for (s in DaySessionizer.sessions(events, idle, nowMs)) {
            if (s.pkg == DRIFT_PACKAGE) continue
            if (launchable.isNotEmpty() && s.pkg !in launchable) continue
            val from = maxOf(s.startMs, dayStartMs)
            val to = minOf(s.endMs, nowMs)
            if (to <= from) continue
            total += to - from
            if (isDistracting(s.pkg, categoryOf(s.pkg), offApps, onApps, guessOff)) {
                distracting += to - from
            }
        }
        return Counted(total, distracting)
    }
}
