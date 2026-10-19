package io.github.santhoshunt.drift

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UsageEventMapperTest {
    @Test
    fun mapsEveryKeptEventType() {
        val expected = mapOf(
            1 to "resumed",
            2 to "paused",
            23 to "stopped",
            15 to "screenOn",
            16 to "screenOff",
            17 to "keyguardShown",
            18 to "keyguardHidden",
            26 to "shutdown",
            27 to "startup",
        )
        for ((type, kind) in expected) {
            assertEquals("type $type", kind, UsageEventMapper.kindOf(type))
        }
    }

    @Test
    fun dropsEveryOtherEventType() {
        // Public in android.jar (API 36): 0 NONE, 5 CONFIGURATION_CHANGE,
        // 7 USER_INTERACTION, 8 SHORTCUT_INVOCATION, 11 STANDBY_BUCKET_CHANGED,
        // 19 FOREGROUND_SERVICE_START, 20 FOREGROUND_SERVICE_STOP. The rest
        // are hidden or unused values.
        for (type in listOf(-1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 19, 20, 21, 22, 24, 25, 28, 99)) {
            assertNull("type $type", UsageEventMapper.kindOf(type))
        }
    }

    @Test
    fun mapsEveryCategory() {
        val expected = mapOf(
            0 to "game",
            1 to "audio",
            2 to "video",
            3 to "image",
            4 to "social",
            5 to "news",
            6 to "maps",
            7 to "productivity",
            8 to "accessibility",
        )
        for ((category, name) in expected) {
            assertEquals("category $category", name, UsageEventMapper.categoryName(category))
        }
    }

    @Test
    fun unknownCategoriesAreUndefined() {
        for (category in listOf(-1, 9, 42, Int.MIN_VALUE, Int.MAX_VALUE)) {
            assertEquals("undefined", UsageEventMapper.categoryName(category))
        }
    }

    @Test
    fun bufferLineRoundTrips() {
        val line = UsageEventMapper.bufferLine(
            1_760_860_800_123L,
            "com.example.video",
            "com.example.video.PlayerActivity",
            "resumed",
        )
        val json = JSONObject(line)
        assertEquals(4, json.length())
        assertEquals(1_760_860_800_123L, json.getLong("t"))
        assertEquals("com.example.video", json.getString("p"))
        assertEquals("com.example.video.PlayerActivity", json.getString("c"))
        assertEquals("resumed", json.getString("k"))
    }

    @Test
    fun bufferLineKeepsANullClass() {
        val json = JSONObject(UsageEventMapper.bufferLine(5L, "android", null, "screenOff"))
        assertTrue(json.has("c"))
        assertTrue(json.isNull("c"))
        assertEquals(5L, json.getLong("t"))
        assertEquals("screenOff", json.getString("k"))
    }

    @Test
    fun bufferLineStaysOnOneLine() {
        val awkward = "com.example.notes\n\"quoted\"\r\\slash"
        val line = UsageEventMapper.bufferLine(7L, awkward, "A\nB", "paused")
        assertFalse(line.contains('\n'))
        assertFalse(line.contains('\r'))
        val json = JSONObject(line)
        assertEquals(awkward, json.getString("p"))
        assertEquals("A\nB", json.getString("c"))
    }
}
