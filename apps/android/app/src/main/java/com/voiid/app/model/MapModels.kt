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

    // ── Move (journey / ETA) ────────────────────────────────────────────────────────────
    // Carried on the SAME `fix` frame under the SAME shareKey. A destination and an arrival
    // time are at least as sensitive as the position — "where they will be, and when" is the
    // one thing a position alone does not give you — so they ride inside the authenticated
    // plaintext the server relays as an opaque blob. No new share kind, no server column:
    // `018_location_shares.sql` constrains kind to ('conversation','map') deliberately.
    //
    // Every field is nullable with a default, and explicitNulls=false keeps them off the wire
    // for an ordinary fix. That is the cross-platform contract: iOS's synthesized decoder
    // THROWS on a missing non-optional key (it does not fall back to the default) and its
    // receiveFix() drops the frame on a throw — so a required Move field here would silently
    // kill every Android fix on iOS, the same failure shape already documented on t/n.
    val dlat: Double? = null,            // destination lat, rounded to 3 dp like a presence fix
    val dlon: Double? = null,            // destination lon, same rounding
    val dname: String? = null,           // destination name, chosen by the traveller
    val daddr: String? = null,           // optional street address
    // ABSOLUTE epoch millis of predicted arrival, never a relative countdown: a "12 minutes"
    // is already stale when it renders, while an absolute instant is self-correcting against
    // the viewer's own clock. Long + the lenient serializer, matching iOS's Int64.
    @Serializable(with = LenientEpochMillisSerializer::class)
    val eta: Long? = null,
    // Epoch millis the journey started — the denominator of the arrival progress bar. On the
    // wire because a viewer deriving it from its own first-seen frame would restart the bar
    // at 0% every time the screen was reopened.
    @Serializable(with = LenientEpochMillisSerializer::class)
    val mstart: Long? = null,
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
    /**
     * 25 m, down from 100.
     *
     * The filter decides how far you can move before the pin follows. At 100 m you could walk
     * the length of a building, or to the far end of a platform, and your pin would not move —
     * which reads as stale rather than coarse. 25 m tracks walking honestly while still
     * rejecting the 10–20 m wander of a stationary phone, so a pin left on a desk does not
     * jitter and burn frames.
     *
     * Cost is bounded by the CADENCE, not this: a fix that passes the filter is one WebSocket
     * frame, and the interval still gates how often one can arrive at all.
     */
    const val PRESENCE_MIN_DISTANCE_M = 25f
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

    /**
     * 6 decimals (~0.1 m) — effectively RAW device GPS. Still applied before encryption (§4),
     * but it no longer coarsens: it only trims float noise so two identical positions encode
     * identically.
     *
     * WHY THE COARSENING WENT. This was 3 decimals (~110 m), then 4 (~11 m). Both quantised
     * the pin onto a grid: at 110 m two people standing together showed a block apart, and
     * even at 11 m a pin could sit on the wrong side of a street. The product target is
     * Snap Map, which does NOT fuzz friend-to-friend pins — its published fuzzing applies to
     * PUBLIC Story heatmaps, which is a different feature with a different threat model.
     *
     * THE PRIVACY MODEL DID NOT WEAKEN, because rounding was never carrying it. What protects
     * a position here is that it is end-to-end encrypted to a named allow-list, that Ghost
     * Mode is a hard local gate, that a 24-hour auto-ghost expires the share, and that the
     * user chose each recipient. Blurring the coordinate on top of that bought imprecision,
     * not safety — anyone who can decrypt the fix is someone the user deliberately picked.
     */
    const val PRESENCE_COORD_DECIMALS = 6
}
