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
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /** Perform a request and return the raw JSON body string (caller deserializes). */
    suspend fun request(
        method: String,
        path: String,
        jsonBody: String? = null,
        auth: Boolean = true,
    ): String = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(ApiConfig.baseUrl.trimEnd('/') + "/" + path.trimStart('/'))

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
            if (!it.isSuccessful) {
                if (it.code == 401) tokens.clear()
                val msg = runCatching { json.decodeFromString<ErrorBody>(text).error }
                    .getOrNull() ?: "Request failed (${it.code})."
                throw ApiError.Http(it.code, msg)
            }
            text
        }
    }

    /** Convenience: deserialize the response into [T]. */
    suspend inline fun <reified T> requestAs(
        method: String,
        path: String,
        jsonBody: String? = null,
        auth: Boolean = true,
    ): T = json.decodeFromString(request(method, path, jsonBody, auth))
}

@kotlinx.serialization.Serializable
private data class ErrorBody(val error: String = "error")
