package io.github.santhoshunt.drift

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `drift/nudge` channel (lib/platform/nudge_bridge.dart): the two
 * permissions live nudges need, and starting or stopping NudgeService.
 *
 * startService also records that the service should run, so BootReceiver
 * restarts it after a reboot or an update. The plan itself never crosses
 * this channel; Dart writes it to the snapshot file the service reads.
 */
class NudgeBridge(private val activity: Activity) {
    companion object {
        /** Below 65536: FragmentActivity rejects codes using the upper
         * 16 bits. */
        const val NOTIFICATION_REQUEST = 4207
    }

    /** The requestNotificationPermission call waiting for the dialog. */
    private var pending: MethodChannel.Result? = null

    private val prefs by lazy {
        activity.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canDrawOverlays" -> result.success(Settings.canDrawOverlays(activity))
            "openOverlaySettings" -> {
                openOverlaySettings()
                result.success(null)
            }
            "hasNotificationPermission" -> result.success(hasNotificationPermission())
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "startService" -> startService(result)
            "stopService" -> {
                prefs.edit().putBoolean(NudgeService.KEY_WANTED, false).commit()
                activity.stopService(Intent(activity, NudgeService::class.java))
                result.success(null)
            }
            "serviceStatus" -> result.success(serviceStatus())
            else -> result.notImplemented()
        }
    }

    /** From MainActivity.onRequestPermissionsResult; true when the result
     * was this bridge's. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != NOTIFICATION_REQUEST) return false
        val waiting = pending ?: return true
        pending = null
        waiting.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
        return true
    }

    /** A dialog still open when the activity goes answers as not granted,
     * so the Dart future never hangs. */
    fun dispose() {
        pending?.success(false)
        pending = null
    }

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        // Already granted, or Android 12 and below where there is no dialog;
        // a second request while one is open answers with the current state.
        if (hasNotificationPermission() || pending != null) {
            result.success(hasNotificationPermission())
            return
        }
        pending = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST
        )
    }

    /** The app's own "Display over other apps" page; the full list on ROMs
     * that lack the per-app screen. */
    private fun openOverlaySettings() {
        val own = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${activity.packageName}")
        )
        try {
            activity.startActivity(own)
        } catch (_: Exception) {
            try {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
            } catch (_: Exception) {
                // No such screen at all; the Dart side keeps showing the step.
            }
        }
    }

    /** Clears the last error first, so Diagnostics shows only failures
     * since this start. */
    private fun startService(result: MethodChannel.Result) {
        prefs.edit()
            .putBoolean(NudgeService.KEY_WANTED, true)
            .remove(NudgeService.KEY_LAST_ERROR)
            .commit()
        try {
            NudgeService.start(activity)
            result.success(null)
        } catch (e: Exception) {
            NudgeService.recordError(activity, e)
            result.error("FAILED", e.message, null)
        }
    }

    private fun serviceStatus(): Map<String, Any?> = mapOf(
        "running" to NudgeService.running,
        "lastTickMs" to
            if (prefs.contains(NudgeService.KEY_LAST_TICK)) prefs.getLong(NudgeService.KEY_LAST_TICK, 0) else null,
        "lastNudgeMs" to
            if (prefs.contains(NudgeService.KEY_LAST_NUDGE)) prefs.getLong(NudgeService.KEY_LAST_NUDGE, 0) else null,
        "lastError" to prefs.getString(NudgeService.KEY_LAST_ERROR, null),
    )
}
