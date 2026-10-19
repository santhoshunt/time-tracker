package io.github.santhoshunt.drift

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.io.File

/**
 * Hourly copy of Android's usage events into filesDir/usage_buffer.
 *
 * Android keeps event-level history for only a few days, and Drift may stay
 * closed longer than that. Each run saves the events since the last run, at
 * most 24 hours back, as one `<fromMs>-<toMs>.jsonl` file. Dart reads the
 * files, commits the rows, then deletes them through UsageBridge.
 *
 * Scheduled from MainActivity as unique periodic work, policy KEEP, so a
 * launch never resets the schedule. WorkManager creates this class by
 * reflection; proguard-rules.pro keeps its constructor.
 *
 * Since v0.4.0 each run then runs Dart (DriftBackground): ingest, the
 * widget and nudge snapshots, and the evening summary when it is due.
 * KEEP the class name and [UNIQUE_NAME]: WorkManager stores both for work
 * already booked on installed phones, and a rename would leave that work
 * pointing at a class that no longer exists.
 */
class UsageBufferWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {
    companion object {
        const val UNIQUE_NAME = "drift_usage_buffer"
        private const val DAY_MS = 24L * 60 * 60 * 1000
    }

    /** The buffer file comes first and never depends on Dart, so a Dart
     * failure can never lose events. Always success: a failed Dart run is
     * simply redone by the next hourly run. */
    override fun doWork(): Result {
        bufferEvents(applicationContext)
        DriftBackground.run(applicationContext, summary = false)
        return Result.success()
    }

    private fun bufferEvents(context: Context) {
        val prefs = context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (!UsageBridge.hasUsageAccess(context)) {
            // Recorded so Diagnostics shows the job is alive; the cursor
            // stays put until access is granted.
            prefs.edit().putLong(UsageBridge.KEY_LAST_RUN, now).apply()
            return
        }
        removeStaleTemps(context, now)
        val cursor = prefs.getLong(UsageBridge.KEY_CURSOR, 0L)
        val from = maxOf(cursor, now - DAY_MS)
        val to = now
        val events = UsageBridge.readEvents(context, from, to)
        if (events.isNotEmpty()) {
            try {
                write(context, from, to, events)
            } catch (_: Exception) {
                // Disk full or similar: keep the cursor, so the next run
                // covers this span again.
                prefs.edit().putLong(UsageBridge.KEY_LAST_RUN, now).apply()
                return
            }
        }
        // commit, not apply: the process may end right after this returns,
        // and the Dart run that follows reads the cursor's files.
        prefs.edit()
            .putLong(UsageBridge.KEY_CURSOR, to)
            .putLong(UsageBridge.KEY_LAST_RUN, now)
            .commit()
    }

    /** A run killed mid-write leaves a .tmp file that nothing else
     * lists. Its span was never committed to the cursor, so the next run
     * covers it again and the leftover is safe to delete after an hour. */
    private fun removeStaleTemps(context: Context, now: Long) {
        val dir = UsageBridge.bufferDir(context)
        dir.listFiles { f -> f.name.endsWith(".tmp") }?.forEach { f ->
            if (now - f.lastModified() > 60L * 60 * 1000) f.delete()
        }
    }

    /** Writes to a .tmp file and renames it, so Dart never lists a file
     * that is only half written. */
    private fun write(context: Context, from: Long, to: Long, events: List<Map<String, Any?>>) {
        val dir = UsageBridge.bufferDir(context)
        if (!dir.isDirectory && !dir.mkdirs()) error("Can't create ${dir.path}")
        val name = "$from-$to.jsonl"
        val tmp = File(dir, "$name.tmp")
        tmp.bufferedWriter().use { out ->
            for (e in events) {
                out.write(
                    UsageEventMapper.bufferLine(
                        e["t"] as Long,
                        e["p"] as String,
                        e["c"] as String?,
                        e["k"] as String,
                    )
                )
                out.write("\n")
            }
        }
        if (!tmp.renameTo(File(dir, name))) {
            tmp.delete()
            error("Can't rename ${tmp.name}")
        }
    }
}
