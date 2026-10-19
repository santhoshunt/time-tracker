package io.github.santhoshunt.drift

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.time.ZoneId

/**
 * The three home-screen widgets, drawn from filesDir/widget_snapshot.json,
 * which Dart writes (lib/services/widget_snapshot.dart). Every line that
 * depends on the clock (the current block, time left, the next block, the
 * now line) is worked out here at render time by [WidgetModel], so the
 * 30-minute redraw in each *_info.xml stays right while Drift is closed.
 *
 * The system calls the providers from a broadcast, where an escaping
 * exception kills the whole app process, so every render is wrapped: a
 * widget that cannot draw keeps its last picture.
 *
 * Launchers reapply a new RemoteViews onto the views they already show when
 * the layout is the same, so every render sets each colour, size and
 * visibility it can change, never relying on the layout's defaults.
 */
object DriftWidgets {
    const val SNAPSHOT_FILE = "widget_snapshot.json"

    /** The card padding the 4x2 layouts use, in dp. */
    private const val PAD_H = 16
    private const val PAD_V = 10

    /** The ring layout's padding on every side, in dp. */
    private const val RING_PAD = 10

    /** The smallest ring, in dp, a stacked two-line caption may leave. */
    private const val MIN_RING_DP = 56f

    /** The strip bitmap's height in dp, as drift_widget_strips.xml sizes
     * its ImageView. */
    private const val STRIP_DP = 38

    enum class Kind(val code: Int, val fallbackW: Int, val fallbackH: Int) {
        NOW(1, 250, 110),
        STRIPS(2, 250, 110),
        RING(3, 110, 110),
    }

    private val providers = listOf(
        NowWidgetProvider::class.java to Kind.NOW,
        StripsWidgetProvider::class.java to Kind.STRIPS,
        RingWidgetProvider::class.java to Kind.RING,
    )

    /** Redraws every placed Drift widget. Dart calls this (through the
     * drift/widgets channel) after writing a new snapshot. Never throws. */
    fun refreshAll(context: Context) {
        try {
            val app = context.applicationContext ?: context
            val manager = AppWidgetManager.getInstance(app) ?: return
            val snapshot = readSnapshot(app)
            for ((cls, kind) in providers) {
                val ids = try {
                    manager.getAppWidgetIds(ComponentName(app, cls))
                } catch (_: Exception) {
                    continue
                }
                for (id in ids) render(app, manager, id, kind, snapshot)
            }
        } catch (_: Exception) {
            // Drawn again on the next snapshot or 30-minute redraw.
        }
    }

    /** Redraws [ids] of one widget kind; the providers call this. */
    fun render(context: Context, manager: AppWidgetManager, ids: IntArray, kind: Kind) {
        val snapshot = readSnapshot(context)
        for (id in ids) render(context, manager, id, kind, snapshot)
    }

    /** The snapshot, or null when it is missing or does not parse. */
    fun readSnapshot(context: Context): WidgetSnapshot? = try {
        val file = File(context.filesDir, SNAPSHOT_FILE)
        if (file.isFile) WidgetSnapshot.parse(file.readText()) else null
    } catch (_: Exception) {
        null
    }

    private fun render(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        kind: Kind,
        snapshot: WidgetSnapshot?,
    ) {
        try {
            val nowMs = System.currentTimeMillis()
            val zone = ZoneId.systemDefault()
            val colors = snapshot?.colors ?: WidgetColors()
            val text = WidgetModel.text(snapshot, nowMs, zone)
            val today = snapshot?.takeIf { text.day == WidgetDay.TODAY }
            update(context, manager, id, kind) { w, h, bitmaps ->
                when (kind) {
                    Kind.NOW -> now(context, w, h, id, text, colors)
                    Kind.STRIPS -> strips(context, w, h, bitmaps, id, today, text, colors, nowMs, zone)
                    Kind.RING -> ring(context, w, h, bitmaps, id, text, colors)
                }
            }
        } catch (_: Exception) {
            // Drawn again on the next snapshot or 30-minute redraw.
        }
    }

    // --- Sizes and the update -----------------------------------------------

