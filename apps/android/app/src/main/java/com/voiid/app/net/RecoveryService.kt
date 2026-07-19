package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable
import uniffi.voiid.PinWrappedSecret

/**
 * PIN-wrapped master-secret transport (recovery key). Mirrors the backend contract:
 *   - PUT  /recovery/key            store the PIN-wrapped secret ({version,salt,nonce,ciphertext})
 *   - GET  /recovery/key            fetch it; 404 = never set, 429 = locked (Retry-After)
 *   - POST /recovery/attempt-result report every PIN unwrap attempt so the server can
 *                                    lock the key after 10 consecutive failures.
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

    /** Upload the PIN-wrapped master secret (setup + change-PIN). */
    suspend fun putKey(wrapped: PinWrappedSecret) {
        val body = ApiClient.json.encodeToString(WrappedKeyDto.serializer(), WrappedKeyDto.from(wrapped))
        api.request("PUT", "recovery/key", jsonBody = body)
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
