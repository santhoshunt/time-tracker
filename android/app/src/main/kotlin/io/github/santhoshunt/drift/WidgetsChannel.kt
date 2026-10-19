package io.github.santhoshunt.drift

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Redraws every home-screen widget from filesDir/widget_snapshot.json. */
fun interface WidgetRefresher {
    fun refreshAll(context: Context)
}

/**
 * The `drift/widgets` channel: Dart calls `refresh` after writing a new
 * widget snapshot (lib/services/widget_snapshot.dart), from the app's
 * engine and from the headless one.
 *
 * The widgets themselves live in DriftWidgets.kt. [refresher] is the seam
 * between the two: the channel and the widgets were written apart, and a
 * test or a hotfix can swap the redraw out without touching either.
 */
object WidgetsChannel {
    const val CHANNEL = "drift/widgets"

    @Volatile
    var refresher: WidgetRefresher = WidgetRefresher { DriftWidgets.refreshAll(it) }

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "refresh" -> try {
                refresher.refreshAll(context.applicationContext)
                result.success(null)
            } catch (e: Exception) {
                // A widget that fails to draw must not fail the Dart run;
                // the error reaches Dart, which logs it and carries on.
                result.error("FAILED", e.message, null)
            }
            else -> result.notImplemented()
        }
    }
}
