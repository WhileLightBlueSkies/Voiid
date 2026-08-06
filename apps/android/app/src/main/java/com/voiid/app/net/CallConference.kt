package com.voiid.app.net

import android.content.Context
import android.util.Base64
import android.util.Log
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable

/**
 * Ad-hoc conference calling — the wire, the REST contract and the key courier.
 * Repair plan §3.3 (per-call secret over the ratchet) and §3.8 (the same keying for plain 1:1).
 * The escalation state machine that drives all of it lives in [ConferenceManager].
 *
 * ## THE STRUCTURAL RULE, and why this file exists at all
 *
 * From a live 1:1 call you can add a third person. If that person is a stranger to your peer,
 * your peer sees their **@username** and nothing else — and to message them afterwards they must
 * still pass the 6-digit contact-PIN gate. **A SHARED CALL GRANTS NO MESSAGING RIGHTS.**
 *
 * That is why this cannot be built on the existing group-call path, which is a LiveKit room keyed
 * on a conversation's MLS state: escalating that way would have to create a group CONVERSATION,
 * and a conversation membership row is exactly the messaging edge the product forbids.
 *
 * So: **NOTHING in this file, or anywhere else on the call path, may write to a conversation
 * table.** Call state lives in `call_participants`. Reachability is READ from conversations to
 * answer "may A reach B" and never written. If a future change makes escalation create or mutate
 * a conversation/membership row, the PIN gate in `020_reachability.sql` is bypassed and the
 * product requirement is silently broken. There is no test that will catch it on this side of the
 * wire — the backend guard tests (`backend/api/test/callConference.test.ts`) are the ones that
 * will, and they will fail loudly. Do not "fix" them.
 *
 * ## CALL KEYS, NOT CONVERSATION KEYS
 *
 * Media for a conference is keyed by a per-call secret minted with `newCallSecret()`, distributed
 * PAIRWISE over the existing Double Ratchet, and rotated on every join and leave. A conversation
 * key is never reused for call media — an added stranger is not in your conversation and must not
 * be able to derive anything about it, and your peer must not be able to derive anything about
 * the stranger's other calls.
 */

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Constants — mirrored from backend/api/src/callConference.ts. Keep in step.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/** `voiid-call-<call_id>` — the ad-hoc room for a conference escalated out of a 1:1 call. */
const val ADHOC_ROOM_PREFIX = "voiid-call-"

/** Server-enforced ceiling. The UI hides "add person" once the roster reaches it. */
const val MAX_CALL_PARTICIPANTS = 8

/** The room name for [callId]. Derived, never sent by the client as a request field. */
fun adhocRoomName(callId: String): String = ADHOC_ROOM_PREFIX + callId

// ─────────────────────────────────────────────────────────────────────────────────────────────
// ConferenceRelay — the WS seam
// ─────────────────────────────────────────────────────────────────────────────────────────────

/**
 * The integration seam between [WebSocketClient] and the conference engine, mirroring
 * [LocationRelay] / [GamesRelay] and existing for the same reason: a single mutable callback on
 * the socket lets one consumer clobber another, and this keeps the shared-file edit down to one
 * fan-out call.
 *
 * `ciphertext` crossing here is OPAQUE — pairwise Double-Ratchet output that the relay copied
 * verbatim. It is never parsed, never logged, and only [CallKeyCourier] may open it.
 */
object ConferenceRelay {

    /** One inbound conference frame. Every field beyond type/from/call_id is frame-specific. */
    data class Frame(
        val type: String,
        val fromUserId: String,
        val callId: String,
        val callKind: String? = null,
        val room: String? = null,
        /** `call_key` only: WHICH of OUR devices this copy is encrypted to. */
        val deviceId: String? = null,
        /** `call_key` only: which of the SENDER's devices encrypted it (picks the ratchet session). */
        val senderDeviceId: String? = null,
        /** `call_key` only: opaque base64. Never logged. */
        val ciphertextB64: String? = null,
    )

    fun interface Sink { fun onFrame(frame: Frame) }

    private val sinks = mutableListOf<Sink>()

    fun subscribe(s: Sink) = synchronized(sinks) { if (!sinks.contains(s)) sinks.add(s) }
    fun unsubscribe(s: Sink) = synchronized(sinks) { sinks.remove(s) }

