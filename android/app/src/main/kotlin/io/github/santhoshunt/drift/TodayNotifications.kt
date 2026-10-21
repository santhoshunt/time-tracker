package io.github.santhoshunt.drift

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File

/**
 * The Today notifications (layout option C in plans/decisions.md): a
 * silent pair, the block now or next and today's distracting time with a
 * bar, plus a heads-up 5 minutes before each block and another as it
 * starts.
 *
 * The words come from TodayStatus and the numbers from DayUsage; this only
 * posts. NudgeService refreshes the pair each tick; BlockAlarmReceiver
 * posts the heads-ups from an alarm, so a sleeping phone still gets them.
 */
object TodayNotifications {
    const val TODAY_CHANNEL = "drift_today"
    const val BLOCKS_CHANNEL = "drift_blocks"

    /** The usage notification is the service's own (NudgeService's 1801);
     * 1802 is the nudge and 1803 the evening summary. */
    const val BLOCK_ID = 1804
    const val REMINDER_ID = 1805

    /** Payloads the app turns into a tab (_HomeShellState._onPayload). */
    const val TAB_TODAY = "tab:today"
    const val TAB_USAGE = "tab:usage"

    private const val KEY_ALERTED = "reminders_alerted"
    private const val ALARM_REQUEST = 5
    private const val TAP_TODAY_REQUEST = 6
    private const val TAP_USAGE_REQUEST = 7
    private const val DAY_MS = 24L * 60 * 60 * 1000

    /** As NudgeDecider's rule: a snapshot this old describes a plan that is
     * probably out of date, so it gets no reminders and says so. */
    const val STALE_MS = 36L * 60 * 60 * 1000

