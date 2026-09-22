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

    /** (A) Live share cadence: balanced power, ~15 s target / 10 s floor, including fresh stationary fixes. */
    private fun liveRequest(): LocationRequest =
        LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, 15_000L)
            .setMinUpdateIntervalMillis(10_000L)
            .setMinUpdateDistanceMeters(0f)
            .setWaitForAccurateLocation(false)
            .build()

    /**
     * Start live-share updates. [onFix] is invoked on the main looper for each fix. Throws
     * SecurityException if permission is not actually held — the caller guarantees it is.
     */
    @SuppressLint("MissingPermission")
    fun startLive(onError: () -> Unit = {}, onFix: (Location) -> Unit) {
        stop()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { location ->
                    if (isRecent(location)) recentFix = Location(location)
                    onFix(location)
                }
            }
        }
        callback = cb
        client.requestLocationUpdates(liveRequest(), cb, Looper.getMainLooper())
            .addOnFailureListener { if (callback === cb) { stop(); onError() } }
    }

    /** One best-effort current fix (for the static pin). Never throws to the caller. */
    @SuppressLint("MissingPermission")
    /**
     * One fix, for a pin or for centring the picker.
     *
     * HIGH_ACCURACY, not BALANCED. Balanced returns a cell/wifi estimate — roughly 100 m, and
     * often a CACHED one — which for a pin the user is placing deliberately meant a marker
     * dropped a street or more from where they were standing. That is the "location is not
     * accurate" report. `getCurrentLocation` (unlike `getLastLocation`) actively computes a
     * fresh fix rather than handing back whatever is in the cache.
     */
    fun currentFix(onResult: (Location?) -> Unit) {
        runCatching {
            client.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
                .addOnSuccessListener { onResult(it) }
                .addOnFailureListener { onResult(null) }
        }.onFailure { onResult(null) }
    }

    /** Cancellable, bounded request independent of the continuous live callback. */
    @SuppressLint("MissingPermission")
    suspend fun freshFix(): Location? {
        if (!LocationPermissions.hasForeground(appContext)) return null
        recentFix?.takeIf { isRecent(it) }?.let { return Location(it) }
        return kotlinx.coroutines.withTimeoutOrNull(15_000) {
            kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
                val cancellation = com.google.android.gms.tasks.CancellationTokenSource()
                continuation.invokeOnCancellation { cancellation.cancel() }
                if (!LocationPermissions.hasForeground(appContext)) {
                    continuation.resumeWith(Result.success(null))
                } else runCatching {
                    val request = com.google.android.gms.location.CurrentLocationRequest.Builder()
                        .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
                        .setMaxUpdateAgeMillis(15_000)
                        .setDurationMillis(15_000)
                        .build()
                    client.getCurrentLocation(request, cancellation.token)
                        .addOnSuccessListener { location ->
                            val valid = location?.takeIf { isRecent(it) }
                            valid?.let { recentFix = Location(it) }
                            if (continuation.isActive) continuation.resumeWith(Result.success(valid))
                        }
                        .addOnFailureListener {
                            if (continuation.isActive) continuation.resumeWith(Result.success(null))
                        }
                }.onFailure {
                    if (continuation.isActive) continuation.resumeWith(Result.success(null))
                }
            }
        }
    }

    companion object {
        // Shared by the picker and live engine, but only for a strictly recent sensor fix.
        // A manually selected map coordinate is never used to start a live share.
        @Volatile private var recentFix: Location? = null
        private fun isRecent(location: Location): Boolean {
            val age = (android.os.SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000
            return location.latitude.isFinite() && location.longitude.isFinite() &&
                location.latitude in -90.0..90.0 && location.longitude in -180.0..180.0 &&
                location.hasAccuracy() && location.accuracy.isFinite() && location.accuracy >= 0 && age in 0..15_000
        }
    }

    fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
    }
}
