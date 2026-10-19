package io.github.santhoshunt.drift

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Background Dart runs: ingest, the widget and nudge snapshots, and the
 * evening summary while Drift is closed (lib/background.dart).
 *
 * Two Dart isolates must never write the database at once. So a run goes
 * to the app's own engine when it is alive ([addLive], channel
 * `drift/background`, method `runBackground`) and starts a headless engine
 * only when it is not. BootApp calls `awaitIdle` before opening the
 * database, so an app opened mid-run waits for the headless engine to
 * finish, at most a minute.
 *
 * Every field except [gate] is touched on the main thread only.
 */
object DriftBackground {
    const val CHANNEL = "drift/background"

    /** The entry point lives outside main.dart, so the engine is told
     * which library holds it; lib/app.dart imports that library, which
     * keeps it in the release build. */
    private const val ENTRY_LIBRARY = "package:drift_time/background.dart"
    private const val ENTRY_FUNCTION = "backgroundMain"

    /** Diagnostics: when the last run ended and whether it went well. */
    const val KEY_LAST_RUN = "dart_last_run_ms"
    const val KEY_LAST_OK = "dart_last_ok"

    /** Why the last headless engine failed to start, if it did. */
    const val KEY_LAST_ERROR = "dart_last_error"

    /** A run not finished by then is stopped; the next run starts over,
     * and every step is safe to repeat. */
    private const val RUN_TIMEOUT_SECONDS = 120L

    /** An app kept waiting on a stuck headless run opens anyway. */
    private const val IDLE_WAIT_MILLIS = 60_000L

    private val main = Handler(Looper.getMainLooper())

    /** Background channels of the app's live engines, newest last. Usually
     * one; a second MainActivity can briefly add another. */
    private val liveChannels = mutableListOf<MethodChannel>()

    /** The engine of the headless run in progress, if any. */
    private var headless: FlutterEngine? = null
    private var headlessCleanup: (() -> Unit)? = null
    private val idleWaiters = mutableListOf<MethodChannel.Result>()

    private val gate = SummaryBookingGate()

    fun addLive(channel: MethodChannel) {
        liveChannels.remove(channel)
        liveChannels += channel
    }

    fun removeLive(channel: MethodChannel) {
        liveChannels.remove(channel)
    }

    /** SummaryWorker brackets its run with these, so the run's own rebooking
     * does not cancel it (see SummaryBookingGate). */
    fun beginSummaryRun() = gate.begin()
    fun endSummaryRun(): SummaryBookingGate.Pending? = gate.end()
    fun deferBooking(atMs: Long?): Boolean = gate.defer(atMs)

    /** Answers once no headless engine holds the database, or after a
     * minute, when the stuck run is stopped rather than left writing beside
     * the app. Its work is redone by the next run. */
    fun awaitIdle(result: MethodChannel.Result) {
        if (headless == null) {
            result.success(null)
            return
        }
        idleWaiters += result
        main.postDelayed({
            if (result in idleWaiters) headless?.let { stopHeadless(it) }
        }, IDLE_WAIT_MILLIS)
    }

