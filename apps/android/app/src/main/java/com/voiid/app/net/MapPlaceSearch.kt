package com.voiid.app.net

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.google.android.libraries.places.api.Places
import com.google.android.libraries.places.api.model.AutocompleteSessionToken
import com.google.android.libraries.places.api.model.Place
import com.google.android.libraries.places.api.net.FetchPlaceRequest
import com.google.android.libraries.places.api.net.FindAutocompletePredictionsRequest
import com.google.android.libraries.places.api.net.PlacesClient
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Place search for the Map tab — the Android half of the same feature iOS gets from
 * `MKLocalSearchCompleter` (see `MapSearchModel.swift`).
 *
 * SETUP REQUIRED (one Cloud Console change, no code change):
 *   the existing Maps key must have **Places API (New)** enabled AND listed in the key's
 *   API restrictions. Without it every request fails — which is why every call here degrades
 *   to an empty result list and a log line rather than throwing into the UI. The search field
 *   is additionally gated behind `BuildConfig.MAPS_CONFIGURED`, so a build with no key at all
 *   never shows search at all.
 *
 * BILLING: autocomplete is billed per SESSION, not per keystroke, as long as one
 * [AutocompleteSessionToken] spans predictions→fetch. [newSession] mints one per search
 * session and [fetchPlace] consumes it, which keeps a whole "type, refine, pick" interaction
 * in the cheap tier. Fields on the fetch are restricted to ID/NAME/LAT_LNG/ADDRESS — asking
 * for more moves the request into a more expensive SKU for data we would not use.
 *
 * PRIVACY: queries only go out while the user is actively typing in the search field. An idle
 * Map tab issues no Places traffic at all.
 */
object MapPlaceSearch {

    private const val TAG = "MapPlaceSearch"

    @Volatile private var client: PlacesClient? = null
    @Volatile private var unavailable = false

    /** One autocomplete result: what to show in the list, and the id needed to resolve it. */
    data class Suggestion(val placeId: String, val title: String, val subtitle: String)

    /** A resolved place: enough to drop a pin and hand off to the maps app. */
    data class Resolved(val placeId: String, val name: String, val address: String?, val lat: Double, val lon: Double)

    /**
     * Idempotent. Reads the SAME key the Maps SDK uses from the manifest metadata rather than
     * taking a second copy of the secret into BuildConfig — one key, one place it is injected.
     * Returns false when the key is missing, which the UI treats as "no search".
     */
    fun ensureInitialized(context: Context): Boolean {
        if (unavailable) return false
        client?.let { return true }
        synchronized(this) {
            client?.let { return true }
            val key = runCatching {
                context.packageManager
                    .getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
                    .metaData?.getString("com.google.android.geo.API_KEY")
            }.getOrNull()
            if (key.isNullOrBlank()) {
                unavailable = true
                return false
            }
            return runCatching {
                if (!Places.isInitialized()) Places.initializeWithNewPlacesApiEnabled(context.applicationContext, key)
                client = Places.createClient(context.applicationContext)
                true
            }.getOrElse {
                Log.w(TAG, "Places init failed — is 'Places API (New)' enabled on the Maps key?", it)
                unavailable = true
                false
            }
        }
    }

    /** A token spanning one "type, refine, pick" interaction — see the billing note above. */
    fun newSession(): AutocompleteSessionToken = AutocompleteSessionToken.newInstance()

    /**
     * Autocomplete for [query]. Empty list on any failure (no key, API not enabled, offline) —
     * search degrading to "no results" is always better than an error dialog over the map.
     *
     * [bias] centres results on what the user is looking at, so "coffee" means coffee HERE.
     */
    suspend fun predictions(
        context: Context,
        query: String,
        session: AutocompleteSessionToken,
        bias: com.google.android.gms.maps.model.LatLngBounds? = null,
    ): List<Suggestion> {
        if (query.isBlank()) return emptyList()
        if (!ensureInitialized(context)) return emptyList()
        val c = client ?: return emptyList()
        val request = FindAutocompletePredictionsRequest.builder()
            .setQuery(query)
            .setSessionToken(session)
            .apply { bias?.let { setLocationBias(com.google.android.libraries.places.api.model.RectangularBounds.newInstance(it)) } }
            .build()
        return suspendCancellableCoroutine { cont ->
            c.findAutocompletePredictions(request)
                .addOnSuccessListener { res ->
                    cont.resume(
                        res.autocompletePredictions.take(6).map {
                            Suggestion(
                                placeId = it.placeId,
                                title = it.getPrimaryText(null).toString(),
                                subtitle = it.getSecondaryText(null).toString(),
                            )
                        },
                    )
                }
                .addOnFailureListener {
                    Log.w(TAG, "autocomplete failed — check 'Places API (New)' on the Maps key", it)
                    cont.resume(emptyList())
                }
        }
    }

    /**
     * Resolve a suggestion to a coordinate. Consumes [session], which is what closes the
     * billed autocomplete session — never reuse a token after this.
     */
    suspend fun fetchPlace(
        context: Context,
        placeId: String,
        session: AutocompleteSessionToken,
    ): Resolved? {
        if (!ensureInitialized(context)) return null
        val c = client ?: return null
        // ID/NAME/LAT_LNG/ADDRESS only — more fields would move this into a pricier SKU for
        // data we do not render.
        val fields = listOf(Place.Field.ID, Place.Field.NAME, Place.Field.LAT_LNG, Place.Field.ADDRESS)
        val request = FetchPlaceRequest.builder(placeId, fields).setSessionToken(session).build()
        return suspendCancellableCoroutine { cont ->
            c.fetchPlace(request)
                .addOnSuccessListener { res ->
                    val p = res.place
                    val ll = p.latLng
                    cont.resume(
                        if (ll == null) null
                        else Resolved(placeId, p.name ?: "Place", p.address, ll.latitude, ll.longitude),
                    )
                }
                .addOnFailureListener {
                    Log.w(TAG, "fetchPlace failed", it)
                    cont.resume(null)
                }
        }
    }
}
