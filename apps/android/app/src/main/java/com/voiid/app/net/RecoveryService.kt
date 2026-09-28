package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable
import uniffi.voiid.PinWrappedSecret

/**
 * PIN-wrapped master-secret transport (recovery key). Mirrors the backend contract:
 *   - PUT  /recovery/key            store the PIN-wrapped secret ({version,salt,nonce,ciphertext})
 *   - GET  /recovery/key            fetch it; 404 = never set, 429 = locked (Retry-After)
 *   - POST /recovery/attempt-result report each PIN unwrap attempt
 *
 * ── WHAT THE ATTEMPT REPORT IS, AND IS NOT (S04) ──────────────────────────────────
 * This comment used to say the report lets the server "lock the key after 10 consecutive
 * failures", as though that were a security boundary. It is not, and the backend retracted
 * the same claim in `routes/recovery.ts` — read the threat model there first.
 *
 * The counter moves only when a client chooses to POST `success:false`. An attacker holding
 * the wrap can fetch once and guess OFFLINE forever, report nothing, or POST `success:true`
 * to clear an active lock. A control the attacker can decline to trigger and can reset at
 * will is abuse telemetry about HONEST clients, not protection. Keep reporting — the
 * telemetry is worth having — but never present the 429 to the user as a guarantee.
 *
 * What actually defends the secret is the BIP39 phrase (high entropy, never sent) and,
 * weakly, Argon2id raising the cost per guess on a ~20-bit PIN. Replacing this with a real
 * boundary is S04, and it needs a cryptographic reviewer.
 *
 * `version` travels as a JSON number; the FFI [PinWrappedSecret] carries it as a UByte,
 * so we convert on the boundary.
 */
