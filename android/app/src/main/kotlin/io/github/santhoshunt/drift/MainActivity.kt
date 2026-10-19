package io.github.santhoshunt.drift

import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

class MainActivity : FlutterFragmentActivity() {
    companion object {
        /** Dart to native: usage events, apps, icons and the buffer. */
        private const val USAGE_CHANNEL = "drift/usage"

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        usageBridge?.dispose()
        usageBridge = UsageBridge(this).also { bridge ->
            MethodChannel(messenger, USAGE_CHANNEL).setMethodCallHandler(bridge::handle)
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

        scheduleBuffer()
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
