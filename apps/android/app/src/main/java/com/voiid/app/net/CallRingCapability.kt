package com.voiid.app.net

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether this device can actually RING for an incoming call — and, when it can't, which
 * settings screen fixes it.
 *
 * Three OS states silently turn a call into nothing at all, each leaving no trace anywhere:
 *
 *  - **POST_NOTIFICATIONS denied** (Android 13+). `notify()` becomes a no-op, so there is no
 *    ring *and* no full-screen intent. The message path has always checked this; the call path
 *    did not, which is why calls could simply never arrive with nothing to look at.
 *  - **USE_FULL_SCREEN_INTENT revoked** (Android 14+, where it became user-revocable). The
 *    lockscreen takeover degrades to a heads-up notification, which an idle screen never shows.
 *  - **Battery optimization**. Aggressive OEM power managers stop the FCM process start
 *    outright, so the ring push is never delivered in the first place.
 *
 * Detection only — nothing here changes call behaviour. [state] is what the UI reads to explain
 * the degradation, and [fixIntent] is the screen that repairs it. Battery optimization is
 * reported but deliberately does NOT raise the banner: it is on by default for most users and
 * most of them still receive calls fine, so nagging about it would train people to ignore the
 * banner that matters.
 */
object CallRingCapability {

    data class State(
        /** Calls cannot ring at all: notifications are blocked. */
        val notificationsBlocked: Boolean = false,
        /** Calls ring, but never take over the lockscreen. */
        val fullScreenIntentBlocked: Boolean = false,
        /** The OEM may kill us before the ring push is delivered. */
        val batteryOptimized: Boolean = false,
    ) {
        /** Something the user should be told about and can fix. */
        val degraded: Boolean get() = notificationsBlocked || fullScreenIntentBlocked
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    /** Cheap; safe to call on every app foreground and before every ring. */
    fun refresh(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        val notifications = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        val fsi = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            nm != null && !runCatching { nm.canUseFullScreenIntent() }.getOrDefault(true)
        val battery = runCatching {
            val pm = context.getSystemService(PowerManager::class.java)
            pm != null && !pm.isIgnoringBatteryOptimizations(context.packageName)
        }.getOrDefault(false)
        val next = State(
            notificationsBlocked = notifications,
            fullScreenIntentBlocked = fsi,
            batteryOptimized = battery,
        )
        if (next != _state.value) {
            _state.value = next
            if (next.degraded) {
                android.util.Log.w(
                    "VOIID",
                    "call ring degraded — notifications=${!notifications} fullScreenIntent=${!fsi}",
                )
            }
        }
    }

    /**
     * The settings screen that fixes the most severe current problem, or null when nothing is
     * wrong. Blocked notifications win: without them there is no ring to make full-screen.
     */
    fun fixIntent(context: Context): Intent? {
        val s = _state.value
        return when {
            s.notificationsBlocked -> appNotificationSettings(context)
            s.fullScreenIntentBlocked && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, packageUri(context))
            else -> null
        }
    }

    /**
     * The battery-optimization list, for an explicit "my calls arrive late" help flow.
     *
     * Deliberately the LIST screen and not `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: the
     * direct request needs REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, which Play restricts to a
     * short list of app types and rejects on review for everyone else.
     */
    fun batteryOptimizationSettings(): Intent =
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

    private fun appNotificationSettings(context: Context): Intent =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri(context))
        }

    private fun packageUri(context: Context): Uri = Uri.fromParts("package", context.packageName, null)
}