    fun dispatch(
        type: String,
        fromUserId: String,
        callId: String,
        callKind: String?,
        room: String?,
        deviceId: String?,
        senderDeviceId: String?,
        ciphertextB64: String?,
    ) {
        val frame = Frame(type, fromUserId, callId, callKind, room, deviceId, senderDeviceId, ciphertextB64)
        val snapshot = synchronized(sinks) { sinks.toList() }
        // runCatching per sink: one subscriber throwing must not swallow the frame for the rest,
        // and a signaling frame is never worth crashing the socket thread over.
        for (s in snapshot) runCatching { s.onFrame(frame) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// REST contract — POST /v1/calls/:id/{escalate,adhoc-token,join,leave}, GET .../participants
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// SERIALIZATION BUG CLASSES THIS FILE IS WRITTEN AGAINST (both have bitten this repo):
//
//  * REQUEST bodies: the shared `ApiClient.json` has `encodeDefaults = false`, so any property
//    with a default is silently OMITTED from the wire. Every defaulted field on an outbound DTO
//    below therefore carries @EncodeDefault. `EscalateBody.invitee_user_id` has no default at
//    all, which is the strongest form of the same guarantee.
//
//  * RESPONSE bodies: kotlinx throws MissingFieldException on an ABSENT key for a property with
//    no default — the Kotlin analogue of Swift's `keyNotFound`. Every response property below
//    has a default, so a server that adds, renames or conditionally omits a field degrades the
//    reading rather than throwing the whole call away.

/** One roster entry. **@username and state only** — see [CallRosterEntry.displayName]. */
@Serializable
data class CallRosterEntry(
    val user_id: String = "",
    /** Nullable BY CONTRACT: a user may have no handle yet. Renders as "Unknown", never a uuid. */
    val username: String? = null,
    /** "invited" | "joined". 'left' is never returned. */
    val state: String = "invited",
    val invited_by: String? = null,
    val is_self: Boolean = false,
) {
    val isJoined: Boolean get() = state == "joined"

    /**
     * The name to render for this entry.
     *
     * USE THIS, never `GET /users/:id`: that endpoint returns `full_name` to ANY authenticated
     * caller, so resolving a call roster through it would leak a stranger's private-plane
     * profile name to someone who merely shares a call with them. The precedence
     * (known peer -> local name; everyone else -> "@username"; null -> "Unknown") lives in
     * [com.voiid.app.store.UserDirectory.callRosterName] so both call surfaces share one rule.
     */
    fun displayName(selfLabel: String = "You"): String =
        if (is_self) selfLabel
        else com.voiid.app.store.UserDirectory.callRosterName(user_id, username)
}

@Serializable
data class EscalateInvitee(val user_id: String = "", val username: String? = null)

@Serializable
data class EscalateResponse(
    val call_id: String = "",
    val room: String = "",
    val livekit_url: String? = null,
    val livekit_configured: Boolean = false,
    val invitee: EscalateInvitee? = null,
    val participants: List<CallRosterEntry> = emptyList(),
    val ringing_devices: Int = 0,
    val voip_devices: Int = 0,
    val grant_ttl_seconds: Long = 0,
)

@Serializable
data class AdhocTokenResponse(
    val url: String = "",
    val token: String = "",
    val room: String = "",
    val identity: String? = null,
    /** "invited" | "joined" — the roster row we were let in on. */
    val state: String = "invited",
    val ttl_seconds: Long = 0,
)

@Serializable
data class CallJoinResponse(
    val call_id: String = "",
    val room: String = "",
    val state: String = "joined",
    val participant_count: Int = 0,
    val participants: List<CallRosterEntry> = emptyList(),
)

@Serializable
data class CallLeaveResponse(
    val call_id: String = "",
    val left: Boolean = true,
    val was_participant: Boolean = false,
    val participant_count: Int = 0,
)

@Serializable
data class CallParticipantsResponse(
    val call_id: String = "",
    val room: String = "",
    val call_kind: String = "voice",
    val status: String = "",
    val participants: List<CallRosterEntry> = emptyList(),
)

/**
 * Thin REST client for the five conference endpoints. All are mounted under `/v1/calls`; all
 * take the session bearer; `:id` is the CALL id — the same client-generated uuid that
 * `POST /calls/ring` and every WS call frame already use.
 */
class ConferenceApi(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    /**
     * Invite [inviteeUserId] into call [callId].
     *
     * Hand-built body rather than a DTO round trip would work too, but the DTO documents the
     * contract — one non-defaulted field, so `encodeDefaults = false` cannot drop it.
     */
    suspend fun escalate(callId: String, inviteeUserId: String): EscalateResponse {
        val body = ApiClient.json.encodeToString(EscalateBody.serializer(), EscalateBody(inviteeUserId))
        return api.requestAs("POST", "calls/$callId/escalate", jsonBody = body)
    }

    /** A LiveKit JWT for `voiid-call-<callId>`. Gated on a live participant row, NOT membership. */
    suspend fun adhocToken(callId: String): AdhocTokenResponse =
        api.requestAs("POST", "calls/$callId/adhoc-token", jsonBody = "{}")

    /** invited|joined => joined. The membership event the rekey hangs off. */
    suspend fun join(callId: String): CallJoinResponse =
        api.requestAs("POST", "calls/$callId/join", jsonBody = "{}")

    /**
     * Leave — and the DECLINE path: an invitee who never joined declines by calling this.
     * Idempotent, and never fails a teardown retry (leaving twice is a 200 with
     * `was_participant:false`).
     */
    suspend fun leave(callId: String): CallLeaveResponse =
        api.requestAs("POST", "calls/$callId/leave", jsonBody = "{}")

    /** The roster. @username only — see [CallRosterEntry.displayName]. */
    suspend fun participants(callId: String): CallParticipantsResponse =
        api.requestAs("GET", "calls/$callId/participants")

    /** Single non-defaulted field — see the serialization note above. */
    @Serializable
    private data class EscalateBody(val invitee_user_id: String)
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// CallKeyCourier — §3.3 / §3.8: the per-call secret, over the ratchet, pairwise
// ─────────────────────────────────────────────────────────────────────────────────────────────

/**
 * The envelope carried inside a `call_key` frame's ciphertext.
 *
 * Everything a key frame needs to say beyond routing lives HERE rather than in cleartext frame
 * fields, so the relay sees two ids and an opaque blob: the rekey [epoch] is authenticated by the
 * ratchet, and a relay (or anyone who reaches it) cannot tell one rekey from another, nor replay
 * an old key against a new epoch without the receiver noticing.
 *
 * @EncodeDefault on every defaulted property: `ApiClient.json` has `encodeDefaults = false`, so
 * `t` and `v` would otherwise vanish from the wire and the receiver would reject its own format.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class CallKeyEnvelope(
    @EncodeDefault val t: String = "voiid:call_key",
    @EncodeDefault val v: Int = 1,
    val call_id: String,
    /** Monotonic per call. A joiner/leaver bumps it; a receiver ignores anything not newer. */
    val epoch: Int,
    /** base64 of the 32-byte `CallSecret.secret`, straight from `newCallSecret()`. */
    val secret: String,
    /**
     * §3.8 capability marker. Absent/false on an old peer, which is the whole point of
     * version negotiation: an old client simply never sends one and both sides fall back to
     * today's DTLS-only 1:1 behaviour rather than failing the call.
     */
    @EncodeDefault val srtp_commit: Boolean = false,
)

/**
 * Mints, distributes, receives and applies per-call secrets.
 *
 * ## Why pairwise and not "just use the group key"
 * The joiner must receive CALL keys, not conversation keys. `e2e-core` has shipped
 * `newCallSecret()` / `srtpKeysFor1to1()` since Phase 4 and **nothing called them**. The inviter
 * mints a fresh secret and sends it to each participant over the Double Ratchet — to the current
 * peer over the existing 1:1 session, to the invitee by establishing sessions from their published
 * prekey bundles. **Establishing a ratchet session creates no conversation row**, which is exactly
 * why this is the mechanism that satisfies the structural rule at the top of this file.
 *
 * ## Not the durable message path
 * A call key is worthless in ten seconds and must never become a row in `messages` — it rides the
 * ephemeral `call_key` relay frame instead. It reuses [ChatEngine.encryptBroadcast] /
 * [ChatEngine.decryptBroadcast] purely for their hard-won per-device session correctness (one
 * prekey fetch per user, glare tolerance, append-never-overwrite on accept); reimplementing that
 * would produce undecryptable keys and a call nobody can join.
 */
class CallKeyCourier(context: Context) {

    private val appContext = context.applicationContext
    private val engine = ChatEngine.get(appContext)
    private val e2e = E2EManager.get(appContext)

    /**
     * Mint a fresh secret for [callId] at [epoch] and fan it out to [recipientUserIds}, one
     * ratchet ciphertext per recipient DEVICE, each in its own `call_key` frame.
     *
     * Returns the secret so the minter can apply it locally — it is never round-tripped through
     * the relay to itself.
     *
     * BEST EFFORT PER RECIPIENT, deliberately: a participant whose devices have no published
     * prekeys is logged and skipped rather than failing the whole rekey, because the alternative
     * is that one stale device stops everyone else from re-keying after a leave — which would
     * leave the LEAVER able to decrypt the media they were just removed from.
     */
    suspend fun mintAndDistribute(callId: String, epoch: Int, recipientUserIds: List<String>): String {
        val secret = uniffi.voiid.newCallSecret().secret
        distribute(callId, epoch, secret, recipientUserIds)
        return secret
    }

    /** Re-fan an ALREADY MINTED secret (a late joiner catching up on the current epoch). */
    suspend fun distribute(callId: String, epoch: Int, secret: String, recipientUserIds: List<String>) {
        val myId = TokenStore.get(appContext).userId
        val envelope = CallKeyEnvelope(
            call_id = callId, epoch = epoch, secret = secret, srtp_commit = true,
        )
        val plaintext = ApiClient.json
            .encodeToString(CallKeyEnvelope.serializer(), envelope)
            .encodeToByteArray()
        val ws = WebSocketClient.get(appContext)
        val senderDeviceId = e2e.deviceId

        for (uid in recipientUserIds.distinct()) {
            if (uid.isBlank() || uid == myId) continue     // never key ourselves over the wire
            // ONE ENCRYPT CALL PER RECIPIENT USER, not per audience: the broadcast helper returns
            // only (device_id, ciphertext), so batching several users into one call would lose
            // which device belongs to whom — and every frame needs a `to_user_id`.
            // getOrNull + a null check rather than getOrElse { … continue }: `continue` from
            // inside an inline lambda is still an experimental Kotlin feature, and one skipped
            // recipient must not need a compiler flag to express.
            val attempt = runCatching {
                engine.encryptBroadcast(plaintext, listOf(uid), includeOwnDevices = false)
            }
            attempt.exceptionOrNull()?.let {
                Log.w("VOIID", "call key: fan-out failed for a participant — they cannot join keyed", it)
            }
            val copies = attempt.getOrNull() ?: continue
            if (copies.isEmpty()) {
                Log.w("VOIID", "call key: no deliverable device for a participant (no prekeys)")
                continue
            }
            for (c in copies) {
                ws.sendCallKey(
                    toUserId = uid,
                    callId = callId,
                    deviceId = c.recipientDeviceId,
                    senderDeviceId = senderDeviceId,
                    ciphertextB64 = c.ciphertext,
                )
            }
        }
    }

    /**
     * Open an inbound `call_key` frame addressed to THIS device.
     *
     * Returns null — and says why at warn level, never with the ciphertext — for anything that
     * is not a well-formed key for [expectedCallId]. A null is always safe: the caller refuses to
     * join unkeyed, exactly as the group clients already do.
     */
    suspend fun open(frame: ConferenceRelay.Frame, expectedCallId: String): CallKeyEnvelope? {
        val ct = frame.ciphertextB64 ?: return null
        if (frame.callId != expectedCallId) return null
        // Not ours: a user's devices share one Redis channel, so every device sees every copy.
        val mine = e2e.deviceId
        if (frame.deviceId != null && mine != null && frame.deviceId != mine) return null

        val plain = runCatching { engine.decryptBroadcast(ct, frame.fromUserId, frame.senderDeviceId) }
            .getOrElse {
                Log.w("VOIID", "call key: decrypt threw for call=$expectedCallId", it)
                null
            } ?: run {
                Log.w("VOIID", "call key: undecryptable for call=$expectedCallId — refusing to join unkeyed")
                return null
            }

        val env = runCatching { ApiClient.json.decodeFromString(CallKeyEnvelope.serializer(), plain) }
            .getOrNull()
        if (env == null || env.t != "voiid:call_key" || env.call_id != expectedCallId) {
            Log.w("VOIID", "call key: envelope rejected for call=$expectedCallId")
            return null
        }
        return env
    }

    companion object {
        /**
         * The LiveKit shared-key string for a call secret: `base64(masterKey ‖ masterSalt)`.
         *
         * EXACTLY the format group calls already use ([GroupEngine.callKey]), for the same
         * reason: LiveKit's `KeyProvider.setSharedKey` takes a String and converts it with
         * `toByteArray(UTF_8)` before its own HKDF, and raw key bytes are not valid UTF-8 —
         * encoding them directly is lossy and can converge different inputs onto the same key.
         * Base64 round-trips through UTF-8 unchanged and preserves the full entropy. This is an
         * ENCODING, not a weakening.
         *
         * Returns null if `e2e-core` refuses the secret (malformed base64), which the caller must
         * treat as "no key" and therefore "do not join".
         */
        fun liveKitSharedKey(secret: String): String? = runCatching {
            val keys = uniffi.voiid.srtpKeysFor1to1(uniffi.voiid.CallSecret(secret))
            Base64.encodeToString(keys.masterKey + keys.masterSalt, Base64.NO_WRAP)
        }.getOrElse {
            Log.e("VOIID", "call key: SRTP derivation failed", it)
            null
        }

        /**
         * §3.8 — the key-commitment value for a plain 1:1 call.
         *
         * WHAT THIS DEFENDS AGAINST. 1:1 media today is trusted solely on the DTLS-SRTP
         * fingerprints carried in server-relayed SDP; the engine's own comments admit a colluding
         * server could substitute both fingerprints and sit in the middle. libwebrtc's public
         * Android API gives us no way to inject externally-derived SRTP keys, so we do the other
         * half of what §3.8 allows: bind the DTLS fingerprints to a secret the server has never
         * seen.
         *
         * Both sides compute this over the SAME inputs — the SRTP key derived from the ratcheted
         * call secret, plus the two fingerprints in a canonical (sorted) order so offerer and
         * answerer agree — and compare. A server that substitutes fingerprints necessarily shows
         * each side a different pair, so the two commitments cannot match; and it cannot forge a
         * matching one, because it never had the secret.
         *
         * Returns null on any malformed input, which the caller must treat as "unverified" —
         * never as "verified".
         */
        fun srtpCommitment(secret: String, fingerprintA: String?, fingerprintB: String?): String? {
            val a = fingerprintA?.trim()?.lowercase().orEmpty()
            val b = fingerprintB?.trim()?.lowercase().orEmpty()
            if (a.isEmpty() || b.isEmpty()) return null
            val ordered = listOf(a, b).sorted()
            return runCatching {
                val keys = uniffi.voiid.srtpKeysFor1to1(uniffi.voiid.CallSecret(secret))
                val mac = javax.crypto.Mac.getInstance("HmacSHA256")
                mac.init(javax.crypto.spec.SecretKeySpec(keys.masterKey + keys.masterSalt, "HmacSHA256"))
                mac.update("voiid-call-commit-v1".toByteArray())
                for (fp in ordered) {
                    mac.update(fp.toByteArray())
                    mac.update(0)      // length-unambiguous separator; two fingerprints can never
                                       // be reparsed as one concatenated string
                }
                Base64.encodeToString(mac.doFinal(), Base64.NO_WRAP)
            }.getOrNull()
        }

        /**
         * The DTLS fingerprint out of an SDP blob (`a=fingerprint:sha-256 AB:CD:…`).
         *
         * SDP is otherwise treated as opaque everywhere in this codebase and stays that way: this
         * reads ONE attribute, which is public key-agreement material already visible to the
         * relay, and never the media lines.
         */
        fun dtlsFingerprint(sdp: String?): String? = sdp
            ?.lineSequence()
            ?.firstOrNull { it.startsWith("a=fingerprint:") }
            ?.removePrefix("a=fingerprint:")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }
}
