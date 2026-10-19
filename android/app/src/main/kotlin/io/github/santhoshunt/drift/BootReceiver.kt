package io.github.santhoshunt.drift

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restarts NudgeService after a reboot, and after the in-app updater
 * replaces the package, which kills the running service.
 *
 * Only when the user turned live nudges on (prefs flag service_wanted). Both
 * broadcasts come from the system, which reaches a non-exported receiver,
 * so no other app can start the service through this. Android may still
 * refuse the start (ForegroundServiceStartNotAllowedException on Android
 * 12+); that is recorded for Diagnostics and the next app launch starts
 * the service instead.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        val prefs = context.getSharedPreferences(UsageBridge.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(NudgeService.KEY_WANTED, false)) return
        try {
            NudgeService.start(context)
        } catch (e: Exception) {
            // Caught as Exception: the typed class exists only from API 31.
            NudgeService.recordError(context, e)
        }
    }
}