    /** The size in dp the widget is drawn at now: the launcher reports the
     * portrait cell as min width by max height and the landscape one as max
     * width by min height. */
    private fun sizeDp(context: Context, options: Bundle?, kind: Kind): Pair<Int, Int> {
        val portrait = context.resources.configuration.orientation !=
            Configuration.ORIENTATION_LANDSCAPE
        fun opt(key: String, fallback: Int) =
            options?.getInt(key, 0)?.takeIf { it > 0 } ?: fallback
        return if (portrait) {
            opt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, kind.fallbackW) to
                opt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, kind.fallbackH)
        } else {
            opt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, kind.fallbackW) to
                opt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, kind.fallbackH)
        }
    }

    /** The sizes the widget is drawn at: landscape (max width by min
     * height), then portrait (min width by max height). One size when they
     * match or the launcher has not reported any. */
    private fun orientationSizes(context: Context, options: Bundle?, kind: Kind): List<Pair<Int, Int>> {
        fun opt(key: String) = options?.getInt(key, 0) ?: 0
        val minW = opt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val maxW = opt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
        val minH = opt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
        val maxH = opt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        if (minW <= 0 || maxW <= 0 || minH <= 0 || maxH <= 0) {
            return listOf(sizeDp(context, options, kind))
        }
        if (minW == maxW && minH == maxH) return listOf(minW to maxH)
        return listOf(maxW to minH, minW to maxH)
    }

    /** The bitmaps of one update, each drawn once: where both orientations
     * ask for the same key they share one instance, which RemoteViews sends
     * once. With [enabled] false it draws none: the fallback update. */
    class Bitmaps(val enabled: Boolean = true) {
        private val drawn = HashMap<String, Bitmap>()

        fun get(key: String, draw: () -> Bitmap): Bitmap? =
            if (enabled) drawn.getOrPut(key, draw) else null
    }

    /** Sends the widget drawn once per orientation, so lines and bitmaps
     * sized for one never clip in the other. Where the system refuses the
     * update (bitmaps past the binder's size limit), it sends the same
     * views without bitmaps, so the widget never stays on an old picture. */
    private fun update(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        kind: Kind,
        build: (Int, Int, Bitmaps) -> RemoteViews,
    ) {
        val sizes = orientationSizes(context, manager.getAppWidgetOptions(id), kind)
        fun views(bitmaps: Bitmaps): RemoteViews {
            val drawn = sizes.map { (w, h) -> build(w, h, bitmaps) }
            return if (drawn.size == 1) drawn[0] else RemoteViews(drawn[0], drawn[1])
        }
        try {
            manager.updateAppWidget(id, views(Bitmaps()))
        } catch (_: RuntimeException) {
            // TransactionTooLargeException arrives wrapped in a
            // RuntimeException from AppWidgetManager.
            manager.updateAppWidget(id, views(Bitmaps(enabled = false)))
        }
    }

    /** How tall one line of [sp] text draws in a TextView, in dp, at the
     * user's font size (TextView keeps the font's top-to-bottom padding). */
    private fun lineDp(context: Context, sp: Float): Float {
        val dm = context.resources.displayMetrics
        val paint = Paint().apply {
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, dm)
        }
        val fm = paint.fontMetricsInt
        return (fm.bottom - fm.top) / dm.density
    }

    /** How wide [text] draws at [sp], in dp, at the user's font size. */
    private fun textWidthDp(context: Context, text: String, sp: Float, bold: Boolean = false): Float {
        val dm = context.resources.displayMetrics
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, dm)
            typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        return paint.measureText(text) / dm.density
    }

    // --- Shared pieces ------------------------------------------------------

    /** Opens Drift. MainActivity itself, not the launcher alias: the alias
     * changes when the icon is switched (IconSwitcher.kt), and a widget
     * holding a disabled alias would do nothing until its next redraw. One
     * request code per widget and kind, so no widget's tap replaces
     * another's. */
    private fun openApp(context: Context, id: Int, kind: Kind): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return PendingIntent.getActivity(
            context,
            id * 4 + kind.code,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** The layout with the card painted in the theme and the tap set. */
    private fun base(context: Context, layout: Int, c: WidgetColors, id: Int, kind: Kind): RemoteViews =
        RemoteViews(context.packageName, layout).apply {
            setInt(R.id.dw_bg, "setColorFilter", c.card)
            setInt(R.id.dw_border, "setColorFilter", c.line)
            setOnClickPendingIntent(R.id.dw_root, openApp(context, id, kind))
        }

    private fun RemoteViews.show(viewId: Int, visible: Boolean) =
        setViewVisibility(viewId, if (visible) View.VISIBLE else View.GONE)

    /** Sets [value] and shows the view, or hides it for null. */
    private fun RemoteViews.textOrGone(viewId: Int, value: String?) {
        setTextViewText(viewId, value ?: "")
        show(viewId, value != null)
    }

    private fun spoken(vararg parts: String?): String =
        listOf("Drift", *parts).filterNotNull().joinToString(". ")

    // --- Drift now (4x2) ----------------------------------------------------

    private fun now(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        id: Int,
        t: WidgetText,
        c: WidgetColors,
    ): RemoteViews {
        val v = base(context, R.layout.drift_widget_now, c, id, Kind.NOW)
        v.setTextColor(R.id.dw_label, c.textSecondary)
        v.setTextColor(R.id.dw_stale, c.textSecondary)
        v.setTextColor(R.id.dw_headline, c.text)
        v.setTextColor(R.id.dw_detail, c.text)
        v.setTextColor(R.id.dw_score, c.text)
        v.setTextColor(R.id.dw_drift, c.textSecondary)

        if (t.day != WidgetDay.TODAY) {
            v.show(R.id.dw_label_row, true)
            v.textOrGone(R.id.dw_stale, null)
            v.show(R.id.dw_bar, false)
            v.setTextViewText(R.id.dw_headline, t.headline)
            // The largest size up to 18sp at which the whole line fits the
            // card's width; 13sp is the floor, where it ellipsizes.
            val room = (widthDp - 2 * PAD_H - 2).toFloat()
            val size = listOf(18f, 17f, 16f, 15f, 14f)
                .firstOrNull { textWidthDp(context, t.headline, it, bold = true) <= room } ?: 13f
            v.setTextViewTextSize(R.id.dw_headline, TypedValue.COMPLEX_UNIT_SP, size)
            v.textOrGone(R.id.dw_detail, null)
            v.show(R.id.dw_score_row, false)
            v.setContentDescription(R.id.dw_root, spoken(t.headline))
            return v
        }

        v.textOrGone(R.id.dw_stale, t.stale)
        v.show(R.id.dw_bar, true)
        v.setInt(R.id.dw_bar, "setColorFilter", if (t.block != null) c.accent else c.line)
        v.setTextViewText(R.id.dw_headline, t.headline)
        v.setTextViewTextSize(R.id.dw_headline, TypedValue.COMPLEX_UNIT_SP, 20f)
        v.textOrGone(R.id.dw_detail, t.detail)
        v.setTextViewText(R.id.dw_score, t.score ?: "")
        v.textOrGone(R.id.dw_drift, t.drift)

        // The lines' heights at the user's font size against the room the
        // card has; the label row goes first, then the score row, so the
        // block name and its time left never clip.
        val label = lineDp(context, 12f) + 2
        val main = lineDp(context, 20f) + lineDp(context, 14f)
        val score = 6 + lineDp(context, 13f)
        val room = heightDp - 2 * PAD_V
        val showLabel = main + score + label <= room
        val showScore = main + score <= room
        v.show(R.id.dw_label_row, showLabel)
        v.show(R.id.dw_score_row, showScore)
        // With the label row gone, "updated 14:05" takes the drift's place,
        // so an old score never shows unmarked.
        if (!showLabel && t.stale != null) v.textOrGone(R.id.dw_drift, t.stale)
        v.setContentDescription(R.id.dw_root, spoken(t.headline, t.detail, t.score, t.drift, t.stale))
        return v
    }

    // --- Drift plan and actual (4x2) ----------------------------------------

    private fun strips(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: Bitmaps,
        id: Int,
        snapshot: WidgetSnapshot?,
        t: WidgetText,
        c: WidgetColors,
        nowMs: Long,
        zone: ZoneId,
    ): RemoteViews {
        val v = base(context, R.layout.drift_widget_strips, c, id, Kind.STRIPS)
        v.setTextColor(R.id.dw_title, c.text)
        v.setTextColor(R.id.dw_time, c.textSecondary)
        v.setTextColor(R.id.dw_strip_text, c.text)
        v.setTextColor(R.id.dw_drift, c.textSecondary)
        v.setTextColor(R.id.dw_stale, c.textSecondary)
        v.setTextColor(R.id.dw_empty, c.text)

        if (snapshot == null) {
            v.show(R.id.dw_body, false)
            v.textOrGone(R.id.dw_empty, t.headline)
            v.setContentDescription(R.id.dw_root, spoken(t.headline))
            return v
        }
        v.show(R.id.dw_body, true)
        v.textOrGone(R.id.dw_empty, null)
        v.setTextViewText(R.id.dw_title, t.score ?: "")
        v.setTextViewText(R.id.dw_time, WidgetModel.clock(nowMs, zone))

        // One strip per width: both orientations share it where the widths
        // match. Without bitmaps (the fallback update) a line of text says
        // what the block lane would have shown.
        val strip = bitmaps.get("strip:$widthDp") {
            stripBitmap(context, widthDp, snapshot, c, nowMs, zone)
        }
        if (strip != null) {
            v.setImageViewBitmap(R.id.dw_strip, strip)
            v.show(R.id.dw_strip, true)
            v.textOrGone(R.id.dw_strip_text, null)
        } else {
            v.show(R.id.dw_strip, false)
            v.textOrGone(R.id.dw_strip_text, "${t.headline} · ${t.detail}")
        }

        // The drift line stays in place even when empty: its weight keeps
        // "updated 14:05" at the right edge.
        v.setTextViewText(R.id.dw_drift, t.drift ?: "")
        v.textOrGone(R.id.dw_stale, t.stale)
        val header = lineDp(context, 16f)
        val middle = 8 + if (strip != null) STRIP_DP.toFloat() else lineDp(context, 14f)
        val footer = 4 + lineDp(context, 12f)
        val hasFooter = t.drift != null || t.stale != null
        val showFooter = hasFooter && header + middle + footer <= heightDp - 2 * PAD_V
        v.show(R.id.dw_footer, showFooter)
        // With the footer gone, "updated 14:05" takes the clock's place, so
        // an old score never shows unmarked.
        if (!showFooter && t.stale != null) v.setTextViewText(R.id.dw_time, t.stale)
        v.setContentDescription(
            R.id.dw_root,
            spoken(t.score, t.drift, "${t.headline}, ${t.detail}", t.stale),
        )
        return v
    }

    /**
     * The plan strip (blocks in the accent), the actual strip (pieces in
     * their verdict colours, as lib/painters/lane_painter.dart fills them),
     * the now line, and the hour ticks, drawn at the ImageView's exact size
     * so fitXY never stretches the labels. At most 2 pixels per dp and 1200
     * pixels wide: about 365 KB at the widest, which keeps both
     * orientations' strips together under the binder's limit in the usual
     * case, and [update] resends without them where it is not.
     */
    private fun stripBitmap(
        context: Context,
        widgetW: Int,
        snapshot: WidgetSnapshot,
        c: WidgetColors,
        nowMs: Long,
        zone: ZoneId,
    ): Bitmap {
        val dm = context.resources.displayMetrics
        val d = minOf(dm.density, 2f)
        val w = ((widgetW - 2 * PAD_H) * d).toInt().coerceIn(64, 1200)
        val h = (STRIP_DP * d).toInt()
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        val axis = WidgetModel.stripAxis(snapshot, zone)
        val wf = w.toFloat()
        fun x(f: Double) = (f * wf).toFloat()

        // Plan: a track, then each block as its own rounded bar.
        val planTop = 0f
        val planH = 6 * d
        val planR = planH / 2
        fill.color = c.line
        canvas.drawRoundRect(RectF(0f, planTop, wf, planTop + planH), planR, planR, fill)
        fill.color = c.accent
        for (s in WidgetModel.planSpans(snapshot, axis)) {
            val left = x(s.from)
            val right = maxOf(x(s.to), left + 2 * d)
            canvas.drawRoundRect(RectF(left, planTop, right, planTop + planH), planR, planR, fill)
        }

        // Actual: pieces clipped to one rounded track, so neighbours meet
        // with no notches between them.
        val actTop = planTop + planH + 4 * d
        val actH = 12 * d
        val actR = 4 * d
        val track = RectF(0f, actTop, wf, actTop + actH)
        fill.color = c.line
        canvas.drawRoundRect(track, actR, actR, fill)
        canvas.save()
        canvas.clipPath(Path().apply { addRoundRect(track, actR, actR, Path.Direction.CW) })
        val dash = DashPathEffect(floatArrayOf(3 * d, 3 * d), 0f)
        for (s in WidgetModel.actualSpans(snapshot, axis)) {
            val verdict = s.verdict ?: continue
            val left = x(s.from)
            val right = maxOf(x(s.to), left + 1 * d)
            val rect = RectF(left, actTop, right, actTop + actH)
            fill.color = WidgetModel.verdictFill(c, verdict)
            canvas.drawRect(rect, fill)
            if (verdict == WidgetVerdict.NO_DATA) {
                // Stripes: nothing is known, so it must not look like any
                // verdict.
                canvas.save()
                canvas.clipRect(rect)
                stroke.pathEffect = null
                stroke.strokeWidth = 1 * d
                stroke.color = WidgetColors.withAlpha(c.textSecondary, 0.5)
                var sx = left - actH
                while (sx < right) {
                    canvas.drawLine(sx, actTop + actH, sx + actH, actTop, stroke)
                    sx += 5 * d
                }
                canvas.restore()
            }
            val outline = WidgetModel.verdictOutline(c, verdict)
            if (outline != null && right - left >= 4 * d) {
                stroke.pathEffect = dash
                stroke.strokeWidth = 1.2f * d
                stroke.color = outline
                val inset = 0.6f * d
                canvas.drawRoundRect(
                    RectF(left + inset, actTop + inset, right - inset, actTop + actH - inset),
                    2 * d, 2 * d, stroke,
                )
            }
        }
        canvas.restore()

        // The now line across both strips, in the off-track colour as the
        // Today lane draws it (timeline_lanes.dart), over a card-coloured
        // halo so it reads on any fill in every theme.
        WidgetModel.nowFraction(axis, nowMs)?.let { f ->
            val lw = 1.5f * d
            val halo = 1.5f * d
            val nx = x(f).coerceIn(halo, wf - lw - halo)
            fill.color = c.card
            canvas.drawRect(nx - halo, planTop, nx + lw + halo, actTop + actH, fill)
            fill.color = c.offTrack
            canvas.drawRect(nx, planTop, nx + lw, actTop + actH, fill)
        }

        // Hour ticks and labels: the first label starts at its tick, the
        // last ends at its tick, the rest are centred on theirs.
        val tickTop = actTop + actH + 1 * d
        val tickH = 3 * d
        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = c.textSecondary
            // Follows the font size up to a point: the bitmap's height is
            // fixed, so the labels may not outgrow it.
            textSize = minOf(10f * context.resources.configuration.fontScale, 11f) * d
            typeface = Typeface.DEFAULT
        }
        fill.color = c.textSecondary
        val baseline = h - label.descent()
        for (tick in axis.ticks) {
            val tx = x(tick.fraction).coerceIn(0f, wf - d)
            canvas.drawRect(tx, tickTop, tx + d, tickTop + tickH, fill)
            val tw = label.measureText(tick.label)
            val lx = when {
                tick.fraction <= 0.0 -> 0f
                tick.fraction >= 1.0 -> wf - tw
                else -> (tx - tw / 2).coerceIn(0f, wf - tw)
            }
            canvas.drawText(tick.label, lx, baseline, label)
        }
        return bmp
    }

    // --- Drift score (2x2) --------------------------------------------------

    private fun ring(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: Bitmaps,
        id: Int,
        t: WidgetText,
        c: WidgetColors,
    ): RemoteViews {
        val v = base(context, R.layout.drift_widget_ring, c, id, Kind.RING)
        v.setTextColor(R.id.dw_percent, c.text)
        v.setTextColor(R.id.dw_percent_sub, c.textSecondary)
        v.setTextColor(R.id.dw_caption, if (t.block != null) c.text else c.textSecondary)
        v.setTextColor(R.id.dw_caption2, c.textSecondary)
        v.setTextColor(R.id.dw_stale, c.textSecondary)

        // The caption on one line where it fits; else stacked in two where
        // the ring keeps a readable size; else one line with the block name
        // shortened, so the time left always shows whole.
        val roomW = (widthDp - 2 * RING_PAD).toFloat()
        val line = lineDp(context, 12f)
        val staleDp = lineDp(context, 10f)
        val oneLineRoomH = heightDp - 2 * RING_PAD - 4 - line
        val measure = { s: String -> textWidthDp(context, s, 12f) }
        val cap = t.ring
        val fitsOneLine = measure(cap.oneLine) <= roomW - 2
        val stacked = !fitsOneLine && cap.second != null &&
            minOf(roomW, oneLineRoomH - line) >= MIN_RING_DP
        if (stacked) {
            v.setTextViewText(R.id.dw_caption, cap.first)
            v.textOrGone(R.id.dw_caption2, cap.second)
        } else {
            v.setTextViewText(
                R.id.dw_caption,
                if (t.block != null) WidgetModel.fitCaption(cap, roomW - 2, measure) else cap.oneLine,
            )
            v.textOrGone(R.id.dw_caption2, null)
        }
        val roomH = oneLineRoomH - if (stacked) line else 0f
        // The stale line only where the ring keeps most of its size.
        val showStale = t.stale != null && roomH - staleDp >= minOf(roomW, roomH) * 0.8f
        v.textOrGone(R.id.dw_stale, if (showStale) t.stale else null)
        val ringDp = minOf(roomW, roomH - if (showStale) staleDp else 0f)
            .toInt().coerceAtLeast(40)

        // One ring for both orientations: it is square and fitCenter scales
        // it to the room each one has.
        val percent = t.ringPercent
        val ringBmp = bitmaps.get("ring:${percent ?: -1}") { ringBitmap(percent, c) }
        if (ringBmp != null) v.setImageViewBitmap(R.id.dw_ring, ringBmp)
        v.show(R.id.dw_ring, ringBmp != null)

        when {
            t.day != WidgetDay.TODAY -> {
                v.textOrGone(R.id.dw_percent, null)
                v.show(R.id.dw_percent_sub, false)
            }
            percent == null -> {
                v.textOrGone(R.id.dw_percent, "No score")
                v.setTextColor(R.id.dw_percent, c.textSecondary)
                v.setTextViewTextSize(R.id.dw_percent, TypedValue.COMPLEX_UNIT_DIP, ringDp * 0.13f)
                v.show(R.id.dw_percent_sub, false)
            }
            else -> {
                v.textOrGone(R.id.dw_percent, "$percent%")
                v.setTextViewTextSize(R.id.dw_percent, TypedValue.COMPLEX_UNIT_DIP, ringDp * 0.24f)
                v.setTextViewTextSize(R.id.dw_percent_sub, TypedValue.COMPLEX_UNIT_DIP, ringDp * 0.105f)
                // "on track" under the figure only where the ring has room.
                v.show(R.id.dw_percent_sub, ringDp >= 76)
            }
        }
        v.setContentDescription(
            R.id.dw_root,
            spoken(percent?.let { "$it% on track today" }, t.ringCaption, t.stale),
        )
        return v
    }

    /** The score ring: the track in the line colour, then [percent] of it
     * in the on-track colour from 12 o'clock; with no [percent], the bare
     * track. Always 300 pixels across (about 350 KB), the plan's cap; on a
     * dense screen a big ring is scaled up a little, which a flat arc
     * survives. */
    private fun ringBitmap(percent: Int?, c: WidgetColors): Bitmap {
        val size = 300
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val stroke = size * 0.09f
        val inset = stroke / 2 + 1
        val oval = RectF(inset, inset, size - inset, size - inset)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            color = c.line
        }
        canvas.drawArc(oval, 0f, 360f, false, paint)
        val sweep = (percent ?: 0).coerceIn(0, 100) * 3.6f
        if (sweep > 0f) {
            paint.color = c.onTrack
            paint.strokeCap = if (sweep >= 360f) Paint.Cap.BUTT else Paint.Cap.ROUND
            canvas.drawArc(oval, -90f, sweep, false, paint)
        }
        return bmp
    }
}

/** Drift now (4x2): the current block, its time left, today's score and
 * drift. */
class NowWidgetProvider : DriftWidgetProvider(DriftWidgets.Kind.NOW)

/** Drift plan and actual (4x2): today's plan above what happened. */
class StripsWidgetProvider : DriftWidgetProvider(DriftWidgets.Kind.STRIPS)

/** Drift score (2x2): the score ring and the current block. */
class RingWidgetProvider : DriftWidgetProvider(DriftWidgets.Kind.RING)

/** One picker entry per subclass; [DriftWidgets] draws each kind. */
abstract class DriftWidgetProvider(private val kind: DriftWidgets.Kind) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        DriftWidgets.render(context, manager, ids, kind)
    }

    /** A resize changes which lines fit, the strip's width and the ring's
     * size. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        DriftWidgets.render(context, manager, intArrayOf(id), kind)
    }
}