    fun isStale(snapshot: NudgeSnapshot, nowMs: Long) = nowMs - snapshot.writtenAtMs > STALE_MS

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        // Low: shown in the Silent section with no sound or pop-up, as
        // Regain's status notification is.
        nm.createNotificationChannel(
            NotificationChannel(TODAY_CHANNEL, "Today", NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) }
        )
        nm.createNotificationChannel(
            NotificationChannel(BLOCKS_CHANNEL, "Block reminders", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    fun canPost(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /** Opens Drift on [payload]'s tab, through the same extra the evening
     * summary uses (NotifyBridge.EXTRA_PAYLOAD). */
    private fun tap(context: Context, payload: String, request: Int): PendingIntent {
        val open = Intent(context, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
            .putExtra(NotifyBridge.EXTRA_PAYLOAD, payload)
        return PendingIntent.getActivity(
            context,
            request,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    /** "Distracting: 39 min" over "46% of 1 h 25 min on apps". Expanded,
     * it also lists the apps with the most distracting time. */
    fun usage(
        context: Context,
        counted: DayUsage.Counted,
        label: (String) -> String,
        colors: NudgeColors,
    ): Notification {
        val line = TodayStatus.usageLine(counted.totalMs, counted.distractingMs)
        val apps = TodayStatus.topApps(counted.distractingByApp, label)
        val builder = NotificationCompat.Builder(context, TODAY_CHANNEL)
        if (apps.isNotEmpty()) {
            builder.setStyle(
                NotificationCompat.BigTextStyle().bigText((listOf(line.text) + apps).joinToString("\n"))
            )
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_drift)
            .setContentTitle(line.title)
            .setContentText(line.text)
            .setColor(colors.offTrack)
            .setContentIntent(tap(context, TAB_USAGE, TAP_USAGE_REQUEST))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
    }

    fun postBlock(context: Context, line: TodayStatus.Line) {
        if (!canPost(context)) return
        val n = NotificationCompat.Builder(context, TODAY_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_drift)
            .setContentTitle(line.title)
            .setContentText(line.text)
            .setContentIntent(tap(context, TAB_TODAY, TAP_TODAY_REQUEST))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            // Sorts the block above the usage numbers, as in Regain.
            .setSortKey("a")
            .build()
        context.getSystemService(NotificationManager::class.java)?.notify(BLOCK_ID, n)
    }

    fun cancelBlock(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(BLOCK_ID)
    }

    /** The heads-up. "Starting now" replaces "Up next" (same id), and each
     * goes away by itself once it no longer holds. */
    private fun postReminder(context: Context, r: TodayStatus.Reminder, nowMs: Long) {
        val line = TodayStatus.reminderLine(r, nowMs, java.time.ZoneId.systemDefault())
        val until = if (r.startsNow) {
            minOf(r.startMs + TodayStatus.START_VALID_MS, r.endMs)
        } else {
            r.startMs + 60_000L
        }
        val n = NotificationCompat.Builder(context, BLOCKS_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_drift)
            .setContentTitle(line.title)
            .setContentText(line.text)
            .setContentIntent(tap(context, TAB_TODAY, TAP_TODAY_REQUEST))
            .setAutoCancel(true)
            .setTimeoutAfter(maxOf(until - nowMs, 1_000L))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .build()
        context.getSystemService(NotificationManager::class.java)?.notify(REMINDER_ID, n)
    }

    private fun alerted(context: Context): Set<String> =
        context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_ALERTED, emptySet()) ?: emptySet()

    /** Keys start with the block's start; anything over two days old goes,
     * so the set stays a handful of entries. commit, not apply: a receiver's
     * process may end right after. */
    private fun markAlerted(context: Context, key: String, nowMs: Long) {
        val kept = alerted(context).filter { k ->
            val start = k.substringBefore(':').toLongOrNull() ?: return@filter false
            start > nowMs - 2 * DAY_MS
        }.toMutableSet()
        kept.add(key)
        context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
            .edit().putStringSet(KEY_ALERTED, kept).commit()
    }

    /** Posts the reminder due now, once. Used by the alarm and, as a
     * fallback for an alarm Android held back, by every service tick. */
    fun postDueReminder(context: Context, snapshot: NudgeSnapshot, nowMs: Long) {
        if (!snapshot.reminders || isStale(snapshot, nowMs) || !canPost(context)) return
        val due = TodayStatus.due(TodayStatus.reminders(snapshot.windows), nowMs, alerted(context))
            ?: return
        createChannels(context)
        postReminder(context, due, nowMs)
        markAlerted(context, due.key, nowMs)
    }

    /** The block line, or a note that the plan here is too old to trust. */
    fun blockLine(snapshot: NudgeSnapshot, nowMs: Long): TodayStatus.Line =
        if (isStale(snapshot, nowMs)) {
            TodayStatus.Line("Open Drift to update your plan", "The plan here is over a day old")
        } else {
            TodayStatus.blockLine(snapshot.windows, nowMs, java.time.ZoneId.systemDefault())
        }

    /**
     * One alarm, for the next reminder after now; replaced on every call.
     * Exact where Android allows it (USE_EXACT_ALARM from 13, the granted
     * SCHEDULE_EXACT_ALARM on 12); otherwise inexact, and the tick and the
     * next alarm post anything still valid. Under Doze Android fires these
     * at most once per nine minutes per app, so "Starting now" can come a
     * few minutes late on a sleeping phone; TodayStatus keeps it valid.
     */
    fun scheduleNext(context: Context, snapshot: NudgeSnapshot?, nowMs: Long) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST,
            Intent(context, BlockAlarmReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val at = if (snapshot == null || !snapshot.reminders) {
            null
        } else {
            TodayStatus.nextAlarmMs(TodayStatus.reminders(snapshot.windows), nowMs)
        }
        if (at == null) {
            am.cancel(pending)
            return
        }
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        try {
            if (exact) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            }
        } catch (e: SecurityException) {
            // Exact alarms revoked between the check and the call.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }
}

/** The snapshot file Dart writes, read without NudgeService's cache, for
 * the alarm receiver. Null when missing or malformed. */
object SnapshotFile {
    fun read(context: Context): NudgeSnapshot? = try {
        val file = File(context.filesDir, NudgeService.SNAPSHOT_FILE)
        if (file.isFile) NudgeSnapshot.parse(JSONObject(file.readText())) else null
    } catch (_: Exception) {
        null
    }
}
