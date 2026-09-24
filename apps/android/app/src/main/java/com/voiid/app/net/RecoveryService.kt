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

    @kotlinx.serialization.Serializable private data class StatusResp(val has_pin_wrap: Boolean = false)

    /** Whether a LEGACY PIN wrap exists. Not a fetch: the server answers without handing
     *  the wrap out, so asking never counts toward the fetch limit. New backups never make
     *  one (S04 — a short PIN wrapped key can be guessed offline by whoever obtains it). */
    suspend fun hasPinWrap(): Boolean =
        ApiClient.json.decodeFromString(StatusResp.serializer(), api.request("GET", "recovery/status")).has_pin_wrap

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
