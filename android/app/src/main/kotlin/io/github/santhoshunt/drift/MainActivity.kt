package io.github.santhoshunt.drift

import android.content.Intent
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

class MainActivity : FlutterFragmentActivity() {
    companion object {
        /** Dart to native: the launcher icon alias. */
        private const val ICON_CHANNEL = "drift/icon"

        /** Dart to native: verify and install a downloaded update. */
        private const val UPDATE_CHANNEL = "drift/update"

        /** Dart to native: nudge permissions and the nudge service. */
        private const val NUDGE_CHANNEL = "drift/nudge"
    }

    private var usageBridge: UsageBridge? = null
    private var updateInstaller: UpdateInstaller? = null
    private var nudgeBridge: NudgeBridge? = null

    /** drift/background on this engine; registered with DriftBackground so
     * worker runs go here while the app is open. */
    private var backgroundChannel: MethodChannel? = null

    /** drift/notify on this engine; onNewIntent pushes summary taps on it. */
    private var notifyChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        usageBridge?.dispose()
        usageBridge = UsageBridge(applicationContext, this).also { bridge ->
            MethodChannel(messenger, UsageBridge.CHANNEL).setMethodCallHandler(bridge::handle)
        }

        val icons = IconSwitcher(applicationContext)
        MethodChannel(messenger, ICON_CHANNEL).setMethodCallHandler(icons::handle)

        val updateChannel = MethodChannel(messenger, UPDATE_CHANNEL)
        updateInstaller?.dispose()
        updateInstaller = UpdateInstaller(this, updateChannel).also { installer ->
            updateChannel.setMethodCallHandler(installer::handle)
        }

        nudgeBridge?.dispose()
        nudgeBridge = NudgeBridge(this).also { bridge ->
            MethodChannel(messenger, NUDGE_CHANNEL).setMethodCallHandler(bridge::handle)
        }

        backgroundChannel?.let { DriftBackground.removeLive(it) }
        backgroundChannel = MethodChannel(messenger, DriftBackground.CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "awaitIdle" -> DriftBackground.awaitIdle(result)
                    else -> result.notImplemented()
                }
            }
            DriftBackground.addLive(channel)
        }

        val notify = NotifyBridge(applicationContext, this)
        notifyChannel = MethodChannel(messenger, NotifyBridge.CHANNEL).also { channel ->
            channel.setMethodCallHandler(notify::handle)
        }

        MethodChannel(messenger, WidgetsChannel.CHANNEL).setMethodCallHandler { call, result ->
            WidgetsChannel.handle(applicationContext, call, result)
        }

        scheduleBuffer()
    }

    /** Without this a destroyed activity's channel stays registered, and
     * every worker run would wait out its timeout on a dead engine. */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        backgroundChannel?.let { DriftBackground.removeLive(it) }
        backgroundChannel = null
        notifyChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** A summary tap while Drift is open (launchMode singleTop). setIntent
     * so a later takeLaunchPayload reads this intent, not the first one. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = NotifyBridge.takePayload(intent) ?: return
        notifyChannel?.invokeMethod("launchPayload", payload)
    }

    /** super first, so Flutter plugins still get their own results. */
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        nudgeBridge?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        // Also here, in case the engine outlives this activity and
        // cleanUpFlutterEngine is not called.
        backgroundChannel?.let { DriftBackground.removeLive(it) }
        backgroundChannel = null
        usageBridge?.dispose()
        usageBridge = null
        updateInstaller?.dispose()
        updateInstaller = null
        nudgeBridge?.dispose()
        nudgeBridge = null
        super.onDestroy()
    }

    /** KEEP: every launch calls this, and replacing the work would restart
     * its 60-minute clock each time. */
    private fun scheduleBuffer() {
        val request = PeriodicWorkRequest.Builder(
            UsageBufferWorker::class.java,
            60,
            TimeUnit.MINUTES
        ).build()
        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            UsageBufferWorker.UNIQUE_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            request
        )
    }
}
