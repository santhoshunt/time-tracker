package io.github.santhoshunt.drift

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class WidgetModelTest {
    companion object {
        /** Pinned, so the tests never depend on the machine's zone. */
        private val IST: ZoneId = ZoneId.of("Asia/Kolkata")
        private val DAY: LocalDate = LocalDate.of(2026, 10, 19)
        private const val EPS = 1e-9

        fun at(h: Int, m: Int = 0, s: Int = 0, day: LocalDate = DAY, zone: ZoneId = IST): Long =
            day.atTime(h, m, s).atZone(zone).toInstant().toEpochMilli()

        fun midnight(day: LocalDate = DAY, zone: ZoneId = IST): Long =
            day.atStartOfDay(zone).toInstant().toEpochMilli()

        fun block(name: String, start: Long, end: Long): JSONObject =
            JSONObject().put("name", name).put("startMs", start).put("endMs", end)

        fun piece(start: Long, end: Long, verdict: String): JSONObject =
            JSONObject().put("startMs", start).put("endMs", end).put("verdict", verdict)

        fun colors(): JSONObject = JSONObject()
            .put("bg", "#F7F8FA").put("card", "#FFFFFF").put("line", "#E3E7ED")
            .put("text", "#1B1F24").put("textSecondary", "#5F6B7A").put("accent", "#4A90E2")
            .put("onTrack", "#2E9E6B").put("offTrack", "#E0504E").put("guessed", "#F2B544")

        /** A good snapshot for [DAY]: Deep work 09:00 to 11:00, Family
         * 18:00 to 20:00, computed at 10:00, 74% with 55 min drift. */
        fun snapshotJson(
            blocks: List<JSONObject> = listOf(
                block("Deep work", at(9), at(11)),
                block("Family", at(18), at(20)),
            ),
            pieces: List<JSONObject> = listOf(
                piece(at(9), at(9, 40), "onTrack"),
                piece(at(9, 40), at(10), "offTrack"),
            ),
            percent: Any? = 74,
            driftMin: Int = 55,
            computedAtMs: Long = at(10),
            dayStartMs: Long = midnight(),
            colors: JSONObject? = colors(),
        ): JSONObject = JSONObject()
            .put("v", 1)
            .put("computedAtMs", computedAtMs)
            .put("dayStartMs", dayStartMs)
            .put("blocks", JSONArray(blocks))
            .put("pieces", JSONArray(pieces))
            .put("percent", percent ?: JSONObject.NULL)
            .put("driftMin", driftMin)
            .put("plannedMin", 120)
            .apply { if (colors != null) put("colors", colors) }

        fun parse(json: JSONObject): WidgetSnapshot =
            WidgetSnapshot.parse(json.toString()) ?: error("snapshot did not parse")
    }

    // --- Parsing ------------------------------------------------------------

    @Test
    fun malformedTextGivesNull() {
        assertNull(WidgetSnapshot.parse(null as String?))
        assertNull(WidgetSnapshot.parse(""))
        assertNull(WidgetSnapshot.parse("not json"))
        assertNull(WidgetSnapshot.parse("[1, 2]"))
        assertNull(WidgetSnapshot.parse("{\"v\": 1, \"computedAtMs\": "))
    }

    @Test
    fun malformedTopLevelGivesNull() {
        assertNull(WidgetSnapshot.parse(snapshotJson().put("v", 2).toString()))
        assertNull(WidgetSnapshot.parse(snapshotJson().put("v", "1").toString()))
        assertNull(WidgetSnapshot.parse(snapshotJson().apply { remove("computedAtMs") }.toString()))
        assertNull(WidgetSnapshot.parse(snapshotJson().put("dayStartMs", "today").toString()))
        assertNull(WidgetSnapshot.parse(snapshotJson().put("dayStartMs", 1.5).toString()))
        assertNull(WidgetSnapshot.parse(snapshotJson().put("blocks", "none").toString()))
        assertNull(WidgetSnapshot.parse(snapshotJson().put("pieces", JSONObject()).toString()))
    }

    @Test
    fun goodSnapshotParses() {
        val s = parse(snapshotJson())
        assertEquals(at(10), s.computedAtMs)
        assertEquals(midnight(), s.dayStartMs)
        assertEquals(listOf("Deep work", "Family"), s.blocks.map { it.name })
        assertEquals(listOf(WidgetVerdict.ON_TRACK, WidgetVerdict.OFF_TRACK), s.pieces.map { it.verdict })
        assertEquals(74, s.percent)
        assertEquals(55, s.driftMin)
        assertEquals(120, s.plannedMin)
        assertEquals(0xFF4A90E2.toInt(), s.colors.accent)
        assertEquals(0xFFFFFFFF.toInt(), s.colors.card)
    }

    @Test
    fun badBlocksAndPiecesAreDroppedOneByOne() {
        val s = parse(
            snapshotJson(
                blocks = listOf(
                    block("Family", at(18), at(20)),
                    JSONObject().put("startMs", at(7)).put("endMs", at(8)),
                    block("Backwards", at(12), at(11)),
                    block("Half", at(13), at(14)).put("startMs", 1.5),
                    block("  ", at(6), at(7)),
                    block("Deep work", at(9), at(11)),
                ),
                pieces = listOf(
                    piece(at(9), at(10), "onTrack"),
                    piece(at(10), at(11), "sideQuest"),
                    piece(at(11), at(11), "offTrack"),
                    piece(at(8), at(9), "noData"),
                ),
            ).apply {
                getJSONArray("blocks").put("not an object")
                getJSONArray("pieces").put(JSONObject.NULL)
            }
        )
        // Sorted by start, whatever order Dart wrote; a blank name is kept
        // with a stand-in.
        assertEquals(listOf("Untitled block", "Deep work", "Family"), s.blocks.map { it.name })
        assertEquals(listOf(WidgetVerdict.NO_DATA, WidgetVerdict.ON_TRACK), s.pieces.map { it.verdict })
    }

    @Test
    fun missingListsAreEmpty() {
        val json = snapshotJson().apply {
            remove("blocks")
            remove("pieces")
            remove("driftMin")
            remove("plannedMin")
        }
        val s = parse(json)
        assertEquals(emptyList<WidgetBlock>(), s.blocks)
        assertEquals(emptyList<WidgetPiece>(), s.pieces)
        assertEquals(0, s.driftMin)
        assertEquals(0, s.plannedMin)
    }

    @Test
    fun percentNullOrOutOfRange() {
        assertNull(parse(snapshotJson(percent = null)).percent)
        assertNull(parse(snapshotJson().apply { remove("percent") }).percent)
        assertNull(parse(snapshotJson(percent = "74")).percent)
        assertNull(parse(snapshotJson(percent = 74.5)).percent)
        assertEquals(100, parse(snapshotJson(percent = 130)).percent)
        assertEquals(0, parse(snapshotJson(percent = 0)).percent)
    }

    @Test
    fun missingColoursFallBackToMono() {
        assertEquals(WidgetColors(), parse(snapshotJson(colors = null)).colors)
        val partial = JSONObject()
            .put("accent", "#38BDF8")
            .put("card", "#12345")
            .put("text", "red")
            .put("line", 0x272B30)
            .put("onTrack", "#3dd68c")
        val c = parse(snapshotJson(colors = partial)).colors
        val d = WidgetColors()
        assertEquals(0xFF38BDF8.toInt(), c.accent)
        assertEquals(0xFF3DD68C.toInt(), c.onTrack)
        assertEquals(d.card, c.card)
        assertEquals(d.text, c.text)
        assertEquals(d.line, c.line)
        assertEquals(d.bg, c.bg)
        assertEquals(d.guessed, c.guessed)
        // Colours that are not an object fall back as a whole.
        assertEquals(d, parse(snapshotJson().put("colors", "dark")).colors)
    }

    @Test
    fun monoDefaultsMatchTheAppTheme() {
        val d = WidgetColors()
        assertEquals(0xFF101214.toInt(), d.bg)
        assertEquals(0xFF181B1E.toInt(), d.card)
        assertEquals(0xFF272B30.toInt(), d.line)
        assertEquals(0xFFF0F4FF.toInt(), d.text)
        assertEquals(0xFFAAB8D4.toInt(), d.textSecondary)
        assertEquals(0xFFE6EAF2.toInt(), d.accent)
        assertEquals(0xFF3DD68C.toInt(), d.onTrack)
        assertEquals(0xFFFF6B6B.toInt(), d.offTrack)
        assertEquals(0xFFF5B544.toInt(), d.guessed)
    }

    // --- The current block and the time left --------------------------------

    @Test
    fun currentBlockAndTimeLeft() {
        val s = parse(snapshotJson())
        val t = WidgetModel.text(s, at(10, 18), IST)
        assertEquals(WidgetDay.TODAY, t.day)
        assertEquals("Deep work", t.headline)
        assertEquals("42 min left", t.detail)
        assertEquals("Deep work", t.block?.name)
        assertEquals("Deep work · 42 min left", t.ringCaption)
    }

    @Test
    fun timeLeftRoundsUp() {
        assertEquals(1, WidgetModel.minutesLeft(at(11), at(10, 59, 30)))
        assertEquals(42, WidgetModel.minutesLeft(at(11), at(10, 18)))
        assertEquals(43, WidgetModel.minutesLeft(at(11), at(10, 17, 59)))
        assertEquals(0, WidgetModel.minutesLeft(at(11), at(11)))
        val s = parse(snapshotJson())
        assertEquals("1 min left", WidgetModel.text(s, at(10, 59, 30), IST).detail)
        assertEquals("1 h 15 min left", WidgetModel.text(s, at(9, 45), IST).detail)
        assertEquals("2 h left", WidgetModel.text(s, at(9), IST).detail)
    }

    @Test
    fun blockEndIsExclusive() {
        val s = parse(snapshotJson())
        val t = WidgetModel.text(s, at(11), IST)
        assertEquals("No block now", t.headline)
        assertNull(t.block)
        assertEquals("Next: Family at 18:00", t.detail)
        assertEquals("No block now", t.ringCaption)
    }

    @Test
    fun nextBlockText() {
        val s = parse(snapshotJson())
        assertEquals("Next: Deep work at 09:00", WidgetModel.text(s, at(7, 30), IST).detail)
        assertEquals("Next: Family at 18:00", WidgetModel.text(s, at(14), IST).detail)
        assertEquals("Nothing else planned today", WidgetModel.text(s, at(21), IST).detail)
        // In a block, the next one is not shown.
        assertEquals("Family", WidgetModel.text(s, at(18), IST).headline)
    }

    @Test
    fun overlappingBlocksPickTheLaterStart() {
        val s = parse(
            snapshotJson(
                blocks = listOf(
                    block("Work", at(9), at(17)),
                    block("Lunch", at(13), at(14)),
                )
            )
        )
        assertEquals("Lunch", WidgetModel.currentBlock(s.blocks, at(13, 30))?.name)
        assertEquals("Work", WidgetModel.currentBlock(s.blocks, at(14))?.name)
        assertEquals("Lunch", WidgetModel.nextBlock(s.blocks, at(10))?.name)
    }

    @Test
    fun ringCaptionParts() {
        val s = parse(snapshotJson())
        assertEquals(RingCaption("Deep work", "42 min left", " · "), WidgetModel.text(s, at(10, 18), IST).ring)
        assertEquals(RingCaption("No block now", null, ""), WidgetModel.text(s, at(12), IST).ring)
        assertEquals(RingCaption("Open Drift", "to start", " "), WidgetModel.text(null, at(12), IST).ring)
        val old = parse(snapshotJson(dayStartMs = midnight(DAY.minusDays(1))))
        assertEquals("Open Drift to see today", WidgetModel.text(old, at(12), IST).ringCaption)
    }

    @Test
    fun fitCaptionShortensTheNameAndKeepsTheTimeLeft() {
        // One unit per character.
        val measure = { s: String -> s.length.toFloat() }
        val cap = RingCaption("Deep work", "42 min left", " · ")
        assertEquals("Deep work · 42 min left", WidgetModel.fitCaption(cap, 23f, measure))
        assertEquals("Deep wo… · 42 min left", WidgetModel.fitCaption(cap, 22f, measure))
        // "Deep " trims to "Deep" before the ellipsis.
        assertEquals("Deep… · 42 min left", WidgetModel.fitCaption(cap, 19f, measure))
        assertEquals("D… · 42 min left", WidgetModel.fitCaption(cap, 16f, measure))
        assertEquals("42 min left", WidgetModel.fitCaption(cap, 15f, measure))
        assertEquals("42 min left", WidgetModel.fitCaption(cap, 5f, measure))
        // No second part: left for the TextView to ellipsize.
        assertEquals("No block now", WidgetModel.fitCaption(RingCaption("No block now", null, ""), 3f, measure))
    }

    @Test
    fun fitCaptionNeverSplitsAnEmoji() {
        val measure = { s: String -> s.length.toFloat() }
        // "Gym 🏋" ends in a surrogate pair: the cut skips past it whole.
        val cap = RingCaption("Gym 🏋", "5 min left", " · ")
        val fitted = WidgetModel.fitCaption(cap, 18f, measure)
        assertEquals("Gym… · 5 min left", fitted)
    }

    @Test
    fun formatMinutesMatchesTheApp() {
        assertEquals("0 min", WidgetModel.formatMinutes(0))
        assertEquals("45 min", WidgetModel.formatMinutes(45))
        assertEquals("1 h", WidgetModel.formatMinutes(60))
        assertEquals("1 h 25 min", WidgetModel.formatMinutes(85))
        assertEquals("2 h", WidgetModel.formatMinutes(120))
    }

    // --- Score and drift ----------------------------------------------------

    @Test
    fun scoreAndDriftText() {
        val t = WidgetModel.text(parse(snapshotJson()), at(10, 18), IST)
        assertEquals("Today 74%", t.score)
        assertEquals("55 min drift", t.drift)
        assertEquals(74, t.ringPercent)
        assertEquals("No drift", WidgetModel.text(parse(snapshotJson(driftMin = 0)), at(10), IST).drift)
        assertEquals(
            "1 h 5 min drift",
            WidgetModel.text(parse(snapshotJson(driftMin = 65)), at(10), IST).drift,
        )
    }

    @Test
    fun noScoreYet() {
        val t = WidgetModel.text(parse(snapshotJson(percent = null)), at(8), IST)
        assertEquals("No score yet", t.score)
        assertNull(t.drift)
        assertNull(t.ringPercent)
        val empty = WidgetModel.text(
            parse(snapshotJson(percent = null, blocks = emptyList(), pieces = emptyList())),
            at(8),
            IST,
        )
        assertEquals("Nothing planned yet", empty.score)
        assertEquals("No block now", empty.headline)
        assertEquals("Nothing else planned today", empty.detail)
    }

    // --- Stale and missing days ---------------------------------------------

    @Test
    fun staleAfterThreeHours() {
        val s = parse(snapshotJson(computedAtMs = at(14, 5)))
        assertNull(WidgetModel.text(s, at(17, 5), IST).stale)
        assertEquals("updated 14:05", WidgetModel.text(s, at(17, 6), IST).stale)
        assertEquals("updated 14:05", WidgetModel.staleLabel(s, at(23, 59), IST))
        // A snapshot from the future (a clock change) is not stale.
        assertNull(WidgetModel.staleLabel(s, at(9), IST))
    }

    @Test
    fun missingSnapshot() {
        val t = WidgetModel.text(null, at(10), IST)
        assertEquals(WidgetDay.MISSING, t.day)
        assertEquals("Open Drift to start", t.headline)
        assertEquals("Open Drift to start", t.ringCaption)
        assertNull(t.detail)
        assertNull(t.score)
        assertNull(t.drift)
        assertNull(t.stale)
        assertNull(t.ringPercent)
    }

    @Test
    fun snapshotFromAnEarlierDay() {
        val yesterday = DAY.minusDays(1)
        val s = parse(
            snapshotJson(
                dayStartMs = midnight(yesterday),
                computedAtMs = at(23, 50, day = yesterday),
                blocks = listOf(block("Late", at(23, day = yesterday), midnight())),
            )
        )
        val t = WidgetModel.text(s, at(0, 10), IST)
        assertEquals(WidgetDay.OLD_DAY, t.day)
        assertEquals("Open Drift to see today", t.headline)
        assertNull(t.score)
        assertNull(t.ringPercent)
        assertNull(t.block)
        // The same snapshot is today's until midnight.
        assertEquals(WidgetDay.TODAY, WidgetModel.day(s, at(23, 55, day = yesterday), IST))
    }

    @Test
    fun dayComparesCalendarDatesInTheZone() {
        // 18:30 UTC on the 18th is midnight of the 19th in IST.
        val s = parse(snapshotJson(dayStartMs = midnight()))
        assertEquals(WidgetDay.TODAY, WidgetModel.day(s, at(23, 59, 59), IST))
        assertEquals(WidgetDay.OLD_DAY, WidgetModel.day(s, at(0, day = DAY.plusDays(1)), IST))
        assertEquals(WidgetDay.OLD_DAY, WidgetModel.day(s, at(10), ZoneId.of("UTC")))
    }

    // --- Strip geometry -----------------------------------------------------

    @Test
    fun defaultAxisRunsFromSixToMidnight() {
        val s = parse(snapshotJson())
        val axis = WidgetModel.stripAxis(s, IST)
        assertEquals(at(6), axis.startMs)
        assertEquals(midnight(DAY.plusDays(1)), axis.endMs)
        assertEquals(listOf("06", "12", "18", "24"), axis.ticks.map { it.label })
        val f = axis.ticks.map { it.fraction }
        assertEquals(0.0, f[0], EPS)
        assertEquals(1.0 / 3, f[1], EPS)
        assertEquals(2.0 / 3, f[2], EPS)
        assertEquals(1.0, f[3], EPS)
    }

    @Test
    fun planAndActualFractions() {
        val s = parse(snapshotJson())
        val axis = WidgetModel.stripAxis(s, IST)
        val plan = WidgetModel.planSpans(s, axis)
        assertEquals(2, plan.size)
        assertEquals(3.0 / 18, plan[0].from, EPS)
        assertEquals(5.0 / 18, plan[0].to, EPS)
        assertEquals(12.0 / 18, plan[1].from, EPS)
        assertEquals(14.0 / 18, plan[1].to, EPS)
        val actual = WidgetModel.actualSpans(s, axis)
        assertEquals(WidgetVerdict.ON_TRACK, actual[0].verdict)
        assertEquals(3.0 / 18, actual[0].from, EPS)
        assertEquals((3 + 40.0 / 60) / 18, actual[0].to, EPS)
        assertEquals(WidgetVerdict.OFF_TRACK, actual[1].verdict)
        assertEquals(4.0 / 18, actual[1].to, EPS)
        assertEquals((4 + 18.0 / 60) / 18, WidgetModel.nowFraction(axis, at(10, 18))!!, EPS)
        assertNull(WidgetModel.nowFraction(axis, at(5)))
    }

    @Test
    fun earlyBlockMovesTheAxisStartToItsHour() {
        val s = parse(
            snapshotJson(
                blocks = listOf(block("Run", at(4, 30), at(5, 15)), block("Work", at(9), at(17))),
                pieces = listOf(piece(at(3), at(4, 45), "idle")),
            )
        )
        val axis = WidgetModel.stripAxis(s, IST)
        assertEquals(at(4), axis.startMs)
        assertEquals(listOf("06", "12", "18", "24"), axis.ticks.map { it.label })
        assertEquals(2.0 / 20, axis.ticks[0].fraction, EPS)
        val plan = WidgetModel.planSpans(s, axis)
        assertEquals(0.5 / 20, plan[0].from, EPS)
        assertEquals(1.25 / 20, plan[0].to, EPS)
        // A piece that starts before the axis is clipped to it.
        val actual = WidgetModel.actualSpans(s, axis)
        assertEquals(0.0, actual[0].from, EPS)
        assertEquals(0.75 / 20, actual[0].to, EPS)
        assertNotNull(WidgetModel.nowFraction(axis, at(4, 30)))
    }

    @Test
    fun blockFromBeforeMidnightStartsTheAxisAtMidnight() {
        val s = parse(
            snapshotJson(blocks = listOf(block("Late", at(23, day = DAY.minusDays(1)), at(1))))
        )
        val axis = WidgetModel.stripAxis(s, IST)
        assertEquals(midnight(), axis.startMs)
        assertEquals(listOf("00", "06", "12", "18", "24"), axis.ticks.map { it.label })
        val plan = WidgetModel.planSpans(s, axis)
        assertEquals(0.0, plan[0].from, EPS)
        assertEquals(1.0 / 24, plan[0].to, EPS)
    }

    @Test
    fun piecesOutsideTheAxisAreDropped() {
        val s = parse(
            snapshotJson(
                pieces = listOf(
                    piece(at(2), at(5), "noData"),
                    piece(at(7), at(8), "guessedOn"),
                )
            )
        )
        val actual = WidgetModel.actualSpans(s, WidgetModel.stripAxis(s, IST))
        assertEquals(listOf(WidgetVerdict.GUESSED_ON), actual.map { it.verdict })
    }

    @Test
    fun axisEndsAtTheZonesNextMidnight() {
        // Europe/London falls back on 25 October 2026: a 25-hour day.
        val london = ZoneId.of("Europe/London")
        val day = LocalDate.of(2026, 10, 25)
        val s = parse(
            snapshotJson(
                dayStartMs = midnight(day, london),
                computedAtMs = at(10, day = day, zone = london),
                blocks = listOf(block("Early", at(0, 30, day = day, zone = london), at(1, 30, day = day, zone = london))),
            )
        )
        val axis = WidgetModel.stripAxis(s, london)
        assertEquals(midnight(day, london), axis.startMs)
        assertEquals(midnight(day.plusDays(1), london), axis.endMs)
        assertEquals(25 * 3_600_000L, axis.endMs - axis.startMs)
        assertEquals(1.0, axis.ticks.last().fraction, EPS)
        // 06:00 is 7 hours in, after the extra hour.
        assertEquals(7.0 / 25, axis.ticks[1].fraction, EPS)
    }

    @Test
    fun verdictFillsMatchTheApp() {
        val c = WidgetColors()
        assertEquals(c.onTrack, WidgetModel.verdictFill(c, WidgetVerdict.ON_TRACK))
        assertEquals(c.offTrack, WidgetModel.verdictFill(c, WidgetVerdict.OFF_TRACK))
        assertEquals(0x47F5B544, WidgetModel.verdictFill(c, WidgetVerdict.GUESSED_OFF))
        assertEquals(0x383DD68C, WidgetModel.verdictFill(c, WidgetVerdict.IDLE))
        assertEquals(0x59AAB8D4, WidgetModel.verdictFill(c, WidgetVerdict.UNPLANNED))
        assertEquals(c.line, WidgetModel.verdictFill(c, WidgetVerdict.NO_DATA))
        assertEquals(c.guessed, WidgetModel.verdictOutline(c, WidgetVerdict.GUESSED_ON))
        assertEquals(c.onTrack, WidgetModel.verdictOutline(c, WidgetVerdict.IDLE))
        assertNull(WidgetModel.verdictOutline(c, WidgetVerdict.OFF_TRACK))
    }
}
