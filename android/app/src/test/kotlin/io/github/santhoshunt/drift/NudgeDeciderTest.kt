package io.github.santhoshunt.drift

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

class NudgeDeciderTest {
    companion object {
        private const val FIXTURE = "test/fixtures/nudge_cases.json"

        /** Walks up from the working directory (android/app under Gradle)
         * to the Flutter project root, so the test does not depend on
         * where it is started from. */
        fun fixture(): JSONObject {
            var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
            while (dir != null) {
                val f = File(dir, FIXTURE)
                if (f.isFile) return JSONObject(f.readText())
                dir = dir.parentFile
            }
            fail("$FIXTURE not found above ${System.getProperty("user.dir")}")
            error("unreachable")
        }

        private fun base(): JSONObject =
            fixture().getJSONObject("snapshots").getJSONObject("base")
    }

    @Test
    fun everyFixtureCaseMatches() {
        val root = fixture()
        val snapshots = root.getJSONObject("snapshots")
        val cases = root.getJSONArray("cases")
        val failures = ArrayList<String>()
        var checked = 0
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val snapshot = NudgeSnapshot.parse(snapshots.getJSONObject(c.getString("snapshot")))
            if (snapshot == null) {
                failures.add("$name: snapshot ${c.getString("snapshot")} did not parse")
                continue
            }
            val actual = NudgeDecider.decide(
                snapshot,
                c.getLong("nowMs"),
                c.getInt("nowLocalMin"),
                c.getString("pkg"),
                c.getString("category"),
                c.getLong("continuousMs"),
                if (c.isNull("lastNudgeMs")) null else c.getLong("lastNudgeMs"),
                if (c.isNull("snoozedUntilMs")) null else c.getLong("snoozedUntilMs"),
            )
            val e = c.getJSONObject("expect")
            val expected = if (e.getBoolean("nudge")) {
                NudgeDecision.Nudge(
                    e.getString("block"),
                    e.getLong("minutesOff"),
                    e.getLong("minutesLeft"),
                    e.optBoolean("lock", false),
                )
            } else {
                NudgeDecision.None
            }
            if (actual != expected) failures.add("$name: expected $expected, got $actual")
            checked++
        }
        println("NudgeDeciderTest: asserted $checked of ${cases.length()} fixture cases")
        assertTrue("the fixture has no cases", cases.length() > 0)
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
        assertEquals(cases.length(), checked)
    }

    @Test
    fun fixtureSnapshotsWithoutColoursGetTheDarkDefaults() {
        val snapshot = NudgeSnapshot.parse(base())
        assertNotNull(snapshot)
        assertEquals(NudgeColors(), snapshot!!.colors)
        assertEquals(2, snapshot.windows.size)
        assertEquals(setOf("com.example.notes", "com.example.chat"), snapshot.windows[0].on)
        assertEquals(false, snapshot.lock)
    }

    @Test
    fun lockIsReadAndAWrongTypeMeansNoLock() {
        val lock = fixture().getJSONObject("snapshots").getJSONObject("lock")
        assertEquals(true, NudgeSnapshot.parse(lock)!!.lock)
        assertEquals(false, NudgeSnapshot.parse(base().put("lock", "yes"))!!.lock)
    }

    @Test
    fun coloursParseAndABadOneFallsBack() {
        val json = base().put(
            "colors",
            JSONObject()
                .put("bg", "#000000")
                .put("card", "#FFFFFF")
                .put("text", "#1a2B3c")
                .put("accent", "blue")
                .put("onAccent", 12)
        )
        val colors = NudgeSnapshot.parse(json)!!.colors
        val d = NudgeColors()
        assertEquals(0xFF000000.toInt(), colors.bg)
        assertEquals(0xFFFFFFFF.toInt(), colors.card)
        assertEquals(0xFF1A2B3C.toInt(), colors.text)
        assertEquals(d.textSecondary, colors.textSecondary)
        assertEquals(d.accent, colors.accent)
        assertEquals(d.onAccent, colors.onAccent)
    }

    @Test
    fun malformedSnapshotsParseToNull() {
        val broken = listOf<Pair<String, (JSONObject) -> Unit>>(
            "unknown version" to { it.put("v", 2) },
            "no version" to { it.remove("v") },
            "writtenAtMs as a string" to { it.put("writtenAtMs", "1760846400000") },
            "enabled as a string" to { it.put("enabled", "true") },
            "fractional minutes" to { it.put("nudgeAfterMin", 5.5) },
            "no repeatMin" to { it.remove("repeatMin") },
            "categories not a list" to { it.put("guessOffCategories", "game") },
            "a number in categories" to { it.getJSONArray("guessOffCategories").put(3) },
            "no windows" to { it.remove("windows") },
            "a window without a block" to {
                it.getJSONArray("windows").getJSONObject(0).remove("block")
            },
            "a window end as a string" to {
                it.getJSONArray("windows").getJSONObject(0).put("endMs", "x")
            },
            "a number in off" to {
                it.getJSONArray("windows").getJSONObject(0).getJSONArray("off").put(7)
            },
            "a window that is not an object" to { it.getJSONArray("windows").put("Deep work") },
        )
        for ((name, breakIt) in broken) {
            val json = base()
            breakIt(json)
            assertNull(name, NudgeSnapshot.parse(json))
        }
        assertNull("empty object", NudgeSnapshot.parse(JSONObject()))
    }

    @Test
    fun quietHoursWrapMidnight() {
        assertTrue(NudgeDecider.inQuietHours(1320, 420, 1320))
        assertTrue(NudgeDecider.inQuietHours(1320, 420, 0))
        assertTrue(NudgeDecider.inQuietHours(1320, 420, 419))
        assertTrue(!NudgeDecider.inQuietHours(1320, 420, 420))
        assertTrue(!NudgeDecider.inQuietHours(1320, 420, 1319))
        assertTrue(NudgeDecider.inQuietHours(600, 720, 600))
        assertTrue(!NudgeDecider.inQuietHours(600, 720, 720))
        assertTrue(!NudgeDecider.inQuietHours(600, 600, 600))
    }

    // ForegroundRun: which app is in front, and since when.

    private val launcher = "com.example.launcher"
    private val ignored = setOf(launcher, "io.github.santhoshunt.drift", "com.android.systemui")

    private fun ev(t: Long, pkg: String, cls: String, kind: String) =
        ForegroundRun.Event(t, pkg, cls, kind)

    @Test
    fun sameAppScreenChangeKeepsTheRunWhenTheOldScreenStopsLate() {
        val events = listOf(
            ev(1_000, "com.example.video", "Home", "resumed"),
            ev(60_000, "com.example.video", "Home", "paused"),
            ev(60_100, "com.example.video", "Player", "resumed"),
            ev(60_600, "com.example.video", "Home", "stopped"),
        )
        assertEquals(ForegroundRun.Run("com.example.video", 1_000), ForegroundRun.find(events, ignored))
    }

    @Test
    fun aResumeWithinFiveSecondsContinuesAndLaterStartsANewRun() {
        val within = listOf(
            ev(1_000, "com.example.video", "Player", "resumed"),
            ev(10_000, "com.example.video", "Player", "paused"),
            ev(15_000, "com.example.video", "Player", "resumed"),
        )
        assertEquals(1_000L, ForegroundRun.find(within, ignored)?.startMs)
        val after = listOf(
            ev(1_000, "com.example.video", "Player", "resumed"),
            ev(10_000, "com.example.video", "Player", "paused"),
            ev(16_000, "com.example.video", "Player", "resumed"),
        )
        assertEquals(16_000L, ForegroundRun.find(after, ignored)?.startMs)
    }

    @Test
    fun anotherAppInBetweenResetsTheRun() {
        val events = listOf(
            ev(1_000, "com.example.video", "Player", "resumed"),
            ev(10_000, "com.example.video", "Player", "paused"),
            ev(10_100, "com.example.chat", "Main", "resumed"),
            ev(12_000, "com.example.chat", "Main", "paused"),
            ev(12_100, "com.example.video", "Player", "resumed"),
        )
        assertEquals(ForegroundRun.Run("com.example.video", 12_100), ForegroundRun.find(events, ignored))
    }

    @Test
    fun screenOffOrLockLeavesNothingInFront() {
        for (kind in listOf("screenOff", "keyguardShown")) {
            val events = listOf(
                ev(1_000, "com.example.video", "Player", "resumed"),
                ev(5_000, "android", "", kind),
            )
            assertNull(kind, ForegroundRun.find(events, ignored))
        }
        // Back on after unlock: a new run from the resume.
        val events = listOf(
            ev(1_000, "com.example.video", "Player", "resumed"),
            ev(5_000, "android", "", "screenOff"),
            ev(9_000, "com.example.video", "Player", "resumed"),
        )
        assertEquals(9_000L, ForegroundRun.find(events, ignored)?.startMs)
    }

    @Test
    fun theHomeScreenLeavesNothingInFront() {
        val events = listOf(
            ev(1_000, "com.example.video", "Player", "resumed"),
            ev(10_000, "com.example.video", "Player", "paused"),
            ev(10_100, launcher, "Home", "resumed"),
        )
        assertNull(ForegroundRun.find(events, ignored))
    }

    @Test
    fun systemUiAndDriftDoNotCutARun() {
        val events = listOf(
            ev(1_000, "com.example.video", "Player", "resumed"),
            ev(5_000, "com.android.systemui", "Shade", "resumed"),
            ev(6_000, "com.android.systemui", "Shade", "paused"),
        )
        assertEquals(1_000L, ForegroundRun.find(events, ignored)?.startMs)
        assertNull(ForegroundRun.find(listOf(ev(1_000, "io.github.santhoshunt.drift", "Main", "resumed")), ignored))
    }
}
