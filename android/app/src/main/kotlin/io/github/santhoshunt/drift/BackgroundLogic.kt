package io.github.santhoshunt.drift

/** How one background Dart run ended, as the workers see it. */
enum class RunOutcome {
    /** Dart ran every step and said so. */
    OK,

    /** Dart ran but a step failed, or it never reported back in time. */
    FAILED,

    /** Nothing ran: the app's engine had no handler yet (BootApp still
     * starting), or another headless run was going. */
    BUSY,
}

/**
 * The decisions the background workers make, kept free of Android types so
 * JVM unit tests cover them (BackgroundLogicTest).
 */
object BackgroundLogic {
    /** WorkManager wants a delay, Dart sends a moment. A moment already
     * past runs at once instead of being refused. */
    fun delayMs(targetMs: Long, nowMs: Long): Long = (targetMs - nowMs).coerceAtLeast(0L)

    /** The live engine's runBackground reply (lib/platform/background_bridge.dart):
     * true, false, or "busy" when the app's isolate is not ready. */
    fun liveOutcome(reply: Any?): RunOutcome = when (reply) {
        true -> RunOutcome.OK
        "busy" -> RunOutcome.BUSY
        else -> RunOutcome.FAILED
    }

    /** Only the summary run retries when nothing ran: the hourly run has
     * already written its buffer file, and the next hour covers the rest,
     * but a summary that does not retry is lost for the day. */
    fun shouldRetry(outcome: RunOutcome, summary: Boolean): Boolean =
        summary && outcome == RunOutcome.BUSY
}

/**
 * Holds back summary bookings made while SummaryWorker is running.
 *
 * Dart rebooks `drift_summary` at the end of every run. Doing that with
 * REPLACE from inside the summary run would cancel the running work, and
 * Android may then end the process while Dart is still writing the
 * database. So while a summary run is active the booking is kept here and
 * SummaryWorker books it once the run is over. Thread safe: Dart's calls
 * arrive on the main thread, the worker runs on its own.
 */
class SummaryBookingGate {
    /** A booking held back: [atMs] is the next summary, or null to cancel. */
    data class Pending(val atMs: Long?)

    private var active = 0
    private var pending: Pending? = null

    @Synchronized
    fun begin() {
        active++
    }

    /** True when the booking was held back; the caller then does nothing. */
    @Synchronized
    fun defer(atMs: Long?): Boolean {
        if (active == 0) return false
        pending = Pending(atMs)
        return true
    }

    /** Ends one run and hands back the last booking held during it, which
     * is the one Dart meant (a later call always replaces an earlier one). */
    @Synchronized
    fun end(): Pending? {
        if (active > 0) active--
        if (active > 0) return null
        val out = pending
        pending = null
        return out
    }
}
