package io.github.santhoshunt.drift

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundLogicTest {
    @Test
    fun delayIsTheTimeUntilTheTarget() {
        assertEquals(90_000L, BackgroundLogic.delayMs(targetMs = 1_090_000L, nowMs = 1_000_000L))
    }

    @Test
    fun aTargetInThePastRunsAtOnce() {
        assertEquals(0L, BackgroundLogic.delayMs(targetMs = 5L, nowMs = 1_000L))
        assertEquals(0L, BackgroundLogic.delayMs(targetMs = 1_000L, nowMs = 1_000L))
    }

    @Test
    fun liveRepliesMapToOutcomes() {
        assertEquals(RunOutcome.OK, BackgroundLogic.liveOutcome(true))
        assertEquals(RunOutcome.FAILED, BackgroundLogic.liveOutcome(false))
        assertEquals(RunOutcome.BUSY, BackgroundLogic.liveOutcome("busy"))
        assertEquals(RunOutcome.FAILED, BackgroundLogic.liveOutcome(null))
    }

    @Test
    fun onlyABusySummaryRunRetries() {
        assertTrue(BackgroundLogic.shouldRetry(RunOutcome.BUSY, summary = true))
        assertFalse(BackgroundLogic.shouldRetry(RunOutcome.BUSY, summary = false))
        assertFalse(BackgroundLogic.shouldRetry(RunOutcome.OK, summary = true))
        assertFalse(BackgroundLogic.shouldRetry(RunOutcome.FAILED, summary = true))
    }

    @Test
    fun bookingsPassStraightThroughOutsideASummaryRun() {
        val gate = SummaryBookingGate()
        assertFalse(gate.defer(123L))
        assertNull(gate.end())
    }

    @Test
    fun theLastBookingDuringASummaryRunIsHeldUntilItEnds() {
        val gate = SummaryBookingGate()
        gate.begin()
        assertTrue(gate.defer(100L))
        assertTrue(gate.defer(200L))
        assertEquals(SummaryBookingGate.Pending(200L), gate.end())
        // Released: the next booking goes straight through again.
        assertFalse(gate.defer(300L))
    }

    @Test
    fun aCancelDuringASummaryRunIsHeldToo() {
        val gate = SummaryBookingGate()
        gate.begin()
        assertTrue(gate.defer(100L))
        assertTrue(gate.defer(null))
        assertEquals(SummaryBookingGate.Pending(null), gate.end())
    }

    @Test
    fun nestedRunsReleaseOnlyAtTheLastEnd() {
        val gate = SummaryBookingGate()
        gate.begin()
        gate.begin()
        assertTrue(gate.defer(100L))
        assertNull(gate.end())
        assertEquals(SummaryBookingGate.Pending(100L), gate.end())
    }

    @Test
    fun aRunWithNoBookingHandsBackNothing() {
        val gate = SummaryBookingGate()
        gate.begin()
        assertNull(gate.end())
    }
}
