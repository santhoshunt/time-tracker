package io.github.santhoshunt.drift

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/**
 * The `drift/notify` channel (lib/platform/background_bridge.dart): the
 * evening summary notification, its booking, and the payload a tap on it
 * carries into the app.
 *
 * Dart builds the text (lib/services/evening_summary.dart); this only
 * posts it. The summary is booked as one-time work with a delay rather
 * than an exact alarm, which would need a permission; WorkManager may run
 * it some minutes late under Doze, which is fine for an evening review.
 *
 * Works without an Activity (the headless engine): only
 * takeLaunchPayload needs one, and answers null without it.
 */
class NotifyBridge(
    private val context: Context,
    private val activity: Activity? = null,
) {
    companion object {
        const val CHANNEL = "drift/notify"
        const val SUMMARY_CHANNEL = "drift_summary"
        const val WORK_NAME = "drift_summary"
        const val EXTRA_PAYLOAD = "launch_payload"
        const val KEY_SUMMARY = "summary"

        /** After NudgeService's 1801 and 1802. */
        private const val SUMMARY_NOTIFICATION_ID = 1803
        private const val TAP_REQUEST = 3

        /** Books the summary for [atMs], replacing any earlier booking.
         * Held back while a summary run is going (see SummaryBookingGate). */
        fun schedule(context: Context, atMs: Long) {
            if (DriftBackground.deferBooking(atMs)) return
            book(context, atMs, ExistingWorkPolicy.REPLACE)
        }

        /** Cancels the booked summary; held back like [schedule]. */
        fun cancel(context: Context) {
            if (DriftBackground.deferBooking(null)) return
            WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
        }

        /** [policy] is REPLACE from Dart and APPEND_OR_REPLACE from the end
         * of a summary run, where REPLACE would cancel the work that is
         * still finishing. Appended work waits for that run, which ends a
         * moment later, so the delay still lands on the right minute. */
        fun book(context: Context, atMs: Long, policy: ExistingWorkPolicy) {
            val delay = BackgroundLogic.delayMs(atMs, System.currentTimeMillis())
            val request = OneTimeWorkRequest.Builder(SummaryWorker::class.java)
                .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                .setInputData(Data.Builder().putBoolean(KEY_SUMMARY, true).build())
                // A retry means the app's engine was still starting; a
                // minute later it is usually ready.
                .setBackoffCriteria(BackoffPolicy.LINEAR, 1, TimeUnit.MINUTES)
                .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(WORK_NAME, policy, request)
        }

        /** The payload a summary tap put on [intent], removed so a
         * recreated activity does not open Review a second time. */
        fun takePayload(intent: Intent?): String? {
            val payload = intent?.getStringExtra(EXTRA_PAYLOAD) ?: return null
            intent.removeExtra(EXTRA_PAYLOAD)
            return payload
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "postSummary" -> {
                val title = call.argument<String>("title")
                val lines = call.argument<List<String>>("lines") ?: emptyList()
                val payload = call.argument<String>("payload")
                if (title == null) {
                    result.error("BAD_ARGS", "title is required.", null)
                } else {
                    result.success(postSummary(title, lines, payload))
                }
            }
            "scheduleSummary" -> {
                // A Dart int this large always arrives as a Long, but a
                // Number read keeps a small test value working too.
                val at = call.argument<Number>("epochMs")?.toLong()
                if (at == null) {
                    result.error("BAD_ARGS", "epochMs is required.", null)
                } else {
                    schedule(context, at)
                    result.success(null)
                }
            }
            "cancelSummary" -> {
                cancel(context)
                result.success(null)
            }
            "takeLaunchPayload" -> result.success(takePayload(activity?.intent))
            else -> result.notImplemented()
        }
    }

    /** False when Android would not show it (no notification permission,
     * or notifications blocked for the app), so Dart does not mark the day
     * as sent and a later run tries again. */
    private fun postSummary(title: String, lines: List<String>, payload: String?): Boolean {
        val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val manager = NotificationManagerCompat.from(context)
        if (!granted || !manager.areNotificationsEnabled()) return false
        createChannel()

        val open = Intent(context, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
        if (payload != null) open.putExtra(EXTRA_PAYLOAD, payload)
        // UPDATE_CURRENT: the extra changes every day, and without it the
        // older PendingIntent with yesterday's payload would be reused.
        val tap = PendingIntent.getActivity(
            context,
            TAP_REQUEST,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(context, SUMMARY_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_drift)
            .setContentTitle(title)
            .setContentText(lines.firstOrNull() ?: "")
            .setStyle(NotificationCompat.BigTextStyle().bigText(lines.joinToString("\n")))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .build()
        return try {
            manager.notify(SUMMARY_NOTIFICATION_ID, notification)
            true
        } catch (_: SecurityException) {
            // Permission revoked between the check and the post.
            false
        }
    }

    /** Default importance: it should sound like any message, not jump over
     * the screen like a nudge. Creating an existing channel is a no-op. */
    private fun createChannel() {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(SUMMARY_CHANNEL, "Evening summary", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }
}
