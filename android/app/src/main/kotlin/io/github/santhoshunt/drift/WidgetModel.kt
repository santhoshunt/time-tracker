package io.github.santhoshunt.drift

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The home-screen widgets' theme as opaque ARGB ints. Each key falls back on
 * its own to the mono theme (the app's default, dark with light text), so a
 * snapshot with a missing or malformed colour still draws.
 */
data class WidgetColors(
    val bg: Int = 0xFF101214.toInt(),
    val card: Int = 0xFF181B1E.toInt(),
    val line: Int = 0xFF272B30.toInt(),
    val text: Int = 0xFFF0F4FF.toInt(),
    val textSecondary: Int = 0xFFAAB8D4.toInt(),
    val accent: Int = 0xFFE6EAF2.toInt(),
    val onTrack: Int = 0xFF3DD68C.toInt(),
    val offTrack: Int = 0xFFFF6B6B.toInt(),
    val guessed: Int = 0xFFF5B544.toInt(),
) {
    companion object {
        private val HEX = Regex("^#[0-9A-Fa-f]{6}$")

        fun parse(json: JSONObject?): WidgetColors {
            val d = WidgetColors()
            if (json == null) return d
            fun color(key: String, fallback: Int): Int {
                val s = json.opt(key) as? String ?: return fallback
                if (!HEX.matches(s)) return fallback
                return (0xFF000000 or s.substring(1).toLong(16)).toInt()
            }
            return WidgetColors(
                bg = color("bg", d.bg),
                card = color("card", d.card),
                line = color("line", d.line),
                text = color("text", d.text),
                textSecondary = color("textSecondary", d.textSecondary),
                accent = color("accent", d.accent),
                onTrack = color("onTrack", d.onTrack),
                offTrack = color("offTrack", d.offTrack),
                guessed = color("guessed", d.guessed),
            )
        }

        /** [color] with its alpha replaced by [alpha] (0 to 1). */
        fun withAlpha(color: Int, alpha: Double): Int {
            val a = (alpha.coerceIn(0.0, 1.0) * 255 + 0.5).toInt()
            return (color and 0x00FFFFFF) or (a shl 24)
        }
    }
}

/** The verdicts of lib/domain/models.dart, by the names Dart writes. */
enum class WidgetVerdict(val wire: String) {
    ON_TRACK("onTrack"),
    OFF_TRACK("offTrack"),
    NEUTRAL("neutral"),
    GUESSED_ON("guessedOn"),
    GUESSED_OFF("guessedOff"),
    IDLE("idle"),
    UNPLANNED("unplanned"),
    NO_DATA("noData");

    companion object {
        fun fromWire(s: String?): WidgetVerdict? = entries.firstOrNull { it.wire == s }
    }
}

/** One plan block of today, in epoch ms, end exclusive. */
data class WidgetBlock(val name: String, val startMs: Long, val endMs: Long)

/** One piece of the actual lane as the app draws it, in epoch ms. */
data class WidgetPiece(val startMs: Long, val endMs: Long, val verdict: WidgetVerdict)

/**
 * What Dart writes to filesDir/widget_snapshot.json (version 1).
 *
 * [parse] checks every value's type itself, as [NudgeSnapshot.parse] does,
 * so Android's org.json and the JVM test library agree on what is malformed.
 * A malformed block or piece is dropped on its own; a malformed top level
 * gives null, which the widgets show as "Open Drift to start".
 */
data class WidgetSnapshot(
    val computedAtMs: Long,
    val dayStartMs: Long,
    val blocks: List<WidgetBlock>,
    val pieces: List<WidgetPiece>,
    val percent: Int?,
    val driftMin: Int,
    val plannedMin: Int,
    val colors: WidgetColors,
) {
    companion object {
        fun parse(text: String?): WidgetSnapshot? {
            if (text.isNullOrBlank()) return null
            val json = try {
                JSONObject(text)
            } catch (_: Exception) {
                return null
            }
            return parse(json)
        }

        fun parse(json: JSONObject): WidgetSnapshot? {
            if (json.int("v") != 1) return null
            val computedAtMs = json.long("computedAtMs") ?: return null
            val dayStartMs = json.long("dayStartMs") ?: return null
            val blocks = ArrayList<WidgetBlock>()
            when (val a = json.opt("blocks")) {
                null, JSONObject.NULL -> {}
                is JSONArray -> for (i in 0 until a.length()) {
                    val b = a.opt(i) as? JSONObject ?: continue
                    val name = (b.opt("name") as? String)?.trim() ?: continue
                    val start = b.long("startMs") ?: continue
                    val end = b.long("endMs") ?: continue
                    if (end <= start) continue
                    blocks.add(WidgetBlock(name.ifEmpty { "Untitled block" }, start, end))
                }
                else -> return null
            }
            val pieces = ArrayList<WidgetPiece>()
            when (val a = json.opt("pieces")) {
                null, JSONObject.NULL -> {}
                is JSONArray -> for (i in 0 until a.length()) {
                    val p = a.opt(i) as? JSONObject ?: continue
                    val start = p.long("startMs") ?: continue
                    val end = p.long("endMs") ?: continue
                    // An unknown verdict is a newer writer's: drawing it as
                    // any known one would mislead, so it is left out.
                    val verdict = WidgetVerdict.fromWire(p.opt("verdict") as? String) ?: continue
                    if (end <= start) continue
                    pieces.add(WidgetPiece(start, end, verdict))
                }
                else -> return null
            }
            return WidgetSnapshot(
                computedAtMs = computedAtMs,
                dayStartMs = dayStartMs,
                blocks = blocks.sortedWith(compareBy({ it.startMs }, { it.endMs })),
                pieces = pieces.sortedBy { it.startMs },
                percent = json.int("percent")?.coerceIn(0, 100),
                driftMin = (json.int("driftMin") ?: 0).coerceAtLeast(0),
                plannedMin = (json.int("plannedMin") ?: 0).coerceAtLeast(0),
                colors = WidgetColors.parse(json.opt("colors") as? JSONObject),
            )
        }

        /** Whole numbers only; null, JSONObject.NULL and 5.5 are not one. */
        private fun JSONObject.long(key: String): Long? {
            val n = opt(key) as? Number ?: return null
            val l = n.toLong()
            return if (n.toDouble() == l.toDouble()) l else null
        }

        private fun JSONObject.int(key: String): Int? {
            val l = long(key) ?: return null
            return if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else null
        }
    }
}

/** Whether the widgets have today's data to show. */
enum class WidgetDay { MISSING, OLD_DAY, TODAY }

/** Every line the three widgets show, worked out at render time. */
data class WidgetText(
    val day: WidgetDay,
    /** The current block's name, "No block now", or the empty-state line. */
    val headline: String,
    /** "42 min left", "Next: Family at 18:00", or null in the empty state. */
    val detail: String?,
    /** The current block, or null. */
    val block: WidgetBlock?,
    /** "Today 74%", "Nothing planned yet", "No score yet", or null. */
    val score: String?,
    /** "55 min drift", "No drift", or null with no score. */
    val drift: String?,
    /** "updated 14:05" when the snapshot is over three hours old. */
    val stale: String?,
    /** The ring's caption, in two parts so a narrow ring can stack them. */
    val ring: RingCaption,
    /** The ring's fill, 0 to 100, or null for a bare track. */
    val ringPercent: Int?,
) {
    /** The ring's caption on one line: "Deep work · 42 min left". */
    val ringCaption: String get() = ring.oneLine
}

/**
 * The ring's caption as [first] and an optional [second] part: on one line
 * joined by [separator] where it fits, stacked where it does not.
 * "Deep work" and "42 min left"; "Open Drift" and "to start".
 */
data class RingCaption(val first: String, val second: String?, val separator: String) {
    val oneLine: String get() = if (second == null) first else first + separator + second
}

/** A tick on the strips' time axis: where it is (0 to 1) and its label. */
data class StripTick(val fraction: Double, val label: String)

/** One drawn span on a strip, from [from] to [to] along it (0 to 1). */
data class StripSpan(val from: Double, val to: Double, val verdict: WidgetVerdict?)

/** The strips' time axis: today from 06:00 (or the first block's hour,
 * when earlier) to the next midnight. */
data class StripAxis(val startMs: Long, val endMs: Long, val ticks: List<StripTick>) {
    fun fraction(ms: Long): Double =
        if (endMs <= startMs) 0.0
        else ((ms - startMs).toDouble() / (endMs - startMs)).coerceIn(0.0, 1.0)
}

/**
 * The widgets' logic, with no Android types, so the JVM tests cover it.
 * Every function takes the render time and the zone, never the clock.
 */
object WidgetModel {
    const val STALE_AFTER_MS = 3 * 60 * 60 * 1000L
    const val EMPTY_MISSING = "Open Drift to start"
    const val EMPTY_OLD_DAY = "Open Drift to see today"
    const val NO_BLOCK = "No block now"

    private val CLOCK = DateTimeFormatter.ofPattern("HH:mm")

    /** Minutes as "1 h 25 min", "45 min" or "2 h": formatMinutes in
     * lib/widgets/score_card.dart. */
    fun formatMinutes(minutes: Int): String {
        if (minutes < 60) return "$minutes min"
        val h = minutes / 60
        val m = minutes % 60
        return if (m == 0) "$h h" else "$h h $m min"
    }

    /** "18:00" for an instant in [zone]. */
    fun clock(ms: Long, zone: ZoneId): String =
        CLOCK.format(Instant.ofEpochMilli(ms).atZone(zone))

    /** Whole minutes from [nowMs] to [endMs], rounded up: the last minute
     * reads "1 min left", never "0 min left". */
    fun minutesLeft(endMs: Long, nowMs: Long): Int {
        val ms = endMs - nowMs
        if (ms <= 0) return 0
        return ((ms + 59_999) / 60_000).toInt()
    }

    private fun localDate(ms: Long, zone: ZoneId): LocalDate =
        Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()

    /** dayStartMs is a local midnight; comparing calendar dates keeps that
     * right across daylight-saving changes. */
    fun day(snapshot: WidgetSnapshot?, nowMs: Long, zone: ZoneId): WidgetDay = when {
        snapshot == null -> WidgetDay.MISSING
        localDate(snapshot.dayStartMs, zone) != localDate(nowMs, zone) -> WidgetDay.OLD_DAY
        else -> WidgetDay.TODAY
    }

    /** "updated 14:05" when the snapshot is more than three hours old. */
    fun staleLabel(snapshot: WidgetSnapshot, nowMs: Long, zone: ZoneId): String? =
        if (nowMs - snapshot.computedAtMs > STALE_AFTER_MS) {
            "updated ${clock(snapshot.computedAtMs, zone)}"
        } else null

    /** The block running at [nowMs]. Where blocks overlap, the one that
     * started last: it is the more specific one. */
    fun currentBlock(blocks: List<WidgetBlock>, nowMs: Long): WidgetBlock? =
        blocks.filter { nowMs >= it.startMs && nowMs < it.endMs }
            .maxWithOrNull(compareBy<WidgetBlock>({ it.startMs }, { -it.endMs }))

    /** The first block starting after [nowMs]. */
    fun nextBlock(blocks: List<WidgetBlock>, nowMs: Long): WidgetBlock? =
        blocks.filter { it.startMs > nowMs }.minByOrNull { it.startMs }

    fun timeLeftText(block: WidgetBlock, nowMs: Long): String =
        "${formatMinutes(minutesLeft(block.endMs, nowMs))} left"

    fun nextText(blocks: List<WidgetBlock>, nowMs: Long, zone: ZoneId): String {
        val next = nextBlock(blocks, nowMs) ?: return "Nothing else planned today"
        return "Next: ${next.name} at ${clock(next.startMs, zone)}"
    }

    fun scoreText(snapshot: WidgetSnapshot): String = when {
        snapshot.percent != null -> "Today ${snapshot.percent}%"
        snapshot.blocks.isEmpty() -> "Nothing planned yet"
        else -> "No score yet"
    }

    fun driftText(snapshot: WidgetSnapshot): String? = when {
        snapshot.percent == null -> null
        snapshot.driftMin == 0 -> "No drift"
        else -> "${formatMinutes(snapshot.driftMin)} drift"
    }

    fun text(snapshot: WidgetSnapshot?, nowMs: Long, zone: ZoneId): WidgetText {
        val day = day(snapshot, nowMs, zone)
        if (snapshot == null || day != WidgetDay.TODAY) {
            val old = day == WidgetDay.OLD_DAY
            return WidgetText(
                day = day,
                headline = if (old) EMPTY_OLD_DAY else EMPTY_MISSING,
                detail = null,
                block = null,
                score = null,
                drift = null,
                stale = null,
                ring = RingCaption("Open Drift", if (old) "to see today" else "to start", " "),
                ringPercent = null,
            )
        }
        val block = currentBlock(snapshot.blocks, nowMs)
        return WidgetText(
            day = day,
            headline = block?.name ?: NO_BLOCK,
            detail = if (block != null) timeLeftText(block, nowMs)
            else nextText(snapshot.blocks, nowMs, zone),
            block = block,
            score = scoreText(snapshot),
            drift = driftText(snapshot),
            stale = staleLabel(snapshot, nowMs, zone),
            ring = if (block != null) RingCaption(block.name, timeLeftText(block, nowMs), " · ")
            else RingCaption(NO_BLOCK, null, ""),
            ringPercent = snapshot.percent,
        )
    }

    /**
     * [caption] on one line in [maxWidth], as [measure] gives widths. The
     * first part gives way, cut and ended with "…"; the second part (the
     * time left) is kept whole, and the first goes entirely when not even
     * one letter of it fits. A caption with no second part comes back as
     * it is, for the TextView to ellipsize.
     */
    fun fitCaption(caption: RingCaption, maxWidth: Float, measure: (String) -> Float): String {
        val full = caption.oneLine
        val second = caption.second ?: return full
        if (measure(full) <= maxWidth) return full
        var n = caption.first.length - 1
        while (n >= 1) {
            // Never split a surrogate pair (an emoji in a block name).
            if (Character.isHighSurrogate(caption.first[n - 1])) {
                n--
                continue
            }
            val cut = caption.first.substring(0, n).trimEnd()
            if (cut.isNotEmpty()) {
                val s = "$cut…${caption.separator}$second"
                if (measure(s) <= maxWidth) return s
            }
            n--
        }
        return second
    }

    /** Today from 06:00, or from the first block's whole hour when that is
     * earlier, to the next local midnight. Ticks sit on 00, 06, 12, 18 and
     * 24 where they fall inside the axis. */
    fun stripAxis(snapshot: WidgetSnapshot, zone: ZoneId): StripAxis {
        val date = localDate(snapshot.dayStartMs, zone)
        val dayStart = date.atStartOfDay(zone).toInstant().toEpochMilli()
        val dayEnd = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val firstHour = snapshot.blocks
            .filter { it.endMs > dayStart && it.startMs < dayEnd }
            .minOfOrNull { maxOf(it.startMs, dayStart) }
            ?.let { Instant.ofEpochMilli(it).atZone(zone).hour }
        val startHour = minOf(6, firstHour ?: 6)
        fun at(hour: Int): Long = if (hour >= 24) dayEnd
        else date.atTime(hour, 0).atZone(zone).toInstant().toEpochMilli()
        val start = at(startHour)
        val axis = StripAxis(start, dayEnd, emptyList())
        val ticks = listOf(0, 6, 12, 18, 24)
            .filter { it >= startHour }
            .map { StripTick(axis.fraction(at(it)), it.toString().padStart(2, '0')) }
        return axis.copy(ticks = ticks)
    }

    /** The plan strip: each block's span on [axis], clipped to it. */
    fun planSpans(snapshot: WidgetSnapshot, axis: StripAxis): List<StripSpan> =
        snapshot.blocks.mapNotNull { b ->
            val from = axis.fraction(b.startMs)
            val to = axis.fraction(b.endMs)
            if (to > from) StripSpan(from, to, null) else null
        }

    /** The actual strip: each piece's span on [axis] with its verdict. */
    fun actualSpans(snapshot: WidgetSnapshot, axis: StripAxis): List<StripSpan> =
        snapshot.pieces.mapNotNull { p ->
            val from = axis.fraction(p.startMs)
            val to = axis.fraction(p.endMs)
            if (to > from) StripSpan(from, to, p.verdict) else null
        }

    /** Where the now line goes, or null outside the axis. */
    fun nowFraction(axis: StripAxis, nowMs: Long): Double? =
        if (nowMs < axis.startMs || nowMs > axis.endMs) null else axis.fraction(nowMs)

    /** The fill for a piece: verdictColor in lib/widgets/verdict_style.dart,
     * with the guessed fill's alpha from lane_painter.dart. */
    fun verdictFill(c: WidgetColors, v: WidgetVerdict): Int = when (v) {
        WidgetVerdict.ON_TRACK -> c.onTrack
        WidgetVerdict.OFF_TRACK -> c.offTrack
        WidgetVerdict.NEUTRAL -> c.textSecondary
        WidgetVerdict.GUESSED_ON, WidgetVerdict.GUESSED_OFF -> WidgetColors.withAlpha(c.guessed, 0.28)
        WidgetVerdict.IDLE -> WidgetColors.withAlpha(c.onTrack, 0.22)
        WidgetVerdict.UNPLANNED -> WidgetColors.withAlpha(c.textSecondary, 0.35)
        WidgetVerdict.NO_DATA -> c.line
    }

    /** The dashed outline colour, where the app draws one. */
    fun verdictOutline(c: WidgetColors, v: WidgetVerdict): Int? = when (v) {
        WidgetVerdict.GUESSED_ON, WidgetVerdict.GUESSED_OFF -> c.guessed
        WidgetVerdict.IDLE -> c.onTrack
        else -> null
    }
}
