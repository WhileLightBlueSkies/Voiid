package com.voiid.app.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire + local types for Feature (B), The Map — docs/LOCATION.md.
 *
 * The Map is the SAFETY-CRITICAL surface: you appear to no one until you name individual
 * people (empty-by-default allow-list), and Ghost Mode is a HARD LOCAL GATE — no fix is
 * ever taken while it is on. Coordinates are rounded to 3 decimals (~110 m) at the source,
 * before encryption, because ambient presence must be cheap AND imprecise.
 *
 * Nothing here holds more than the single most recent fix per contact. There is no history,
 * no trail, no breadcrumb — ever (§8, §10.1). The subject cache is in memory only, so a cold
 * start already satisfies "wipe anything older than 8 h": everything is gone.
 */

/**
 * The self-describing E2EE envelope (§4). The discriminator [vloc] and identifiers live
 * INSIDE the authenticated plaintext because no AEAD here accepts AAD — GCM covers them.
 *
 * Only the Map's kinds are modelled: `map_key` (mints/redistributes the shareKey), `map_off`
 * (durable "I've gone dark"), and `fix` (a streamed position, WS-only). Serialised with
 * ApiClient.json (explicitNulls=false) so omitted fields never hit the wire — a fix is
 * ~100-160 bytes. Reserved fields alt/hdg/spd are deliberately absent (§10.14).
 */
@Serializable
data class MapEnvelope(
    @SerialName("_vloc") val vloc: Int = 1,
    val k: String,                       // map_key | map_off | fix
    val s: String? = null,               // share_id (uuid)
    // t / n / expiresAt use the lenient decoder for the same reason as LocationEnvelope: a
    // peer that puts a fractional literal on the wire must not silently kill the whole frame.
    // See LenientEpochMillisSerializer.
    @Serializable(with = LenientEpochMillisSerializer::class)
    val t: Long? = null,                 // fix wall-clock millis
    @Serializable(with = LenientEpochMillisSerializer::class)
    val n: Long? = null,                 // monotonic seq — drops an out-of-order relay frame
    val lat: Double? = null,
    val lon: Double? = null,
    val acc: Double? = null,
    @Serializable(with = LenientEpochMillisSerializer::class)
    val expiresAt: Long? = null,         // map_key only — the guarantee both sides hold locally
    val key: String? = null,            // map_key only — base64 32-byte shareKey (NEVER a backup secret)
    val cadence: Int? = null,            // seconds — map_key only
)

/**
 * A contact the audience picker can offer: someone we already hold a 1:1 conversation with,
 * because the `map_key` control message needs a [conversationId] to ride the ratchet (§8).
 * [userId] is the peer; a raw id is NEVER shown — the UI resolves the name via UserDirectory.
 */
@Serializable
data class MapContact(
    val userId: String,
    val conversationId: String,
)

/** How the local device presents on the Map right now. Default is [GHOST] — see the honesty rule. */
enum class MapVisibility { GHOST, VISIBLE }

/**
 * Recipient-visible lifecycle of ONE subject on the Map (§8 table). The load-bearing
 * distinction: an explicit stop ([NOT_SHARING]) ERASES the cached position; an age-out
 * ([AGED_OUT]) KEEPS it. That is how a viewer tells "they turned it off" from "their phone
 * is dead" — a safety property, not polish.
 */
enum class MapSubjectState { LIVE, STALE, NOT_SHARING, AGED_OUT }

/** The single most recent decrypted fix for one subject. Overwritten in place, never appended. */
data class MapFix(
    val subjectUserId: String,
    val shareId: String,
    val lat: Double,
    val lon: Double,
    val acc: Double?,
    val seq: Long,
    val fixedAt: Long,       // epoch millis of the fix
)

/**
 * A person visible to us on the Map: the last fix (or its erased/aged tombstone) plus the
 * derived [state]. `fix` is null only when an explicit stop erased it ([NOT_SHARING]).
 */
data class MapSubject(
    val userId: String,
    val fix: MapFix?,
    val state: MapSubjectState,
) {
    /** Fresh, drawable-on-the-map subject: full-colour avatar (Live) or desaturated (Stale). */
    val isOnMap: Boolean get() = fix != null && (state == MapSubjectState.LIVE || state == MapSubjectState.STALE)
}

object MapConstants {
    // Presence cadence (§5): coarse, foreground-only. Balanced power, ~5 min / 250 m.
    const val PRESENCE_INTERVAL_MS = 300_000L

    /**
     * Background presence cadence: 15 minutes, vs 5 in the foreground.
     *
     * A background fix WAKES THE PROCESS — the OS may start Voiid cold just to deliver it —
     * which costs far more than an in-process callback. Presence is an ambient standing
     * state measured in hundreds of metres; 15 minutes keeps a pin honest without paying to
     * wake three times as often for a position that has barely moved.
     */
    const val PRESENCE_BACKGROUND_INTERVAL_MS = 900_000L
    const val PRESENCE_MIN_DISTANCE_M = 250f
    const val PRESENCE_CADENCE_SECONDS = 300

    // §8 subject-state thresholds, all derived from the fix age (works with zero network).
    const val LIVE_MAX_AGE_MS = 15 * 60 * 1000L          // < 15 min → Live
    const val STALE_MAX_AGE_MS = 8 * 60 * 60 * 1000L     // 15 min – 8 h → Stale; older → aged out

    // Hard 24-hour auto-ghost (§3): visibility is never something you forget about for a week.
    const val MAP_MAX_DURATION_SECONDS = 24 * 60 * 60

    /**
     * Fallback lifetime for an inbound `map_key` that arrived with no `expiresAt`.
     *
     * MUST be used by BOTH capture paths — MapPresenceEngine.onControl (foreground) and
     * ChatEngine's background capture. They previously disagreed (8 h vs 24 h), so the exact
     * same key expired 16 h early depending only on whether the app happened to be open when
     * it arrived. Anchored to the share ceiling, which is the real upper bound on how long a
     * sender's share can live.
     */
    const val DEFAULT_KEY_TTL_MS = MAP_MAX_DURATION_SECONDS * 1000L

    // Map presence coordinates are rounded to 3 decimals (~110 m) BEFORE encryption (§4).
    const val PRESENCE_COORD_DECIMALS = 3
}
