package io.github.santhoshunt.drift

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Every case in test/fixtures/usage_count_cases.json, which
 * test/domain/day_usage_test.dart also runs, so the Today notification and
 * the Usage tab count app time alike.
 */
class DayUsageTest {
    private fun fixture(): JSONObject {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val f = File(dir, "test/fixtures/usage_count_cases.json")
            if (f.isFile) return JSONObject(f.readText())
            dir = dir.parentFile
        }
        fail("usage_count_cases.json not found above ${System.getProperty("user.dir")}")
        error("unreachable")
    }

    /** Local time in this machine's zone, as Dart's DateTime.parse reads it. */
    private fun ms(local: String): Long =
        LocalDateTime.parse(local).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()

    private fun JSONArray.strings(): Set<String> = (0 until length()).map { getString(it) }.toSet()

    @Test
    fun everyFixtureCaseMatches() {
        val cases = fixture().getJSONArray("cases")
        val failures = ArrayList<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val events = c.getJSONArray("events").let { a ->
                (0 until a.length()).map { j ->
                    val e = a.getJSONObject(j)
                    ForegroundRun.Event(
                        t = ms(e.getString("t")),
                        pkg = e.getString("p"),
                        cls = if (e.isNull("c")) null else e.getString("c"),
                        kind = e.getString("k"),
                    )
                }
            }
            val categories = c.getJSONObject("categories")
            val counted = DayUsage.count(
                events = events,
                dayStartMs = ms(c.getString("dayStart")),
                nowMs = ms(c.getString("now")),
                idle = c.getJSONArray("idle").strings(),
                launchable = c.getJSONArray("launchable").strings(),
                categoryOf = { p -> categories.optString(p, "undefined") },
                offApps = c.getJSONArray("offApps").strings(),
                onApps = c.getJSONArray("onApps").strings(),
                guessOff = c.getJSONArray("guessOff").strings(),
            )
            val e = c.getJSONObject("expect")
            val expected = DayUsage.Counted(e.getLong("totalMs"), e.getLong("distractingMs"))
            if (counted != expected) failures.add("${c.getString("name")}: expected $expected, got $counted")
        }
        println("DayUsageTest: asserted ${cases.length()} fixture cases")
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
        assertTrue("the fixture covers the rules", cases.length() >= 18)
    }

    @Test
    fun distractingRule() {
        val guess = setOf("game", "video", "social", "news")
        assertTrue(DayUsage.isDistracting("a", "social", emptySet(), emptySet(), guess))
        assertFalse(DayUsage.isDistracting("a", "social", emptySet(), setOf("a"), guess))
        assertTrue(DayUsage.isDistracting("a", "productivity", setOf("a"), emptySet(), guess))
        assertTrue(DayUsage.isDistracting("a", "social", setOf("a"), setOf("a"), guess))
        assertFalse(DayUsage.isDistracting("a", "undefined", emptySet(), emptySet(), guess))
    }

    @Test
    fun driftPackageMatchesTheManifest() {
        assertEquals("io.github.santhoshunt.drift", DayUsage.DRIFT_PACKAGE)
    }
}
