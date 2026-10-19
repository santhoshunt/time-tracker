package io.github.santhoshunt.drift

import org.json.JSONArray
import org.json.JSONObject

/** One plan block from the snapshot, in epoch milliseconds, end exclusive. */
data class NudgeWindow(
    val startMs: Long,
    val endMs: Long,
    val block: String,
    val anyApp: Boolean,
    val on: Set<String>,
    val off: Set<String>,
)

/**
 * The user's theme as opaque ARGB ints, so the overlay matches the app.
 * The defaults are a dark theme with light text, used when Dart wrote no
 * colours or a colour that is not `#RRGGBB`.
 */
data class NudgeColors(
    val bg: Int = 0xFF121212.toInt(),
    val card: Int = 0xFF1E1E24.toInt(),
    val text: Int = 0xFFF0F4FF.toInt(),
    val textSecondary: Int = 0xFFAAB8D4.toInt(),
    val accent: Int = 0xFF8AB4F8.toInt(),
    val onAccent: Int = 0xFF0B1A33.toInt(),
) {
    companion object {
        private val HEX = Regex("^#[0-9A-Fa-f]{6}$")

        fun parse(json: JSONObject?): NudgeColors {
            val d = NudgeColors()
            if (json == null) return d
            fun color(key: String, fallback: Int): Int {
                val s = json.opt(key) as? String ?: return fallback
                if (!HEX.matches(s)) return fallback
                return (0xFF000000 or s.substring(1).toLong(16)).toInt()
            }
            return NudgeColors(
                bg = color("bg", d.bg),
                card = color("card", d.card),
                text = color("text", d.text),
                textSecondary = color("textSecondary", d.textSecondary),
                accent = color("accent", d.accent),
                onAccent = color("onAccent", d.onAccent),
            )
        }
    }
}

/**
 * What Dart wrote to filesDir/nudge_snapshot.json: the nudge settings and
 * the plan windows for the rest of today and tomorrow.
 *
 * Only version 1 is understood. [parse] checks every value's type itself
 * instead of relying on JSONObject's getters, because Android's org.json
 * turns a number into a string where the JVM test library throws; checking
 * types makes both agree on what is malformed.
 */
data class NudgeSnapshot(
    val writtenAtMs: Long,
    val enabled: Boolean,
    val nudgeAfterMin: Int,
    val repeatMin: Int,
    val quietStartMin: Int,
    val quietEndMin: Int,
    val guessOffCategories: Set<String>,
    val windows: List<NudgeWindow>,
    val colors: NudgeColors,
    /** Focus lock: an app ruled off for the block locks at once. Optional
     * in the file, false when absent, so `v` stays 1. */
    val lock: Boolean = false,
) {
    companion object {
        /** The snapshot, or null when anything required is missing or of
         * the wrong type. The service then does nothing until Dart writes a
         * good one. A missing or bad colour falls back to the default. */
        fun parse(json: JSONObject): NudgeSnapshot? {
            if (json.int("v") != 1) return null
            val windowsJson = json.opt("windows") as? JSONArray ?: return null
            val windows = ArrayList<NudgeWindow>(windowsJson.length())
            for (i in 0 until windowsJson.length()) {
                val w = windowsJson.opt(i) as? JSONObject ?: return null
                windows.add(
                    NudgeWindow(
                        startMs = w.long("startMs") ?: return null,
                        endMs = w.long("endMs") ?: return null,
                        block = w.opt("block") as? String ?: return null,
                        anyApp = w.opt("anyApp") as? Boolean ?: return null,
                        on = w.strings("on") ?: return null,
                        off = w.strings("off") ?: return null,
                    )
                )
            }
            return NudgeSnapshot(
                writtenAtMs = json.long("writtenAtMs") ?: return null,
                enabled = json.opt("enabled") as? Boolean ?: return null,
                nudgeAfterMin = json.int("nudgeAfterMin") ?: return null,
                repeatMin = json.int("repeatMin") ?: return null,
                quietStartMin = json.int("quietStartMin") ?: return null,
                quietEndMin = json.int("quietEndMin") ?: return null,
                guessOffCategories = json.strings("guessOffCategories") ?: return null,
                windows = windows,
                colors = NudgeColors.parse(json.opt("colors") as? JSONObject),
                lock = json.opt("lock") as? Boolean ?: false,
            )
        }

        /** Whole numbers only: 5.5 minutes is a writer bug, not a value. */
        private fun JSONObject.long(key: String): Long? {
            val n = opt(key) as? Number ?: return null
            val l = n.toLong()
            return if (n.toDouble() == l.toDouble()) l else null
        }

        private fun JSONObject.int(key: String): Int? {
            val l = long(key) ?: return null
            return if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else null
        }

        private fun JSONObject.strings(key: String): Set<String>? {
            val a = opt(key) as? JSONArray ?: return null
            val out = LinkedHashSet<String>()
            for (i in 0 until a.length()) out.add(a.opt(i) as? String ?: return null)
            return out
        }
    }
}

sealed class NudgeDecision {
    object None : NudgeDecision()

    data class Nudge(
        val block: String,
        val minutesOff: Long,
        val minutesLeft: Long,
        /** Show the lock card (hold to open) instead of the nudge. */
        val lock: Boolean = false,
    ) : NudgeDecision()
}

