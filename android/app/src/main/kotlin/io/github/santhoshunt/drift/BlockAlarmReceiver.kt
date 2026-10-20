package io.github.santhoshunt.drift

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires at a block reminder's time (TodayNotifications.scheduleNext): posts
 * the heads-up that is due, moves the block notification on, and books the
 * next alarm.
 *
 * Not exported, and reached only through the explicit PendingIntent the
 * app builds, so no other app can post Drift's reminders. An exact
 * allow-while-idle alarm may start a foreground service from the
 * background, so a service that Android stopped is started again here.
 */
class BlockAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val now = System.currentTimeMillis()
        val snapshot = SnapshotFile.read(context)
        if (snapshot != null) {
            try {
                TodayNotifications.postDueReminder(context, snapshot, now)
                if (snapshot.status && TodayNotifications.canPost(context)) {
                    TodayNotifications.createChannels(context)
                    TodayNotifications.postBlock(context, TodayNotifications.blockLine(snapshot, now))
                }
            } catch (e: Exception) {
                NudgeService.recordError(context, e)
            }
        }
        TodayNotifications.scheduleNext(context, snapshot, now)

        val prefs = context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
        if (!NudgeService.running && prefs.getBoolean(NudgeService.KEY_WANTED, false)) {
            try {
                NudgeService.start(context)
            } catch (e: Exception) {
                NudgeService.recordError(context, e)
            }
        }
    }
}
