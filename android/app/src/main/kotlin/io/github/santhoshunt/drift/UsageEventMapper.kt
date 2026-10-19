package io.github.santhoshunt.drift

import org.json.JSONObject

/**
 * Turns Android's usage numbers into the strings Dart expects
 * (lib/platform/usage_source.dart, UsageEventKinds and AppCategories).
 *
 * Plain Kotlin with no Android types, so the JVM unit tests cover it. The
 * integer values are copied from android.jar (API 36) rather than read from
 * the SDK classes, which the JVM tests only see as stubs.
 */
object UsageEventMapper {
    /** UsageEvents.Event type to the `k` string, or null for a type Drift
     * drops (configuration changes, notifications, standby buckets...). */
    fun kindOf(type: Int): String? = when (type) {
        1 -> "resumed" // ACTIVITY_RESUMED
        2 -> "paused" // ACTIVITY_PAUSED
        23 -> "stopped" // ACTIVITY_STOPPED
        15 -> "screenOn" // SCREEN_INTERACTIVE
        16 -> "screenOff" // SCREEN_NON_INTERACTIVE
        17 -> "keyguardShown" // KEYGUARD_SHOWN
        18 -> "keyguardHidden" // KEYGUARD_HIDDEN
        26 -> "shutdown" // DEVICE_SHUTDOWN
        27 -> "startup" // DEVICE_STARTUP
        else -> null
    }

    /** ApplicationInfo.category to the `category` string. Apps that declare
     * none report CATEGORY_UNDEFINED (-1), which lands in the else branch. */
    fun categoryName(category: Int): String = when (category) {
        0 -> "game"
        1 -> "audio"
        2 -> "video"
        3 -> "image"
        4 -> "social"
        5 -> "news"
        6 -> "maps"
        7 -> "productivity"
        8 -> "accessibility"
        else -> "undefined"
    }

    /** One buffer-file line: the queryEvents map as a single JSON object.
     * A missing class is written as an explicit null so every line carries
     * all four keys. JSON escapes any newline inside a string, so the result
     * is always one line. */
    fun bufferLine(t: Long, p: String, c: String?, k: String): String =
        JSONObject()
            .put("t", t)
            .put("p", p)
            .put("c", c ?: JSONObject.NULL)
            .put("k", k)
            .toString()
}
