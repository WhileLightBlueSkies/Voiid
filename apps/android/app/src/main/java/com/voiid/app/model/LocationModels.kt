package com.voiid.app.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.math.roundToLong

/**
 * Decodes an epoch-millis field that SHOULD be an integer but may arrive fractional.
 *
 * iOS holds `t` / `expiresAt` as `Double` internally and older builds put
 * `Date().timeIntervalSince1970 * 1000` on the wire verbatim — e.g. `1785154289733.0242`.
 * A plain `Long` decoder THROWS on that literal, and every inbound call site here wraps
 * decoding in `runCatching{}`, so the whole message was dropped with no error and no log:
 * pins, live_start, live_stop and every relayed fix from iOS simply never appeared.
 *
 * iOS now rounds at its encode choke point, but builds already installed do not, so this
 * stays as the permanent tolerant floor. Always ENCODES a clean integer.
 */
internal object LenientEpochMillisSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("EpochMillis", PrimitiveKind.LONG)

    override fun deserialize(decoder: Decoder): Long =
        // decodeDouble() accepts both `1785154289733` and `1785154289733.0242`; Double holds
        // millis exactly out to 2^53, far past any real timestamp, so this loses nothing.
        decoder.decodeDouble().roundToLong()

    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeLong(value)
}

/**
 * Location sharing models (Feature A — location INSIDE conversations). See docs/LOCATION.md.
 *
 * The envelope below is the PLAINTEXT of an E2EE message (1:1 over the Double Ratchet, group
 * over MLS) or of a WebSocket-relayed live fix. Coordinates are only ever inside this
 * authenticated plaintext — the server sees ciphertext, an opaque share id, and routing ids.
 *
 * `_vloc` is the discriminator: `content_type == "location"` OR a plaintext that parses as
 * JSON with `_vloc == 1` is a location envelope. The marker (not the content_type) is what
 * makes this safe on the group/MLS path, where content_type is always "group".
 */
@Serializable
data class LocationEnvelope(
    @SerialName("_vloc") val vloc: Int = 1,
    /** pin | live_start | live_stop | live_rekey | fix. (map_key/map_off are Feature B.) */
    val k: String,
    /** share_id (uuid) — omitted for k:"pin". */
    val s: String? = null,
    @Serializable(with = LenientEpochMillisSerializer::class)
    val t: Long = 0,
    /**
     * Monotonic sequence for a fix, so an out-of-order relay frame is dropped, not drawn.
     * Lenient for the same reason as [t]: iOS seeds it from a timestamp, and a peer that
     * ever emits it fractional must not silently kill every fix from that share.
     */
    @Serializable(with = LenientEpochMillisSerializer::class)
    val n: Long? = null,
    val lat: Double? = null,
    val lon: Double? = null,
    val acc: Double? = null,
    /** Optional, user-typed. NEVER reverse-geocoded (docs/LOCATION.md §10). */
    val label: String? = null,
    /** Millis. live_start / live_rekey only. */
    @Serializable(with = LenientEpochMillisSerializer::class)
    val expiresAt: Long? = null,
    /**
     * Base64 32-byte shareKey — live_start / live_rekey ONLY. Comes from
     * `generateMasterSecret()` and is NEVER persisted in the message store; the recipient
     * lifts it into the secure key store and drops it here. See docs/LOCATION.md §1 (the
     * HKDF-label trap) and §11.
     */
    val key: String? = null,
    /** Seconds; live_start. */
    val cadence: Int? = null,
    // Reserved, never drawn in v1 (docs/LOCATION.md §10.14).
    val alt: Double? = null,
    val hdg: Double? = null,
    val spd: Double? = null,
) {
    companion object {
        const val VLOC = 1
        const val K_PIN = "pin"
        const val K_LIVE_START = "live_start"
        const val K_LIVE_STOP = "live_stop"
        const val K_LIVE_REKEY = "live_rekey"
        const val K_FIX = "fix"

        /** True for a `k` that renders a chat bubble (vs. silent control consumed by the engine). */
        fun rendersBubble(k: String): Boolean = k == K_PIN || k == K_LIVE_START || k == K_LIVE_STOP
    }
}

/** One decoded live position for a share, held ONLY as the single most-recent fix (no trail). */
data class LocationFix(
    val shareId: String,
    val senderUserId: String,
    val lat: Double,
    val lon: Double,
    val acc: Double,
    val seq: Long,
    /** Epoch millis this fix was produced (envelope `t`). */
    val fixedAt: Long,
)

/** The three recipient-visible states, never conflated (docs/LOCATION.md §3). */
enum class ShareState { LIVE, STALE, ENDED }

/**
 * Live view state for ONE inbound share, observed by the bubble. Everything is derivable from
 * [expiresAt] alone (the timer guarantee): a recipient who never receives the stop still hides
 * the marker at [expiresAt], offline, with no network.
 */
data class LiveShareView(
    val shareId: String,
    val ownerUserId: String,
    val expiresAt: Long,          // millis
    val cadenceSeconds: Int,
    val lastFix: LocationFix?,
    /** A `live_stop` (or `loc_stop`) was received — hard ended regardless of the timer. */
    val endedExplicit: Boolean,
) {
    fun state(now: Long = System.currentTimeMillis()): ShareState = when {
        endedExplicit || now >= expiresAt -> ShareState.ENDED
        lastFix == null -> ShareState.STALE
        now - lastFix.fixedAt <= (2L * cadenceSeconds * 1000L + 30_000L) -> ShareState.LIVE
        else -> ShareState.STALE
    }
}

/** One of MY currently-active outbound live shares — drives the persistent banner + Stop. */
data class OutboundShareView(
    val shareId: String,
    val conversationId: String,
    val expiresAt: Long,          // millis
)