/**
 * Whether the app in front right now earns a nudge.
 *
 * Plain Kotlin with no Android types, so the JVM unit tests run it against
 * test/fixtures/nudge_cases.json, the same file the Dart copy of this rule
 * is tested with. The two must stay identical; change the fixture first.
 */
object NudgeDecider {
    private const val MINUTE_MS = 60_000L
    private const val STALE_MS = 36L * 60 * MINUTE_MS
    private const val DAY_MIN = 24 * 60

    fun decide(
        snapshot: NudgeSnapshot,
        nowMs: Long,
        nowLocalMin: Int,
        pkg: String,
        category: String,
        continuousMs: Long,
        lastNudgeMs: Long?,
        snoozedUntilMs: Long?,
    ): NudgeDecision {
        if (!snapshot.enabled) return NudgeDecision.None
        // A snapshot Dart has not refreshed in 36 hours describes a plan
        // that is probably out of date.
        if (nowMs - snapshot.writtenAtMs > STALE_MS) return NudgeDecision.None
        if (inQuietHours(snapshot.quietStartMin, snapshot.quietEndMin, nowLocalMin)) {
            return NudgeDecision.None
        }
        val window = snapshot.windows.firstOrNull { it.startMs <= nowMs && nowMs < it.endMs }
            ?: return NudgeDecision.None
        if (window.anyApp || pkg in window.on) return NudgeDecision.None
        // An explicit rule wins; otherwise only the guessed-off categories
        // count, so an untagged app is on track by default.
        val ruledOff = pkg in window.off
        val offTrack = ruledOff || category in snapshot.guessOffCategories
        if (!offTrack) return NudgeDecision.None
        // Only an app the user ruled off locks; a category guess keeps the
        // nudge and both waits, so an unasked messaging app is never locked.
        val lock = snapshot.lock && ruledOff
        if (!lock) {
            if (continuousMs < snapshot.nudgeAfterMin * MINUTE_MS) return NudgeDecision.None
            if (lastNudgeMs != null && nowMs - lastNudgeMs < snapshot.repeatMin * MINUTE_MS) {
                return NudgeDecision.None
            }
        }
        if (snoozedUntilMs != null && snoozedUntilMs > nowMs) return NudgeDecision.None
        return NudgeDecision.Nudge(
            block = window.block,
            minutesOff = continuousMs / MINUTE_MS,
            minutesLeft = (window.endMs - nowMs + MINUTE_MS - 1) / MINUTE_MS,
            lock = lock,
        )
    }

    /** [start, end) on a 24-hour clock; 22:00 to 07:00 wraps midnight.
     * Equal ends mean no quiet hours at all. */
    fun inQuietHours(startMin: Int, endMin: Int, nowMin: Int): Boolean {
        if (startMin == endMin) return false
        val now = ((nowMin % DAY_MIN) + DAY_MIN) % DAY_MIN
        return if (startMin < endMin) {
            now in startMin until endMin
        } else {
            now >= startMin || now < endMin
        }
    }
}

/**
 * Finds the app in front, and since when, from usage events.
 *
 * Android records no "this app is in front" fact, only activity resumes and
 * pauses, so the front app is the latest resumed package that has not
 * paused or stopped since. Events use UsageEventMapper's kind strings, which
 * keeps this free of Android types and covered by the JVM tests.
 */
object ForegroundRun {
    /** A same-package resume this soon after its pause continues the run:
     * Android pauses the old screen before it resumes the new one. */
    const val HANDOFF_MS = 5_000L

    data class Event(val t: Long, val pkg: String, val cls: String?, val kind: String)

    data class Run(val pkg: String, val startMs: Long)

    /**
     * The package in front at the end of [events] (oldest first) and when
     * its current run began, or null when nothing countable is in front.
     *
     * Events from [ignored] packages (Drift itself, System UI, launchers)
     * are skipped entirely: leaving an app for the home screen already
     * pauses it, and skipping keeps a notification-shade resume, which some
     * ROMs log, from cutting a run short. A launcher in front therefore
     * reads as nothing in front.
     */
    fun find(events: List<Event>, ignored: Set<String>): Run? {
        var pkg: String? = null
        var start = 0L
        // Activities of [pkg] resumed and not yet paused or stopped.
        val resumed = HashSet<String>()
        // When [pkg] last had no resumed activity, or null while it has one.
        var pausedAt: Long? = null
        for (e in events) {
            when (e.kind) {
                "screenOff", "keyguardShown", "shutdown" -> {
                    pkg = null
                    resumed.clear()
                    pausedAt = null
                }
                "resumed" -> {
                    if (e.pkg in ignored) continue
                    val gap = pausedAt
                    val continues = e.pkg == pkg &&
                        (gap == null || e.t - gap <= HANDOFF_MS)
                    if (!continues) {
                        pkg = e.pkg
                        start = e.t
                        resumed.clear()
                    }
                    resumed.add(e.cls ?: "")
                    pausedAt = null
                }
                "paused", "stopped" -> {
                    if (e.pkg != pkg) continue
                    resumed.remove(e.cls ?: "")
                    if (resumed.isEmpty() && pausedAt == null) pausedAt = e.t
                }
            }
        }
        val front = pkg ?: return null
        if (pausedAt != null) return null
        return Run(front, start)
    }
}