class RecoveryService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    @Serializable
    data class WrappedKeyDto(
        val version: Int,
        val salt: String,
        val nonce: String,
        val ciphertext: String,
    ) {
        fun toFfi() = PinWrappedSecret(version.toUByte(), salt, nonce, ciphertext)
        companion object {
            fun from(w: PinWrappedSecret) = WrappedKeyDto(w.version.toInt(), w.salt, w.nonce, w.ciphertext)
        }
    }

    @Serializable private data class GetKeyResp(val wrapped_key: WrappedKeyDto)
    @Serializable private data class AttemptBody(val success: Boolean)

    /** Outcome of GET /recovery/key. */
    sealed class KeyResult {
        data class Found(val wrapped: PinWrappedSecret) : KeyResult()
        object NotSet : KeyResult()                                   // 404
        data class Locked(val retryAfterSeconds: Long?) : KeyResult() // 429
    }

    /** The server's view of this account's V PIN (GET /recovery/status → `vpin`). */
    @Serializable
    data class VPinStatus(
        val auth_salt: String,
        val max_attempts: Int = 5,
        val attempts_left: Int = 5,
        val locked_until: String? = null,
        val retry_after: Long? = null,
    ) {
        val isLocked: Boolean get() = (retry_after ?: 0) > 0
    }

    @Serializable private data class StatusResp(val has_pin_wrap: Boolean = false, val vpin: VPinStatus? = null)

    /** Both PIN schemes in one call: a legacy wrap, and/or a V PIN with its salt and lock. */
    data class PinStatus(val legacy: Boolean, val vpin: VPinStatus?)

    suspend fun status(): PinStatus {
        val r = ApiClient.json.decodeFromString(StatusResp.serializer(), api.request("GET", "recovery/status"))
        return PinStatus(r.has_pin_wrap, r.vpin)
    }

    /** Whether a LEGACY PIN wrap exists. Not a fetch: the server answers without handing
     *  the wrap out, so asking never counts toward the fetch limit. New backups never make
     *  one (S04 — a short PIN wrapped key can be guessed offline by whoever obtains it). */
    suspend fun hasPinWrap(): Boolean = status().legacy

    // ── V PIN ─────────────────────────────────────────────────────────────────────────
    // The server checks a PROOF of the PIN (never the PIN — see [VPinProof]) and releases
    // the locked key only when it is right, counting every wrong try: 5 wrong, locked 24h.
    // A real limit, unlike the client-reported counter above. backend/api/src/vpin.ts.

    @Serializable private data class SetPinBody(val wrapped_key: WrappedKeyDto, val auth_salt: String, val proof: String)
    @Serializable private data class UnlockBody(val proof: String)
    @Serializable private data class VPinError(
        val error: String? = null,
        val code: String? = null,
        val attempts_left: Int? = null,
        val locked_until: String? = null,
    )

    /** What POST /recovery/pin/unlock answered. */
    sealed class UnlockResult {
        data class Released(val wrapped: PinWrappedSecret) : UnlockResult()
        data class Wrong(val attemptsLeft: Int) : UnlockResult()
        data class Locked(val until: String?) : UnlockResult()
        object NotSet : UnlockResult()
        /** The right PIN, but the server can no longer open what it stored — phrase only. */
        object Unreadable : UnlockResult()
        object Unavailable : UnlockResult()
    }

    /** Store (or replace) the V PIN. Throws [ApiError] on failure; 503 means the server
     *  has no key to protect a PIN with and refused rather than store it weakly. */
    suspend fun setVPin(wrapped: PinWrappedSecret, authSalt: ByteArray, proof: ByteArray) {
        val body = ApiClient.json.encodeToString(SetPinBody.serializer(), SetPinBody(
            WrappedKeyDto.from(wrapped), b64(authSalt), b64(proof)))
        val resp = api.requestRaw("PUT", "recovery/pin", body.toByteArray(), "application/json")
        if (!resp.isSuccessful) {
            val err = parseError(resp)
            throw ApiError.Http(resp.code, err?.error ?: "Couldn't save your V PIN (${resp.code}).")
        }
    }

    suspend fun unlockVPin(proof: ByteArray): UnlockResult {
        val body = ApiClient.json.encodeToString(UnlockBody.serializer(), UnlockBody(b64(proof)))
        val resp = api.requestRaw("POST", "recovery/pin/unlock", body.toByteArray(), "application/json")
        val err = if (resp.isSuccessful) null else parseError(resp)
        return when {
            resp.isSuccessful -> UnlockResult.Released(
                ApiClient.json.decodeFromString(GetKeyResp.serializer(), String(resp.body)).wrapped_key.toFfi())
            resp.code == 401 -> UnlockResult.Wrong(err?.attempts_left ?: 0)
            resp.code == 429 && err?.code == "vpin_locked" -> UnlockResult.Locked(err.locked_until)
            resp.code == 429 -> UnlockResult.Locked(null)
            resp.code == 404 -> UnlockResult.NotSet
            resp.code == 409 && err?.code == "vpin_unreadable" -> UnlockResult.Unreadable
            resp.code == 503 -> UnlockResult.Unavailable
            else -> throw ApiError.Http(resp.code, err?.error ?: "Couldn't check your V PIN (${resp.code}).")
        }
    }

    private fun parseError(resp: RawResponse): VPinError? =
        runCatching { ApiClient.json.decodeFromString(VPinError.serializer(), String(resp.body)) }.getOrNull()

    private fun b64(bytes: ByteArray): String = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    /** Delete the legacy PIN wrap, once the person has saved their recovery phrase. */
    suspend fun deleteKey() {
        api.request("DELETE", "recovery/key")
    }

    /** Fetch the PIN-wrapped master secret. Distinguishes never-set (404) and
     *  locked-after-too-many-failures (429 + Retry-After). */
    suspend fun getKey(): KeyResult {
        val resp = api.requestRaw("GET", "recovery/key")
        return when {
            resp.code == 404 -> KeyResult.NotSet
            resp.code == 429 -> KeyResult.Locked(resp.retryAfterSeconds)
            resp.isSuccessful -> {
                val parsed = ApiClient.json.decodeFromString(GetKeyResp.serializer(), String(resp.body))
                KeyResult.Found(parsed.wrapped_key.toFfi())
            }
            else -> throw ApiError.Http(resp.code, "Couldn't fetch recovery key (${resp.code}).")
        }
    }

    /** Report a PIN unwrap attempt so the server can track/lock consecutive failures. */
    suspend fun reportAttempt(success: Boolean) {
        val body = ApiClient.json.encodeToString(AttemptBody.serializer(), AttemptBody(success))
        runCatching { api.request("POST", "recovery/attempt-result", jsonBody = body) }
    }
}
