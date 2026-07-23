package com.voiid.app.net

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.os.Looper
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/**
 * Thin wrapper over [FusedLocationProviderClient] (docs/LOCATION.md §5). Fused — not the
 * platform LocationManager — because it batches, fuses sensors and coalesces requests across
 * apps, which is the entire battery argument for a 10–15 s cadence live share.
 *
 * This class NEVER checks or requests runtime permission itself — that is the caller's job
 * (LocationPermissions) done in-context before a share starts. The [SuppressLint] is deliberate
 * and honest: the FGS + the share lifecycle guarantee we only start updates after a grant.
 */
class LocationProvider(context: Context) {

    private val appContext = context.applicationContext
    private val client: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(appContext)

    private var callback: LocationCallback? = null

    /** (A) Live share cadence: balanced power, ~15 s target / 10 s floor, 25 m distance filter. */
    private fun liveRequest(): LocationRequest =
        LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, 15_000L)
            .setMinUpdateIntervalMillis(10_000L)
            .setMinUpdateDistanceMeters(25f)
            .setWaitForAccurateLocation(false)
            .build()

    /**
     * Start live-share updates. [onFix] is invoked on the main looper for each fix. Throws
     * SecurityException if permission is not actually held — the caller guarantees it is.
     */
    @SuppressLint("MissingPermission")
    fun startLive(onFix: (Location) -> Unit) {
        stop()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let(onFix)
            }
        }
        callback = cb
        client.requestLocationUpdates(liveRequest(), cb, Looper.getMainLooper())
    }

    /** One best-effort current fix (for the static pin). Never throws to the caller. */
    @SuppressLint("MissingPermission")
    fun currentFix(onResult: (Location?) -> Unit) {
        runCatching {
            client.getCurrentLocation(Priority.PRIORITY_BALANCED_POWER_ACCURACY, null)
                .addOnSuccessListener { onResult(it) }
                .addOnFailureListener { onResult(null) }
        }.onFailure { onResult(null) }
    }

    fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
    }
}
