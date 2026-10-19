package io.github.santhoshunt.drift

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `drift/icon` channel: switches the launcher icon by enabling one
 * <activity-alias> and disabling the rest.
 *
 * Every alias targets .MainActivity, which has no launcher entry of its own,
 * so MainActivity's state is never touched. Alias names are frozen: removing
 * one in a later release would strand a launcher entry that points at it.
 */
class IconSwitcher(private val context: Context) {
    companion object {
        /** The alias enabled in the manifest. */
        const val DEFAULT = "IconMeltingClock"

        val ALIASES = listOf(
            DEFAULT,
            "IconTimeRiver",
            "IconSlidingDay",
            "IconNeedle",
            "IconWanderer",
            "IconEscape",
        )
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> result.success(current())
            "set" -> {
                val name = call.argument<String>("name")
                if (name == null || name !in ALIASES) {
                    result.error("UNKNOWN_ICON", "No launcher icon named $name.", null)
                } else {
                    set(name)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun component(name: String) =
        ComponentName(context.packageName, "${context.packageName}.$name")

    /** The first enabled alias. An alias never switched reports DEFAULT,
     * which means the manifest value: enabled only for [DEFAULT]. */
    private fun current(): String {
        val pm = context.packageManager
        for (name in ALIASES) {
            val state = pm.getComponentEnabledSetting(component(name))
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
                (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && name == DEFAULT)
            ) {
                return name
            }
        }
        return DEFAULT
    }

    /** Enables the chosen alias first, then disables the rest, so a launcher
     * entry exists at every point in between. DONT_KILL_APP keeps the running
     * process alive; launchers may take a moment to redraw. */
    private fun set(name: String) {
        val pm = context.packageManager
        pm.setComponentEnabledSetting(
            component(name),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        for (other in ALIASES) {
            if (other == name) continue
            pm.setComponentEnabledSetting(
                component(other),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
        }
    }
}
