package com.voiid.app.net

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.voiid.app.model.MapConstants

/**
 * Coarse, foreground-only location for Map presence (§5) — the FUSED provider, never the
 * platform LocationManager (fused batches, fuses sensors and coalesces across apps, which is
 * the whole point of a <1 %/h ambient state).
 *
 * DELIBERATELY no foreground service and no background updates for the Map: presence is an
 * ambient standing state and must be cheap, so it runs ONLY while the app is foregrounded and
 * dies the instant the app leaves (the honest version of "no background disclosure needed",
 * §8). Live conversation sharing — Feature (A) — is the one that runs an FGS; the Map does not.
 *
 * This provider takes NO position of its own accord. Ghost Mode's hard gate lives one level up
 * in [MapPresenceEngine], which simply never calls [start] while ghosted — "the fix is never
 * taken", not "we filter it server-side".
 */
class MapLocationProvider(context: Context) {

    private val appContext = context.applicationContext
    private val client: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(appContext)

    private var callback: LocationCallback? = null

    /** A foreground location grant of either precision — coarse is enough for ~110 m presence. */
    fun hasPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_COARSE_LOCATION)
        return fine == PackageManager.PERMISSION_GRANTED || coarse == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Begin coarse presence updates. [onFix] receives coordinates ALREADY ROUNDED to 3 decimals
     * (~110 m) — rounding at the source, before anything leaves this method, so an unrounded
     * coordinate can never reach the encrypt path. No-op (returns false) without permission.
     */
    @SuppressLint("MissingPermission") // guarded by hasPermission() immediately above
    fun start(onFix: (lat: Double, lon: Double, acc: Double?) -> Unit): Boolean {
        if (!hasPermission()) return false
        stop()
        val request = LocationRequest.Builder(
            Priority.PRIORITY_BALANCED_POWER_ACCURACY,
            MapConstants.PRESENCE_INTERVAL_MS,
        )
            .setMinUpdateDistanceMeters(MapConstants.PRESENCE_MIN_DISTANCE_M)
            .setWaitForAccurateLocation(false)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val loc = result.lastLocation ?: return
                onFix(round(loc.latitude), round(loc.longitude), if (loc.hasAccuracy()) loc.accuracy.toDouble() else null)
            }
        }
        callback = cb
        return runCatching {
            client.requestLocationUpdates(request, cb, Looper.getMainLooper())
            true
        }.getOrDefault(false)
    }

    fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
    }

    /** One-shot best-effort fix used on foreground so the map is fresh immediately. */
    @SuppressLint("MissingPermission")
    fun requestSingle(onFix: (lat: Double, lon: Double, acc: Double?) -> Unit) {
        if (!hasPermission()) return
        runCatching {
            client.getCurrentLocation(Priority.PRIORITY_BALANCED_POWER_ACCURACY, null)
                .addOnSuccessListener { loc ->
                    if (loc != null) {
                        onFix(round(loc.latitude), round(loc.longitude), if (loc.hasAccuracy()) loc.accuracy.toDouble() else null)
                    }
                }
        }
    }

    private fun round(v: Double): Double {
        var f = 1.0
        repeat(MapConstants.PRESENCE_COORD_DECIMALS) { f *= 10.0 }
        return Math.round(v * f) / f
    }
}