    /**
     * One Dart run, from a worker thread. Blocks until Dart reports back
     * or [RUN_TIMEOUT_SECONDS] pass. [summary] is passed to Dart as a hint;
     * whether a summary is due is Dart's decision, so a late hourly run can
     * also post one the summary run missed.
     */
    fun run(context: Context, summary: Boolean): RunOutcome {
        val app = context.applicationContext
        val latch = CountDownLatch(1)
        val outcome = AtomicReference(RunOutcome.FAILED)
        val reported = AtomicBoolean(false)
        val engine = AtomicReference<FlutterEngine?>(null)
        val done = { o: RunOutcome ->
            if (reported.compareAndSet(false, true)) {
                outcome.set(o)
                latch.countDown()
            }
        }
        main.post {
            try {
                engine.set(start(app, summary, done))
            } catch (e: Exception) {
                app.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE).edit()
                    .putString(KEY_LAST_ERROR, "${e.javaClass.simpleName}: ${e.message}")
                    .commit()
                done(RunOutcome.FAILED)
            }
        }
        if (!latch.await(RUN_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            done(RunOutcome.FAILED)
            main.post { engine.get()?.let { stopHeadless(it) } }
        }
        val result = outcome.get()
        if (result != RunOutcome.BUSY) {
            app.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE).edit()
                .putLong(KEY_LAST_RUN, System.currentTimeMillis())
                .putBoolean(KEY_LAST_OK, result == RunOutcome.OK)
                .commit()
        }
        return result
    }

    /** On the main thread. Returns the headless engine it started, if any. */
    private fun start(context: Context, summary: Boolean, done: (RunOutcome) -> Unit): FlutterEngine? {
        val live = liveChannels.lastOrNull()
        if (live != null) {
            live.invokeMethod(
                "runBackground",
                mapOf("summary" to summary),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = done(BackgroundLogic.liveOutcome(result))

                    override fun error(code: String, message: String?, details: Any?) =
                        done(RunOutcome.FAILED)

                    // The engine is up but Dart has not called listenForRuns
                    // yet: BootApp is still starting.
                    override fun notImplemented() = done(RunOutcome.BUSY)
                }
            )
            return null
        }
        // Another headless run is still going and holds the database.
        if (headless != null) {
            done(RunOutcome.BUSY)
            return null
        }

        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        // Registers every Flutter plugin (sqflite, path_provider,
        // shared_preferences) on this engine, as on the app's.
        val engine = FlutterEngine(context)
        headless = engine
        try {
            registerHeadlessChannels(engine, context, done)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRY_LIBRARY, ENTRY_FUNCTION)
            )
            return engine
        } catch (e: Exception) {
            // Never leave the process marked busy with a dead engine.
            stopHeadless(engine)
            throw e
        }
    }

    /** The channels lib/background.dart uses, without an Activity. */
    private fun registerHeadlessChannels(
        engine: FlutterEngine,
        context: Context,
        done: (RunOutcome) -> Unit,
    ) {
        val messenger = engine.dartExecutor.binaryMessenger
        val usage = UsageBridge(context)
        headlessCleanup = { usage.dispose() }
        MethodChannel(messenger, UsageBridge.CHANNEL).setMethodCallHandler(usage::handle)

        val notify = NotifyBridge(context)
        MethodChannel(messenger, NotifyBridge.CHANNEL).setMethodCallHandler(notify::handle)

        MethodChannel(messenger, WidgetsChannel.CHANNEL).setMethodCallHandler { call, result ->
            WidgetsChannel.handle(context, call, result)
        }

        // Status only: Android 12+ refuses a foreground-service start from
        // the background, and stopping it here would undo the user's
        // choice. The app's engine starts and stops the service.
        MethodChannel(messenger, "drift/nudge").setMethodCallHandler { call, result ->
            when (call.method) {
                "serviceStatus" -> result.success(nudgeStatus(context))
                "hasNotificationPermission" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                        PackageManager.PERMISSION_GRANTED
                )
                "canDrawOverlays" -> result.success(Settings.canDrawOverlays(context))
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "awaitIdle" -> result.success(null)
                "finished" -> {
                    val ok = call.argument<Boolean>("ok") ?: false
                    result.success(null)
                    // After the reply is sent: destroying the engine inside
                    // its own call would drop the answer.
                    main.post {
                        stopHeadless(engine)
                        done(if (ok) RunOutcome.OK else RunOutcome.FAILED)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The same map NudgeBridge.serviceStatus answers in the app. */
    private fun nudgeStatus(context: Context): Map<String, Any?> {
        val prefs = context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
        return mapOf(
            "running" to NudgeService.running,
            "lastTickMs" to
                if (prefs.contains(NudgeService.KEY_LAST_TICK)) prefs.getLong(NudgeService.KEY_LAST_TICK, 0) else null,
            "lastNudgeMs" to
                if (prefs.contains(NudgeService.KEY_LAST_NUDGE)) prefs.getLong(NudgeService.KEY_LAST_NUDGE, 0) else null,
            "lastError" to prefs.getString(NudgeService.KEY_LAST_ERROR, null),
        )
    }

    /** Destroys [engine] if it is still the running one, frees the usage
     * bridge's thread, and releases every app waiting to open. */
    private fun stopHeadless(engine: FlutterEngine) {
        if (headless !== engine) return
        headless = null
        headlessCleanup?.invoke()
        headlessCleanup = null
        try {
            engine.destroy()
        } catch (_: Exception) {
            // Already torn down.
        }
        val waiting = idleWaiters.toList()
        idleWaiters.clear()
        for (w in waiting) w.success(null)
    }
}
