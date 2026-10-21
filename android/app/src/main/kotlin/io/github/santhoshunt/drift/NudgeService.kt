package io.github.santhoshunt.drift

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import java.util.concurrent.ConcurrentHashMap

/**
 * The live-nudge service: once a minute, works out which app is in front
 * and for how long, and asks NudgeDecider whether that earns a nudge.
 *
 * All plan logic stays in Dart, which writes filesDir/nudge_snapshot.json;
 * this only reads it. A foreground service, type specialUse, because
 * Android stops background work within minutes and a nudge that arrives an
 * hour late is useless. The tick runs on its own thread with a Handler, so
 * it pauses while the device sleeps, when there is nothing to nudge about.
 *
 * Restarted after a reboot or an app update by BootReceiver when the prefs
 * flag service_wanted is set (NudgeBridge sets and clears it).
 */
class NudgeService : Service() {
    companion object {
        const val SNAPSHOT_FILE = "nudge_snapshot.json"
        const val SERVICE_CHANNEL = "drift_service"
        const val NUDGE_CHANNEL = "drift_nudges"
        const val KEY_WANTED = "service_wanted"
        const val KEY_LAST_TICK = "service_last_tick_ms"
        const val KEY_LAST_NUDGE = "nudge_last_ms"
        const val KEY_LAST_ERROR = "service_last_error"
        const val NUDGE_NOTIFICATION_ID = 1802
        /** The foreground notification: the usage numbers while "Today in
         * notifications" is on, "Drift is watching your plan" otherwise. */
        private const val SERVICE_NOTIFICATION_ID = 1801

        /** How often the Today usage numbers are counted again. */
        private const val COUNT_EVERY_MS = 60_000L

        /** How long the list of launchable apps is reused. */
        private const val LAUNCHABLE_REFRESH_MS = 30L * 60 * 1000
        private const val TICK_MS = 60_000L

        /** With focus lock on, an app has to be caught within seconds of
         * opening, not a minute later. */
        private const val LOCK_TICK_MS = 10_000L
        private const val LOOKBACK_MS = 3L * 60 * 60 * 1000
        private const val SNOOZE_MS = 5L * 60 * 1000
        private const val SYSTEM_UI = "com.android.systemui"

        /** True between onCreate and onDestroy; serviceStatus reports it. */
        @Volatile
        var running = false
            private set

        /** Package to the end of its "5 more minutes". In memory only, so
         * a restarted service forgets snoozes, which errs towards nudging. */
        private val snoozes = ConcurrentHashMap<String, Long>()

        /** Packages whose next nudge waits only for their snooze. Without
         * this the repeat limit (15 minutes by default) would hold back the
         * nudge long after "5 more minutes" ran out. Cleared when the next
         * nudge for that package fires. */
        private val snoozeEnds = ConcurrentHashMap<String, Long>()

        fun snooze(pkg: String, nowMs: Long) {
            snoozes[pkg] = nowMs + SNOOZE_MS
            snoozeEnds[pkg] = nowMs + SNOOZE_MS
        }

        /** Throws when Android refuses the start, for example
         * ForegroundServiceStartNotAllowedException from the background on
         * Android 12+. Callers record it with [recordError]. */
        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, NudgeService::class.java))
        }

        /** The last failure, shown in Diagnostics through serviceStatus.
         * The class name says which exception it was, since the typed
         * classes do not exist on every supported Android version. commit,
         * not apply: a boot receiver's process may end right after. */
        fun recordError(context: Context, e: Throwable) {
            recordError(context, "${e.javaClass.simpleName}: ${e.message}")
        }

        fun recordError(context: Context, message: String) {
            context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_LAST_ERROR, message)
                .commit()
        }

        fun homeIntent(): Intent = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_HOME)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var thread: HandlerThread
    private lateinit var ticker: Handler
    private var ticking = false

    // Touched only on the tick thread.
    private var lastNudgeMs: Long? = null
    private var notifiedPkg: String? = null
    private var snapshotStamp: Pair<Long, Long>? = null
    private var snapshot: NudgeSnapshot? = null

    /** The last usage notification posted, so a restart (Dart starts the
     * service again on every sync) keeps showing the numbers instead of
     * "Drift is watching your plan" until the next count. Written on the
     * tick thread, read on the main thread. */
    @Volatile
    private var lastUsage: android.app.Notification? = null

    // The Today notifications, also tick-thread only.
    private var lastCountMs = 0L
    private var shownUsage = false
    private var shownBlock: TodayStatus.Line? = null
    private var scheduledFor: NudgeSnapshot? = null
    private var launchable: Set<String> = emptySet()
    private var launchableAtMs = 0L
    private val categories = HashMap<String, String>()
    private val labels = HashMap<String, String>()

    private val tick = object : Runnable {
        override fun run() {
            try {
                tickOnce()
            } catch (e: Exception) {
                recordError(this@NudgeService, e)
            }
            // Separate, so a nudge failure never stops the Today
            // notifications, or the other way round.
            try {
                todayTick(System.currentTimeMillis())
            } catch (e: Exception) {
                recordError(this@NudgeService, e)
            }
            val snap = snapshot
            ticker.postDelayed(this, if (snap != null && snap.enabled && snap.lock) LOCK_TICK_MS else TICK_MS)
        }
    }

    private val prefs by lazy { getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannels()
        if (prefs.contains(KEY_LAST_NUDGE)) lastNudgeMs = prefs.getLong(KEY_LAST_NUDGE, 0)
        thread = HandlerThread("drift-nudge").also { it.start() }
        ticker = Handler(thread.looper)
    }

    /** startForeground runs on every start, not only the first: each
     * startForegroundService call must be answered with it. A sticky
     * restart from the background can be refused on Android 12+; the
     * service then records why and stops until the next app launch. */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            }
            ServiceCompat.startForeground(this, SERVICE_NOTIFICATION_ID, lastUsage ?: serviceNotification(), type)
        } catch (e: Exception) {
            recordError(this, e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (!ticking) {
            ticking = true
            ticker.post(tick)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        ticker.removeCallbacksAndMessages(null)
        thread.quitSafely()
        main.post { NudgeOverlay.dismiss() }
        getSystemService(NotificationManager::class.java)?.cancel(NUDGE_NOTIFICATION_ID)
        // The reminder alarm stays booked: heads-ups still come while the
        // service is stopped.
        TodayNotifications.cancelBlock(this)
        super.onDestroy()
    }

    /**
     * The Today notifications: the block line every tick (re-posted only
     * when its words change), the usage numbers at most once a minute, any
     * reminder an alarm missed, and a new alarm whenever Dart rewrote the
     * snapshot.
     */
    private fun todayTick(now: Long) {
        val snap = readSnapshot()
        if (snap !== scheduledFor) {
            scheduledFor = snap
            TodayNotifications.scheduleNext(this, snap, now)
        }
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (snap == null || !snap.status || !TodayNotifications.canPost(this)) {
            if (shownBlock != null) TodayNotifications.cancelBlock(this)
            shownBlock = null
            if (shownUsage) {
                nm.notify(SERVICE_NOTIFICATION_ID, serviceNotification())
                shownUsage = false
            }
            lastUsage = null
        } else {
            TodayNotifications.createChannels(this)
            val line = TodayNotifications.blockLine(snap, now)
            if (line != shownBlock) {
                TodayNotifications.postBlock(this, line)
                shownBlock = line
            }
            if (!shownUsage || now - lastCountMs >= COUNT_EVERY_MS) {
                val counted = countToday(now, snap)
                val usage = TodayNotifications.usage(this, counted, ::label, snap.colors)
                nm.notify(SERVICE_NOTIFICATION_ID, usage)
                lastUsage = usage
                lastCountMs = now
                shownUsage = true
            }
        }
        if (snap != null) TodayNotifications.postDueReminder(this, snap, now)
    }

    /**
     * Today's app time from usage events, counted as the Usage tab counts
     * (DayUsage, held to the Dart copy by usage_count_cases.json). Events are
     * read from 3 hours before midnight, so an app already open at midnight
     * is seen, and only time from midnight counts.
     */
    private fun countToday(now: Long, snap: NudgeSnapshot): DayUsage.Counted {
        if (!UsageBridge.hasUsageAccess(this)) return DayUsage.Counted(0, 0)
        val zone = java.time.ZoneId.systemDefault()
        val dayStart = java.time.Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
            .atStartOfDay(zone).toInstant().toEpochMilli()
        val events = UsageBridge.readEvents(this, dayStart - LOOKBACK_MS, now).map {
            ForegroundRun.Event(
                t = it["t"] as Long,
                pkg = it["p"] as String,
                cls = it["c"] as String?,
                kind = it["k"] as String,
            )
        }
        if (launchable.isEmpty() || now - launchableAtMs > LAUNCHABLE_REFRESH_MS) {
            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            launchable = UsageBridge.resolve(this, launcher)
                .mapNotNull { it.activityInfo?.packageName }
                .toSet()
            launchableAtMs = now
        }
        val idle = HashSet<String>(UsageBridge.homePackages(this))
        idle.add(packageName)
        idle.add(SYSTEM_UI)
        return DayUsage.count(
            events = events,
            dayStartMs = dayStart,
            nowMs = now,
            idle = idle,
            launchable = launchable,
            categoryOf = { p ->
                categories.getOrPut(p) {
                    UsageEventMapper.categoryName(appInfo(p)?.category ?: ApplicationInfo.CATEGORY_UNDEFINED)
                }
            },
            offApps = snap.offApps,
            onApps = snap.onApps,
            guessOff = snap.guessOffCategories,
        )
    }

    private fun tickOnce() {
        val now = System.currentTimeMillis()
        // Recorded even without usage access, so Diagnostics shows the
        // service is alive.
        prefs.edit().putLong(KEY_LAST_TICK, now).apply()
        snoozes.entries.removeIf { it.value <= now }
        if (!UsageBridge.hasUsageAccess(this)) return
        val snap = readSnapshot()
        val run = frontRun(now)
        clearStaleNudge(run?.pkg)
        if (snap == null || run == null) return

        val info = appInfo(run.pkg)
        val category = UsageEventMapper.categoryName(info?.category ?: ApplicationInfo.CATEGORY_UNDEFINED)
        val cal = Calendar.getInstance().apply { timeInMillis = now }
        val nowLocalMin = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        val snoozeEnd = snoozeEnds[run.pkg]
        val decision = NudgeDecider.decide(
            snap,
            now,
            nowLocalMin,
            run.pkg,
            category,
            now - run.startMs,
            if (snoozeEnd != null && now >= snoozeEnd) null else lastNudgeMs,
            snoozes[run.pkg],
        )
        if (decision !is NudgeDecision.Nudge) return
        // A lock fires on every tick while the app stays in front; one card
        // or one notification is enough, so neither is redrawn or reposted,
        // and the 10-second ticks leave prefs alone.
        if (decision.lock && (NudgeOverlay.showingFor == run.pkg || notifiedPkg == run.pkg)) return

        snoozeEnds.remove(run.pkg)
        if (!decision.lock) {
            lastNudgeMs = now
            prefs.edit().putLong(KEY_LAST_NUDGE, now).apply()
        }
        val label = info?.loadLabel(packageManager)?.toString() ?: run.pkg
        if (Settings.canDrawOverlays(this)) {
            val colors = snap.colors
            // Outside the tick's try: an exception on the main thread would
            // end the whole process. The permission can be revoked between
            // the check and addView, so fall back to the notification.
            main.post {
                try {
                    NudgeOverlay.show(this, run.pkg, label, decision, colors) { pkg ->
                        snooze(pkg, System.currentTimeMillis())
                    }
                } catch (e: Exception) {
                    recordError(this, e)
                    ticker.post {
                        try {
                            postNudgeNotification(run.pkg, label, decision)
                        } catch (e2: Exception) {
                            recordError(this, e2)
                        }
                    }
                }
            }
        } else {
            postNudgeNotification(run.pkg, label, decision)
        }
    }

    /** The snapshot, parsed again only when the file changes. Size is
     * compared as well as the time, since some file systems keep whole
     * seconds and Dart can write twice in one. A file that does not parse
     * gives null, so the service does nothing until Dart rewrites it. */
    private fun readSnapshot(): NudgeSnapshot? {
        val file = File(filesDir, SNAPSHOT_FILE)
        if (!file.isFile) {
            snapshotStamp = null
            snapshot = null
            return null
        }
        val stamp = file.lastModified() to file.length()
        if (stamp != snapshotStamp) {
            snapshotStamp = stamp
            snapshot = try {
                NudgeSnapshot.parse(JSONObject(file.readText()))
            } catch (e: Exception) {
                recordError(this, e)
                null
            }
        }
        return snapshot
    }

    /** The app in front from the last 3 hours of usage events, ignoring
     * Drift, System UI and launchers (see ForegroundRun.find). */
    private fun frontRun(now: Long): ForegroundRun.Run? {
        val events = UsageBridge.readEvents(this, now - LOOKBACK_MS, now).map {
            ForegroundRun.Event(
                t = it["t"] as Long,
                pkg = it["p"] as String,
                cls = it["c"] as String?,
                kind = it["k"] as String,
            )
        }
        val ignored = HashSet<String>(UsageBridge.homePackages(this))
        ignored.add(packageName)
        ignored.add(SYSTEM_UI)
        return ForegroundRun.find(events, ignored)
    }

    /** Takes a nudge down once its app is no longer in front, for example
     * after a home gesture, which leaves an overlay showing. */
    private fun clearStaleNudge(front: String?) {
        val overlayPkg = NudgeOverlay.showingFor
        if (overlayPkg != null && overlayPkg != front) {
            main.post { if (NudgeOverlay.showingFor == overlayPkg) NudgeOverlay.dismiss() }
        }
        if (notifiedPkg != null && notifiedPkg != front) {
            getSystemService(NotificationManager::class.java)?.cancel(NUDGE_NOTIFICATION_ID)
            notifiedPkg = null
        }
    }

    /** Null when the package is gone or hidden by package visibility. */
    @Suppress("DEPRECATION")
    private fun appInfo(pkg: String): ApplicationInfo? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
        } else {
            packageManager.getApplicationInfo(pkg, 0)
        }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    /** The app's name as the launcher shows it, or the package name when
     * the app is gone. Tick-thread only, like [categories]. */
    private fun label(pkg: String): String =
        labels.getOrPut(pkg) { appInfo(pkg)?.loadLabel(packageManager)?.toString() ?: pkg }

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(SERVICE_CHANNEL, "Background service", NotificationManager.IMPORTANCE_MIN)
                .apply { setShowBadge(false) }
        )
        nm.createNotificationChannel(
            NotificationChannel(NUDGE_CHANNEL, "Nudges", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )

    private fun serviceNotification() =
        NotificationCompat.Builder(this, SERVICE_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_drift)
            .setContentTitle("Drift is watching your plan")
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    /**
     * The fallback when "Display over other apps" is off. "Go to home
     * screen" opens HOME straight from the notification: since Android 12 a
     * receiver started by a notification tap may not start an activity.
     * "5 more minutes" goes through NudgeActionReceiver.
     */
    private fun postNudgeNotification(pkg: String, label: String, nudge: NudgeDecision.Nudge) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            recordError(this, "No overlay or notification permission, so a nudge was not shown.")
            return
        }
        val home = PendingIntent.getActivity(
            this,
            1,
            homeIntent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val snooze = PendingIntent.getBroadcast(
            this,
            2,
            Intent(this, NudgeActionReceiver::class.java)
                .setAction(NudgeActionReceiver.ACTION_SNOOZE)
                .putExtra(NudgeActionReceiver.EXTRA_PKG, pkg),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(this, NUDGE_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_drift)
            .setContentTitle(if (nudge.lock) "Locked: ${nudge.block}" else "Off track: ${nudge.block}")
            .setOnlyAlertOnce(true)
            .setContentText(NudgeOverlay.body(label, nudge))
            .setStyle(NotificationCompat.BigTextStyle().bigText(NudgeOverlay.body(label, nudge)))
            .setContentIntent(openAppIntent())
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .addAction(0, "Go to home screen", home)
            .addAction(0, "5 more minutes", snooze)
            .build()
        getSystemService(NotificationManager::class.java)?.notify(NUDGE_NOTIFICATION_ID, notification)
        notifiedPkg = pkg
    }
}

/**
 * The nudge notification's "5 more minutes" button. Not exported and
 * reached only through the explicit PendingIntent NudgeService builds, so
 * no other app can snooze a package.
 */
class NudgeActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_SNOOZE = "io.github.santhoshunt.drift.NUDGE_SNOOZE"
        const val EXTRA_PKG = "pkg"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SNOOZE) return
        val pkg = intent.getStringExtra(EXTRA_PKG) ?: return
        NudgeService.snooze(pkg, System.currentTimeMillis())
        context.getSystemService(NotificationManager::class.java)
            ?.cancel(NudgeService.NUDGE_NOTIFICATION_ID)
    }
}
