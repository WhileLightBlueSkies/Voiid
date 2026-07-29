package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * GIF search through our own /gifs proxy (Tenor behind it), plus the download step that turns
 * a chosen GIF into bytes for the ordinary E2EE media path. Mirrors iOS `GifService.swift`.
 *
 * THE DOWNLOAD IS THE POINT. Every other messenger sends a provider URL and lets each
 * recipient fetch it — which tells Tenor/GIPHY who received what and when, and breaks the GIF
 * permanently if the provider deletes it. Fetching once here and sending ciphertext costs us
 * bandwidth and buys both properties back.
 *
 * Search goes through OUR backend so the API key never ships in the APK (where anyone can
 * extract it) and users' searches don't reach Google carrying their IP.
 */
class GifService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    // Separate client: GIF blobs are larger than JSON and deserve their own timeouts rather
    // than stretching the API client's.
    private val blobClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    @Serializable
    data class Gif(
        val id: String,
        /** Full-size — downloaded, encrypted, sent. */
        val url: String,
        /** Small looping preview for the picker grid. Never sent to anyone. */
        val preview: String,
        val width: Int = 0,
        val height: Int = 0,
        val description: String = "",
    )

    @Serializable
    data class SearchResult(
        val gifs: List<Gif> = emptyList(),
        /** False when the server has no provider key, so the UI can say so instead of spinning. */
        val configured: Boolean = true,
    )

    /** Search, or trending when [query] is null or blank. */
    suspend fun search(query: String?): SearchResult = runCatching {
        val path = if (query.isNullOrBlank()) "gifs/trending"
                   else "gifs/search?q=${java.net.URLEncoder.encode(query, "UTF-8")}"
        api.requestAs<SearchResult>("GET", path)
    // A failed GIF search must never surface as an error state — the composer stays usable
    // and the grid is simply empty.
    }.getOrDefault(SearchResult())

    /**
     * Fetch the GIF bytes so they can be encrypted and sent as normal media.
     *
     * Capped at 8 MB: a GIF is decoded fully into memory to display, and Tenor occasionally
     * serves multi-megabyte files that would spike a low-end phone. Anything larger is dropped
     * rather than risking an OOM mid-send.
     */
    suspend fun download(url: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching {
            blobClient.newCall(Request.Builder().url(url).get().build()).execute().use { res ->
                if (!res.isSuccessful) return@use null
                val bytes = res.body?.bytes() ?: return@use null
                if (bytes.size > 8 * 1024 * 1024) {
                    android.util.Log.w("VOIID", "gif too large (${bytes.size} bytes) — skipped")
                    return@use null
                }
                bytes
            }
        }.getOrNull()
    }
}
