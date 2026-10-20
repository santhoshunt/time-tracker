package io.github.santhoshunt.drift

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class TodayStatusTest {
    /** A fixed zone, so the test reads the same on any machine. */
    private val zone = ZoneId.of("Asia/Kolkata")

    private fun at(h: Int, m: Int, day: Int = 20): Long =
        LocalDateTime.of(2026, 10, day, h, m).atZone(zone).toInstant().toEpochMilli()

    private fun w(name: String, sh: Int, sm: Int, eh: Int, em: Int, day: Int = 20) =
        NudgeWindow(at(sh, sm, day), at(eh, em, day), name, false, emptySet(), emptySet())

    private val day = listOf(
        w("Deep work", 9, 0, 12, 0),
        w("Meetings", 13, 0, 14, 0),
        w("Gym", 8, 0, 9, 0, day = 21),
    )

    @Test
    fun inABlockSaysWhatAndHowLongIsLeft() {
        assertEquals(
            TodayStatus.Line("Now: Deep work", "09:00 to 12:00, 48 min left"),
            TodayStatus.blockLine(day, at(11, 12), zone),
        )
        // Minutes left round up: 2 h 59 min 30 s reads as 3 h.
        assertEquals(
            "09:00 to 12:00, 3 h left",
            TodayStatus.blockLine(day, at(9, 0) + 30_000, zone).text,
        )
        assertEquals("09:00 to 12:00, 2 h 1 min left", TodayStatus.blockLine(day, at(9, 59), zone).text)
    }

    @Test
    fun betweenBlocksShowsTheNextOne() {
        assertEquals(
            TodayStatus.Line("Free until 13:00", "Next: Meetings, 13:00 to 14:00"),
            TodayStatus.blockLine(day, at(12, 0), zone),
        )
    }

    @Test
    fun afterTheLastBlockPointsToTomorrow() {
        assertEquals(
            TodayStatus.Line("Nothing else planned today", "Tomorrow: Gym at 08:00"),
            TodayStatus.blockLine(day, at(15, 0), zone),
        )
        assertEquals(
            TodayStatus.Line("Nothing planned today", "Open Drift to plan your day"),
            TodayStatus.blockLine(emptyList(), at(15, 0), zone),
        )
    }

    @Test
    fun overlappingBlocksShowTheFirstInSnapshotOrder() {
        val overlap = listOf(w("Family", 18, 0, 21, 0), w("Movie night", 20, 0, 23, 0))
        assertEquals("Now: Family", TodayStatus.blockLine(overlap, at(20, 30), zone).title)
    }

    @Test
    fun aBlockToMidnightEndsAt2400() {
        val late = listOf(NudgeWindow(at(22, 0), at(0, 0, day = 21), "Reading", false, emptySet(), emptySet()))
        assertEquals("22:00 to 24:00, 1 h left", TodayStatus.blockLine(late, at(23, 0), zone).text)
    }

    @Test
    fun minutesReadLikeTheApp() {
        assertEquals("0 min", TodayStatus.minutes(0))
        assertEquals("45 min", TodayStatus.minutes(45))
        assertEquals("2 h", TodayStatus.minutes(120))
        assertEquals("1 h 25 min", TodayStatus.minutes(85))
        assertEquals(
            TodayStatus.Line("Distracting: 39 min", "of 1 h 25 min on apps"),
            TodayStatus.usageLine(85L * 60_000, 39L * 60_000 + 20_000),
        )
        assertEquals(46, TodayStatus.percent(85L * 60_000, 39L * 60_000))
        assertEquals(0, TodayStatus.percent(0, 0))
    }

    @Test
    fun twoRemindersPerBlockInTimeOrder() {
        val r = TodayStatus.reminders(day)
        assertEquals(6, r.size)
        assertEquals(at(8, 55), r[0].atMs)
        assertEquals(false, r[0].startsNow)
        assertEquals(at(9, 0), r[1].atMs)
        assertEquals(true, r[1].startsNow)
        assertEquals(r.map { it.atMs }.sorted(), r.map { it.atMs })
        assertEquals(6, r.map { it.key }.toSet().size)
    }

    @Test
    fun dueReminderStaysValidUntilTheNextStateReplacesIt() {
        val r = TodayStatus.reminders(day)
        assertNull(TodayStatus.due(r, at(8, 54), emptySet()))
        assertEquals(false, TodayStatus.due(r, at(8, 55), emptySet())!!.startsNow)
        // A dozing phone fires the "up" alarm 3 minutes late: still shown.
        assertEquals(false, TodayStatus.due(r, at(8, 58), emptySet())!!.startsNow)
        // Android holds the "start" alarm back 4 minutes: it still posts.
        assertEquals(true, TodayStatus.due(r, at(9, 4), emptySet())!!.startsNow)
        // Past the block's first 15 minutes nothing is due.
        assertNull(TodayStatus.due(r, at(9, 15), emptySet()))
    }

    @Test
    fun aShownReminderIsNotShownAgain() {
        val r = TodayStatus.reminders(day)
        val up = TodayStatus.due(r, at(8, 56), emptySet())!!
        assertNull(TodayStatus.due(r, at(8, 57), setOf(up.key)))
        val start = TodayStatus.due(r, at(9, 1), setOf(up.key))!!
        assertNull(TodayStatus.due(r, at(9, 2), setOf(up.key, start.key)))
    }

    @Test
    fun aShortBlockStopsStartingNowAtItsEnd() {
        val short = listOf(w("Call", 9, 0, 9, 10))
        val r = TodayStatus.reminders(short)
        assertEquals(true, TodayStatus.due(r, at(9, 9), emptySet())!!.startsNow)
        assertNull(TodayStatus.due(r, at(9, 10), emptySet()))
    }

    @Test
    fun theNextAlarmIsTheFirstReminderAfterNow() {
        val r = TodayStatus.reminders(day)
        assertEquals(at(8, 55), TodayStatus.nextAlarmMs(r, at(7, 0)))
        assertEquals(at(9, 0), TodayStatus.nextAlarmMs(r, at(8, 55)))
        assertEquals(at(12, 55), TodayStatus.nextAlarmMs(r, at(9, 30)))
        assertNull(TodayStatus.nextAlarmMs(r, at(9, 30, day = 21)))
    }

    @Test
    fun reminderWordsUseTheMinutesLeftWhenPosted() {
        val r = TodayStatus.reminders(day)
        assertEquals(
            TodayStatus.Line("Up next: Deep work", "Starts at 09:00, in 5 min"),
            TodayStatus.reminderLine(r[0], at(8, 55), zone),
        )
        assertEquals("Starts at 09:00, in 2 min", TodayStatus.reminderLine(r[0], at(8, 58), zone).text)
        assertEquals(
            TodayStatus.Line("Starting now: Deep work", "09:00 to 12:00"),
            TodayStatus.reminderLine(r[1], at(9, 0), zone),
        )
    }
}
