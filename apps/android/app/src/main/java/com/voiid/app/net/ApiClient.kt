package com.voiid.app.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Thin OkHttp + kotlinx.serialization JSON client for the VOIID backend.
 * Mirrors the iOS APIClient. Injects the bearer JWT, decodes JSON, surfaces
 * clean errors. See docs/API_CONTRACT.md.
 */
object ApiConfig {
    // Hosted DEV backend (Vultr + Caddy TLS). WebSocket is proxied on the /ws
    // path of the same host. For local-only work, swap to http://10.0.2.2:4000
    // + ws://10.0.2.2:4001 (emulator -> host).
    @Volatile var baseUrl: String = "https://api-dev.voiid.app"
    @Volatile var wsUrl: String = "wss://api-dev.voiid.app/ws"
    // API version this build talks (path-versioned: /v1/...). Bumped per major contract.
    @Volatile var apiVersion: String = "v1"
    // This build's app version (for force-update gating).
    val appVersion: String get() = com.voiid.app.BuildConfig.VERSION_NAME
}

/** Global signal raised when the backend returns 426 (build below minSupported).
 *  The root composable observes [required] and shows a blocking update screen. */
object UpdateGate {
    val required = kotlinx.coroutines.flow.MutableStateFlow(false)
    @Volatile var storeUrl: String? = null
    fun trigger(url: String?) { storeUrl = url; required.value = true }
}

sealed class ApiError(message: String) : Exception(message) {
    class Http(val status: Int, message: String) : ApiError(message)
    class Transport(cause: Throwable) : ApiError(cause.message ?: "Network error")
    object NotAuthenticated : ApiError("Please sign in again.")
}

class ApiClient(
    private val tokens: TokenStore,
    private val http: OkHttpClient = defaultClient,
) {
    companion object {
        // coerceInputValues: an explicit `"field": null` on the wire for a property that has
        // a default falls back to that default instead of throwing. iOS's JSONEncoder emits
        // explicit nulls for nil Optionals, so without this every iOS→Android envelope with
        // an absent caption/allowsReplies threw and the item was dropped silently.
        val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            coerceInputValues = true
        }
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
        // Longer timeouts for raw blob transfers (backup uploads up to 50 MiB).
        private val rawClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .build()
    }

    /** Perform a request and return the raw JSON body string (caller deserializes). */
    suspend fun request(
        method: String,
        path: String,
        jsonBody: String? = null,
        auth: Boolean = true,
        versioned: Boolean = true,
    ): String = withContext(Dispatchers.IO) {
        // Versioned calls go under /v1; pass versioned=false for /config etc.
        val prefix = if (versioned) ApiConfig.apiVersion + "/" else ""
        val builder = Request.Builder()
            .url(ApiConfig.baseUrl.trimEnd('/') + "/" + prefix + path.trimStart('/'))
            .header("X-Voiid-Platform", "android")
            .header("X-Voiid-App-Version", ApiConfig.appVersion)
            .header("X-Voiid-Api-Version", ApiConfig.apiVersion)

        if (auth) {
            val token = tokens.jwt ?: throw ApiError.NotAuthenticated
            builder.header("Authorization", "Bearer $token")
        }
        val reqBody = jsonBody?.toRequestBody(JSON_MEDIA)
        builder.method(method, reqBody ?: if (method == "GET") null else "".toRequestBody(JSON_MEDIA))

        val resp = try {
            http.newCall(builder.build()).execute()
        } catch (e: Exception) {
            throw ApiError.Transport(e)
        }
        resp.use {
            val text = it.body?.string() ?: ""
            // 426 → this build is below minSupportedVersion; raise the global gate.
            if (it.code == 426) {
                val url = runCatching { json.decodeFromString<UpdateBody>(text).update_url }.getOrNull()
                UpdateGate.trigger(url)
                throw ApiError.Http(426, "update required")
            }
            if (!it.isSuccessful) {
                if (it.code == 401) tokens.clear()
                // Log the WHOLE body on a server error. Only the `error` field survives into the
                // exception, so any diagnostic the server adds alongside it (a pg code, a hint)
                // was being thrown away at exactly the moment it was needed. 5xx only: a 401 body
                // is noise, and this must never log message content.
                if (it.code >= 500) {
                    android.util.Log.w("ApiClient", "HTTP ${it.code} on $path: ${text.take(600)}")
                }
                val msg = runCatching { json.decodeFromString<ErrorBody>(text).error }
                    .getOrNull() ?: "Request failed (${it.code})."
                throw ApiError.Http(it.code, msg)
            }
            text
        }
    }

    /**
     * Raw request that does NOT throw on HTTP status — the caller inspects
     * [RawResponse.code] + headers itself (needed for 404-is-a-value on GET /backup
     * and 429 + Retry-After on GET /recovery/key). Attaches the same platform + bearer
     * headers as [request]. Body may be arbitrary bytes (e.g. the octet-stream backup
     * blob). Only transport failures throw ([ApiError.Transport]).
     */
    suspend fun requestRaw(
        method: String,
        path: String,
        body: ByteArray? = null,
        contentType: String = "application/octet-stream",
        auth: Boolean = true,
        versioned: Boolean = true,
    ): RawResponse = withContext(Dispatchers.IO) {
        val prefix = if (versioned) ApiConfig.apiVersion + "/" else ""
        val builder = Request.Builder()
            .url(ApiConfig.baseUrl.trimEnd('/') + "/" + prefix + path.trimStart('/'))
            .header("X-Voiid-Platform", "android")
            .header("X-Voiid-App-Version", ApiConfig.appVersion)
            .header("X-Voiid-Api-Version", ApiConfig.apiVersion)
        if (auth) {
            val token = tokens.jwt ?: throw ApiError.NotAuthenticated
            builder.header("Authorization", "Bearer $token")
        }
        val mediaType = contentType.toMediaType()
        val reqBody = body?.toRequestBody(mediaType)
        builder.method(method, reqBody ?: if (method == "GET") null else ByteArray(0).toRequestBody(mediaType))
        val resp = try {
            rawClient.newCall(builder.build()).execute()
        } catch (e: Exception) {
            throw ApiError.Transport(e)
        }
        resp.use {
            if (it.code == 401) tokens.clear()
            RawResponse(it.code, it.header("Retry-After"), it.body?.bytes() ?: ByteArray(0))
        }
    }

    /** Convenience: deserialize the response into [T]. */
    suspend inline fun <reified T> requestAs(
        method: String,
        path: String,
        jsonBody: String? = null,
        auth: Boolean = true,
        versioned: Boolean = true,
    ): T = json.decodeFromString(request(method, path, jsonBody, auth, versioned))
}

/** Non-throwing raw HTTP result (see [ApiClient.requestRaw]). */
data class RawResponse(val code: Int, val retryAfter: String?, val body: ByteArray) {
    val isSuccessful: Boolean get() = code in 200..299
    /** Retry-After parsed as whole seconds, if the server sent a numeric value. */
    val retryAfterSeconds: Long? get() = retryAfter?.trim()?.toLongOrNull()
}

@kotlinx.serialization.Serializable
private data class ErrorBody(val error: String = "error")

@kotlinx.serialization.Serializable
data class UpdateBody(val update_url: String? = null)
