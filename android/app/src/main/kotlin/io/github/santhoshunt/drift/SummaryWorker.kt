package io.github.santhoshunt.drift

import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * The evening summary run: the same Dart run as the hourly one
 * (DriftBackground), booked as unique one-time work `drift_summary` for
 * the summary time (NotifyBridge.schedule). Dart decides whether the
 * summary is due, posts it, and books the next one.
 *
 * That booking is held back until the run is over (SummaryBookingGate),
 * because replacing this work while it runs would cancel it mid-write.
 */
class SummaryWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {
    override fun doWork(): Result {
        val context = applicationContext
        DriftBackground.beginSummaryRun()
        var outcome = RunOutcome.FAILED
        try {
            outcome = DriftBackground.run(context, summary = true)
        } finally {
            val pending = DriftBackground.endSummaryRun()
            if (pending != null) {
                val at = pending.atMs
                if (at == null) {
                    // Switched off during the run. Cancelling this work as
                    // it ends is harmless: its result no longer matters.
                    WorkManager.getInstance(context)
                        .cancelUniqueWork(NotifyBridge.WORK_NAME)
                } else {
                    NotifyBridge.book(context, at, ExistingWorkPolicy.APPEND_OR_REPLACE)
                }
            }
        }
        return if (BackgroundLogic.shouldRetry(outcome, summary = true)) {
            Result.retry()
        } else {
            Result.success()
        }
    }
}
