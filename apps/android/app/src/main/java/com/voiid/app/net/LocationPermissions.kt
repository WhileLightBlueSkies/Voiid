package com.voiid.app.net

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * The runtime location-permission flow (docs/LOCATION.md §5). THREE steps, in order, because
 * Android 11+ forbids requesting background in the same prompt as foreground and bolting it onto
 * the onboarding one-shot array silently fails:
 *
 *  1. Foreground (FINE + COARSE), requested IN-CONTEXT at first share — never in PermissionsScreen.
 *  2. Background (ACCESS_BACKGROUND_LOCATION) ONLY if step 1 granted AND the user chose a duration
 *     > 15 min. On API 30+ the system routes this to app Settings ("Allow all the time"), so the
 *     caller's rationale sheet must warn the user they are leaving the app.
 *  3. POST_NOTIFICATIONS (handled at onboarding) so the FGS notification is visible.
 *
 * Denials never crash: a foreground-only share still runs (it just pauses in the background).
 */
object LocationPermissions {

    fun hasForeground(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    fun hasBackground(context: Context): Boolean {
        // Below API 29 there is no separate background grant — foreground implies it.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return hasForeground(context)
        return ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    /**
     * True once the user has denied foreground location AND ticked "Don't ask again" (or the OS
     * decided not to show the dialog): the next request is a silent no-op, so the caller must
     * route the user to app Settings instead of re-prompting. Requires an Activity context.
     */
    fun foregroundPermanentlyDenied(activity: Activity): Boolean =
        !hasForeground(activity) &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.ACCESS_FINE_LOCATION) &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.ACCESS_COARSE_LOCATION)

    /** Open this app's system settings page (for the permanently-denied / background-on-30+ cases). */
    fun openAppSettings(context: Context) {
        val i = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(i) }
    }
}

/** Outcome delivered to the caller once the (possibly two-step) flow settles. */
enum class LocationPermissionResult {
    /** Foreground granted, and background granted when it was needed — full share can run. */
    FULL,
    /** Foreground granted but background is not — the share runs foreground-only. */
    FOREGROUND_ONLY,
    /** Foreground denied — no share. */
    DENIED,
}

/**
 * A composable-owned controller for the permission flow. Activity result launchers must be
 * created during composition, so this is produced by [rememberLocationPermissions] and driven
 * imperatively from a click.
 */
class LocationPermissionController internal constructor(
    private val context: Context,
    private val requestForeground: (Array<String>) -> Unit,
    private val requestBackground: (String) -> Unit,
) {
    private var wantBackground = false
    private var pending: ((LocationPermissionResult) -> Unit)? = null

    /** Kick off the flow. [needBackground] is true only for a duration > 15 min. */
    fun request(needBackground: Boolean, onResult: (LocationPermissionResult) -> Unit) {
        pending = onResult
        wantBackground = needBackground
        if (!LocationPermissions.hasForeground(context)) {
            requestForeground(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
            return
        }
        afterForeground(true)
    }

    internal fun onForegroundResult(granted: Boolean) = afterForeground(granted || LocationPermissions.hasForeground(context))

    private fun afterForeground(granted: Boolean) {
        if (!granted) { finish(LocationPermissionResult.DENIED); return }
        if (!wantBackground || LocationPermissions.hasBackground(context)) {
            finish(if (LocationPermissions.hasBackground(context)) LocationPermissionResult.FULL else LocationPermissionResult.FOREGROUND_ONLY)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // On API 30+ the OS ignores this dialog and sends the user to Settings; either way we
            // settle on the callback below. The caller shows a "you are leaving the app" sheet.
            requestBackground(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else {
            finish(LocationPermissionResult.FULL)  // no separate background grant pre-Q
        }
    }

    internal fun onBackgroundResult() {
        finish(if (LocationPermissions.hasBackground(context)) LocationPermissionResult.FULL else LocationPermissionResult.FOREGROUND_ONLY)
    }

    private fun finish(result: LocationPermissionResult) {
        pending?.invoke(result)
        pending = null
    }
}

@Composable
fun rememberLocationPermissions(): LocationPermissionController {
    val context = androidx.compose.ui.platform.LocalContext.current
    // Held in a single-element array so the launcher lambdas (created before the controller) can
    // reach the controller once it is constructed.
    val holder = remember { arrayOfNulls<LocationPermissionController>(1) }
    val fgLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        val granted = grants.values.any { it }
        holder[0]?.onForegroundResult(granted)
    }
    val bgLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { _ ->
        holder[0]?.onBackgroundResult()
    }
    return remember {
        LocationPermissionController(
            context = context,
            requestForeground = { perms -> fgLauncher.launch(perms) },
            requestBackground = { perm -> bgLauncher.launch(perm) },
        ).also { holder[0] = it }
    }
}
