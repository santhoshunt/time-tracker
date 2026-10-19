package io.github.santhoshunt.drift

import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.graphics.drawable.toBitmap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * The `drift/usage` channel: raw usage facts for Dart (UsageSource).
 *
 * Kotlin only reports what Android recorded. Sessions, idle time and
 * verdicts are worked out in Dart. Without usage access every query
 * answers empty rather than failing, so the UI can show the setup step.
 */
class UsageBridge(private val activity: Activity) {
    companion object {
        const val PREFS = "drift_native"
        const val KEY_CURSOR = "buffer_cursor_ms"
        const val KEY_LAST_RUN = "worker_last_run_ms"
        const val BUFFER_DIR = "usage_buffer"

        /** `<fromMs>-<toMs>.jsonl`, as UsageBufferWorker names them. */
        val BUFFER_FILE = Regex("^[0-9]+-[0-9]+\\.jsonl$")

        /** Export file names Dart may ask for: no folders, no tricks. */
        private val SAFE_NAME = Regex("^[A-Za-z0-9_-]+\\.csv$")

        private const val ICON_PX = 96
        private const val TEN_DAYS_MS = 10L * 24 * 60 * 60 * 1000

        /** API 36 marks unsafeCheckOpNoThrow deprecated, but it is the
         * non-deprecated call on Android 10 to 15, hence the suppression. */
        @Suppress("DEPRECATION")
        fun hasUsageAccess(context: Context): Boolean {
            val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ops.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(),
                    context.packageName
                )
            } else {
                // Android 9: the same check under its older name.
                ops.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(),
                    context.packageName
                )
            }
            return mode == AppOpsManager.MODE_ALLOWED
        }

        /** Events Drift keeps between [fromMs] and [toMs], oldest first, in
         * the {t, p, c, k} shape. Empty without usage access. */
        fun readEvents(context: Context, fromMs: Long, toMs: Long): List<Map<String, Any?>> {
            if (toMs <= fromMs || !hasUsageAccess(context)) return emptyList()
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val events = try {
                usm.queryEvents(fromMs, toMs)
            } catch (_: SecurityException) {
                // Access revoked between the check and the query.
                return emptyList()
            } ?: return emptyList()
            val out = ArrayList<Map<String, Any?>>()
            // One Event reused for every read, as the API intends.
            val e = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(e)
                val kind = UsageEventMapper.kindOf(e.eventType) ?: continue
                out.add(
                    mapOf(
                        "t" to e.timeStamp,
                        "p" to e.packageName,
                        "c" to e.className,
                        "k" to kind,
                    )
                )
            }
            return out
        }

        fun bufferDir(context: Context): File = File(context.filesDir, BUFFER_DIR)

        @Suppress("DEPRECATION")
        fun resolve(context: Context, intent: Intent): List<ResolveInfo> {
            val pm = context.packageManager
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
            } else {
                pm.queryIntentActivities(intent, 0)
            }
        }

        /** Launchers: time spent in them counts as idle, and NudgeService
         * never nudges about them. The Settings app's FallbackHome also
         * answers HOME, at a negative priority, so it is left out;
         * otherwise all Settings time would read as idle. */
        fun homePackages(context: Context): List<String> {
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            return resolve(context, home)
                .filter { it.priority >= 0 }
                .mapNotNull { it.activityInfo?.packageName }
                .distinct()
        }
    }

    /** Event, app and icon queries can take hundreds of milliseconds and
     * must not block the UI thread. One thread keeps them in order. */
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasUsageAccess" -> result.success(hasUsageAccess(activity))
            "openUsageAccessSettings" -> {
                open(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBatteryOptimizations()
                result.success(null)
            }
            "queryEvents" -> {
                // A small Dart int arrives as Integer, a large one as Long.
                val from = call.argument<Number>("fromMs")?.toLong()
                val to = call.argument<Number>("toMs")?.toLong()
                if (from == null || to == null) {
                    result.error("BAD_ARGS", "fromMs and toMs are required.", null)
                } else {
                    background(result) { readEvents(activity, from, to) }
                }
            }
            "earliestEventMs" -> background(result) { earliestEventMs() }
            "listApps" -> background(result) { listApps() }
            "appIcon" -> {
                val p = call.argument<String>("p")
                background(result) { p?.let(::appIcon) }
            }
            "homePackages" -> background(result) { homePackages(activity) }
            "drainBuffer" -> background(result) { drainBuffer() }
            "deleteBuffer" -> {
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                background(result) {
                    deleteBuffer(paths)
                    null
                }
            }
            "diagnostics" -> background(result) { diagnostics() }
            "saveCsv" -> {
                val name = call.argument<String>("name")
                val text = call.argument<String>("text")
                if (name == null || text == null || !SAFE_NAME.matches(name)) {
                    result.error("BAD_ARGS", "A plain .csv file name and text are required.", null)
                } else {
                    background(result) { saveCsv(name, text) }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        worker.shutdown()
    }

    /** Runs [work] off the UI thread and replies on it. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            val outcome: Result<Any?> = try {
                Result.success(work())
            } catch (e: Exception) {
                Result.failure(e)
            }
            main.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("FAILED", it.message, null) }
                )
            }
        }
    }

    /** Writes an export where the user can find it and returns where that
     * is, in words. Android 10 and later: Downloads/Drift through
     * MediaStore, which needs no storage permission. Android 9: Drift's own
     * documents folder, which needs none either. */
    private fun saveCsv(name: String, text: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "text/csv")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Drift")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = activity.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("Android did not create the file")
            try {
                resolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
                    ?: error("Android did not open the file")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return "Downloads/Drift/$name"
        }
        val dir = activity.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS)
            ?: activity.filesDir
        val file = File(dir, name)
        file.writeText(text)
        return file.path
    }

    /** Some ROMs lack these settings screens; a bare startActivity would
     * throw and the tap would do nothing visible. */
    private fun open(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(activity.packageName)
    }

    /** The system's one-tap exemption dialog; the full list as a fallback. */
    private fun requestIgnoreBatteryOptimizations() {
        val asked = open(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${activity.packageName}")
            )
        )
        if (!asked) open(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    /** The oldest event Android still holds in the last 10 days, of any
     * type, or null. Only the first event is read. */
    private fun earliestEventMs(): Long? {
        if (!hasUsageAccess(activity)) return null
        val now = System.currentTimeMillis()
        val usm = activity.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = try {
            usm.queryEvents(now - TEN_DAYS_MS, now)
        } catch (_: SecurityException) {
            return null
        } ?: return null
        if (!events.hasNextEvent()) return null
        val e = UsageEvents.Event()
        events.getNextEvent(e)
        return e.timeStamp
    }

    /** One entry per package with a launcher activity. Needs the
     * MAIN/LAUNCHER <queries> entry on Android 11 and later. */
    private fun listApps(): List<Map<String, Any?>> {
        val pm = activity.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any?>>()
        for (info in resolve(activity, launcher)) {
            val app = info.activityInfo?.applicationInfo ?: continue
            if (!seen.add(app.packageName)) continue
            out.add(
                mapOf(
                    "p" to app.packageName,
                    "label" to app.loadLabel(pm).toString(),
                    "category" to UsageEventMapper.categoryName(app.category),
                )
            )
        }
        return out
    }

    /** The app's icon drawn at 96 px as PNG bytes, or null if the package is
     * gone. toBitmap also draws adaptive icons, which have no bitmap. */
    private fun appIcon(p: String): ByteArray? {
        val drawable = try {
            activity.packageManager.getApplicationIcon(p)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        val bitmap = drawable.toBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
        val bytes = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)
        return bytes.toByteArray()
    }

    /** Finished buffer files, oldest first. A file the worker is still
     * writing ends in .tmp and is not listed. */
    private fun drainBuffer(): List<String> {
        val files = bufferDir(activity).listFiles() ?: return emptyList()
        return files
            .filter { it.isFile && BUFFER_FILE.matches(it.name) }
            .sortedBy { it.name.substringBefore('-').toLongOrNull() ?: Long.MAX_VALUE }
            .map { it.absolutePath }
    }

    /** Deletes only buffer files directly inside filesDir/usage_buffer, the
     * same canonical-path check UpdateInstaller.resolve makes. Anything else
     * Dart passes is ignored. */
    private fun deleteBuffer(paths: List<String>) {
        val dir = bufferDir(activity).canonicalFile
        for (path in paths) {
            val file = File(path).canonicalFile
            if (file.parentFile != dir || !BUFFER_FILE.matches(file.name) || !file.isFile) {
                continue
            }
            file.delete()
        }
    }

    private fun diagnostics(): Map<String, Any?> {
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val count = bufferDir(activity).listFiles()
            ?.count { it.isFile && BUFFER_FILE.matches(it.name) } ?: 0
        return mapOf(
            "workerLastRunMs" to
                if (prefs.contains(KEY_LAST_RUN)) prefs.getLong(KEY_LAST_RUN, 0) else null,
            "bufferFiles" to count,
            "bufferCursorMs" to
                if (prefs.contains(KEY_CURSOR)) prefs.getLong(KEY_CURSOR, 0) else null,
        )
    }
}
