package com.voiid.app.net

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.android.gms.location.LocationResult

/**
 * Receives Map-presence location fixes, INCLUDING while the app process is dead.
 *
 * WHY A RECEIVER AND NOT A CALLBACK. `requestLocationUpdates(request, callback, looper)` binds
 * the fix to an in-process object: when Android kills the app — which it does aggressively to
 * a backgrounded app, and immediately when the user swipes it from Recents — that callback
 * dies with it. The user's pin then freezes wherever they last had Voiid open, which is worse
 * than showing nothing: it tells their contacts they are somewhere they left an hour ago.
 *
 * The PendingIntent form of the same API survives that. The OS holds the intent, and when a
 * fix arrives it starts the process cold just to deliver this broadcast. That is how Android
 * does background location without pinning a foreground service.
 *
 * WHY NOT A FOREGROUND SERVICE. There is one (LocationForegroundService), and it is correct
 * for a LIVE SHARE: a short, explicit, timer-bounded act that the user started and that
 * justifies a permanent notification. Map presence is an ambient standing state — a
 * persistent "Voiid is using your location" notification for it would be both wrong and
 * exhausting, and docs/LOCATION.md §8 says the Map deliberately has no FGS.
 *
 * GHOST MODE STILL WINS. The receiver re-reads visibility from the store on every fix rather
 * than trusting that it was unregistered — a process death between "user ghosts" and
 * "unregister lands" must not leak a position.
 */
class MapLocationReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_FIX) return
        val result = LocationResult.extractResult(intent) ?: return
        val loc = result.lastLocation ?: return

        // The app may have been started COLD by this broadcast, so nothing is initialised.
        // MapPresenceEngine.handleBackgroundFix does its own bootstrap and its own ghost
        // check; this receiver stays a thin delivery point.
        runCatching {
            MapPresenceEngine.handleBackgroundFix(
                context.applicationContext,
                loc.latitude,
                loc.longitude,
                if (loc.hasAccuracy()) loc.accuracy.toDouble() else null,
            )
        }.onFailure {
            Log.w("VOIID", "map: background fix failed", it)
        }
    }

    companion object {
        const val ACTION_FIX = "com.voiid.app.MAP_LOCATION_FIX"
    }
}
