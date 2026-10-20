package io.github.santhoshunt.drift

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.roundToLong

/**
 * The words in the Today notifications and the block reminders, worked out
 * from the snapshot's windows. Plain Kotlin with java.time and no Android
 * types, so TodayStatusTest runs it on the JVM in any zone.
 */
object TodayStatus {
    private const val MINUTE_MS = 60_000L

    /** How long before a block "Up next" appears. */
    const val UP_NEXT_MS = 5 * MINUTE_MS

    /** How long into a block "Starting now" stays worth showing. */
    const val START_VALID_MS = 15 * MINUTE_MS

    data class Line(val title: String, val text: String)

    /** One heads-up: "up" before a block starts, or "start" as it starts. */
    data class Reminder(
        val key: String,
        val atMs: Long,
        val startsNow: Boolean,
        val block: String,
        val startMs: Long,
        val endMs: Long,
    ) {
        /** Valid until the next state replaces it, not for a fixed few
         * minutes: on a dozing phone Android may fire the alarm late. */
        fun validAt(nowMs: Long): Boolean =
            if (startsNow) nowMs >= startMs && nowMs < minOf(startMs + START_VALID_MS, endMs)
            else nowMs >= startMs - UP_NEXT_MS && nowMs < startMs
    }

    /** "45 min", "1 h 25 min" or "2 h", as formatMinutes in Dart. */
    fun minutes(min: Long): String {
        if (min < 60) return "$min min"
        val h = min / 60
        val m = min % 60
        return if (m == 0L) "$h h" else "$h h $m min"
    }

    private fun roundedMinutes(ms: Long): Long = (ms.toDouble() / MINUTE_MS).roundToLong()

    private fun ceilMinutes(ms: Long): Long = (ms + MINUTE_MS - 1) / MINUTE_MS

    /** "09:00"; a block ending at the next midnight reads "24:00", as the
     * Plan tab writes it. */
    fun clock(ms: Long, zone: ZoneId, startMs: Long? = null): String {
        val t = ZonedDateTime.ofInstant(Instant.ofEpochMilli(ms), zone)
        if (startMs != null && t.hour == 0 && t.minute == 0) {
            val startDay = ZonedDateTime.ofInstant(Instant.ofEpochMilli(startMs), zone).toLocalDate()
            if (t.toLocalDate() == startDay.plusDays(1)) return "24:00"
        }
        return "%02d:%02d".format(t.hour, t.minute)
    }

    private fun range(w: NudgeWindow, zone: ZoneId) =
        "${clock(w.startMs, zone)} to ${clock(w.endMs, zone, w.startMs)}"

    private fun day(ms: Long, zone: ZoneId): LocalDate =
        ZonedDateTime.ofInstant(Instant.ofEpochMilli(ms), zone).toLocalDate()

    /**
     * The block notification. In a block: "Now: Deep work" over "09:00 to
     * 12:00, 48 min left" (the first window in snapshot order, as nudges
     * pick it). Between blocks: "Free until 13:00" over the next block.
     * After the day's last block: "Nothing else planned today", with
     * tomorrow's first block when there is one.
     */
    fun blockLine(windows: List<NudgeWindow>, nowMs: Long, zone: ZoneId): Line {
        val current = windows.firstOrNull { it.startMs <= nowMs && nowMs < it.endMs }
        if (current != null) {
            val left = minutes(ceilMinutes(current.endMs - nowMs))
            return Line("Now: ${current.block}", "${range(current, zone)}, $left left")
        }
        val next = windows.filter { it.startMs > nowMs }.minByOrNull { it.startMs }
            ?: return Line("Nothing planned today", "Open Drift to plan your day")
        if (day(next.startMs, zone) == day(nowMs, zone)) {
            return Line(
                "Free until ${clock(next.startMs, zone)}",
                "Next: ${next.block}, ${range(next, zone)}",
            )
        }
        return Line(
            "Nothing else planned today",
            "Tomorrow: ${next.block} at ${clock(next.startMs, zone)}",
        )
    }

    /** The usage notification: "Distracting: 39 min" over "of 1 h 25 min
     * on apps". */
    fun usageLine(totalMs: Long, distractingMs: Long): Line = Line(
        "Distracting: ${minutes(roundedMinutes(distractingMs))}",
        "of ${minutes(roundedMinutes(totalMs))} on apps",
    )

    /** The bar's fill, 0 to 100. */
    fun percent(totalMs: Long, distractingMs: Long): Int =
        if (totalMs <= 0) 0 else ((100.0 * distractingMs / totalMs).roundToLong()).toInt().coerceIn(0, 100)

    /** Two heads-ups per block, in time order. Keys hold the start and the
     * name, so two blocks starting together each get theirs. */
    fun reminders(windows: List<NudgeWindow>): List<Reminder> = windows
        .flatMap { w ->
            listOf(
                Reminder("${w.startMs}:${w.block}:up", w.startMs - UP_NEXT_MS, false, w.block, w.startMs, w.endMs),
                Reminder("${w.startMs}:${w.block}:start", w.startMs, true, w.block, w.startMs, w.endMs),
            )
        }
        .sortedWith(compareBy<Reminder> { it.atMs }.thenBy { it.block })

    /** The latest reminder valid now that has not been shown yet. */
    fun due(reminders: List<Reminder>, nowMs: Long, alerted: Set<String>): Reminder? =
        reminders.filter { it.validAt(nowMs) && it.key !in alerted }.maxByOrNull { it.atMs }

    /** When the next alarm should go off: the first reminder after now. */
    fun nextAlarmMs(reminders: List<Reminder>, nowMs: Long): Long? =
        reminders.firstOrNull { it.atMs > nowMs }?.atMs

    /** The heads-up's words. "in N min" is worked out at posting time, so a
     * late alarm or a block added 3 minutes before it starts reads right. */
    fun reminderLine(r: Reminder, nowMs: Long, zone: ZoneId): Line =
        if (r.startsNow) {
            Line("Starting now: ${r.block}", "${clock(r.startMs, zone)} to ${clock(r.endMs, zone, r.startMs)}")
        } else {
            val inMin = ceilMinutes(r.startMs - nowMs).coerceAtLeast(1)
            Line("Up next: ${r.block}", "Starts at ${clock(r.startMs, zone)}, in ${minutes(inMin)}")
        }
}
