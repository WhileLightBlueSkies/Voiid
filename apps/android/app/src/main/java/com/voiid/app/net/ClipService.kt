package com.voiid.app.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * Clips API transport (mirrors iOS `ClipService.swift`).
 *
 * NOTE — clips are NOT end-to-end encrypted, unlike everything [StoryService] touches.
 * They are public broadcast content: the media is PLAINTEXT in R2 and the server
 * attributes view/like/comment counts. That is a deliberate, scoped exception (a
 * broadcast has no fixed recipient set to encrypt to); see docs/CLIPS.md §0 and the
 * header of backend/api/src/routes/clips.ts. Nothing here shares a code path with
 * messages, calls, locations or moments, all of which remain E2EE.
 */
class ClipService(private val tokens: TokenStore) {
    private val api = ApiClient(tokens)

    // Longer timeouts for the direct R2 transfers — a clip can be 100 MB.
    private val blobClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(300, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .build()

    // ── DTOs ──────────────────────────────────────────────────────────────────────

    @Serializable private data class PresignUploadBody(val mime: String)
    @Serializable data class RenditionTarget(val key: String, val upload_url: String)
    @Serializable data class RenditionTargets(
        val sd: RenditionTarget,
        val hd: RenditionTarget,
        val fhd: RenditionTarget,
    )
    @Serializable data class PresignUploadResp(
        val key: String,
        val upload_url: String,
        val thumb_key: String,
        val thumb_upload_url: String,
        /** Nullable so a client talking to a pre-021 backend still uploads the baseline. */
        val renditions: RenditionTargets? = null,
    )

    @Serializable private data class PostClipBody(
        val clip_id: String,
        val r2_key: String,
        val thumb_r2_key: String,
        val caption: String? = null,
        val duration_ms: Int? = null,
        val width: Int? = null,
        val height: Int? = null,
        val byte_size: Long? = null,
        val r2_key_sd: String? = null,
        val r2_key_hd: String? = null,
        val r2_key_fhd: String? = null,
        val byte_size_sd: Long? = null,
        val byte_size_hd: Long? = null,
        val byte_size_fhd: Long? = null,
        val cover_source: String = "frame",
    )
    @Serializable data class PostClipResp(val clip_id: String, val created_at: String)

    /** A clip row as the feed returns it. `thumb_url` is presigned; the VIDEO url is not. */
    @Serializable data class ClipRow(
        val id: String,
        val author_id: String,
        val r2_key: String,
        val thumb_r2_key: String,
        val thumb_url: String? = null,
        val caption: String? = null,
        val duration_ms: Int? = null,
        val width: Int? = null,
        val height: Int? = null,
        val byte_size: Long? = null,
        val view_count: Int = 0,
        val like_count: Int = 0,
        val comment_count: Int = 0,
        val created_at: String,
        val author_name: String? = null,
        val author_photo_url: String? = null,
        val liked_by_me: Boolean = false,
        /** Which renditions exist. Defaulted so a pre-021 backend still decodes. */
        val has_sd: Boolean = false,
        val has_hd: Boolean = false,
        val has_fhd: Boolean = false,
        val byte_size_sd: Long? = null,
        val byte_size_hd: Long? = null,
        val byte_size_fhd: Long? = null,
        val cover_source: String? = null,
    )
    @Serializable data class FeedResp(val clips: List<ClipRow>, val next_cursor: String? = null)

    @Serializable data class PlaybackResp(
        val playback_url: String,
        /**
         * Which rendition the server ACTUALLY served — the requested quality is a
         * request, not a guarantee (a 480p source has no 1080p rendition).
         */
        val quality: String? = null,
        val byte_size: Long? = null,
        /**
         * Seconds this presigned URL stays valid, so the pager can cache it instead of
         * minting a fresh one on every swipe. Nullable with a default because this is a
         * DECODE of a server response — an older server simply omits it. (The
         * `encodeDefaults = false` hazard that has bitten this codebase repeatedly applies
         * to request bodies we SEND, not to responses we receive.)
         */
        val expires_in: Long? = null,
    )
    @Serializable private data class ViewResp(val view_count: Int)
    @Serializable data class LikeResp(val liked: Boolean, val like_count: Int)

    @Serializable data class CommentRow(
        val id: String,
        val clip_id: String,
        val author_id: String,
        val text: String,
        val created_at: String,
        val author_name: String? = null,
        val author_photo_url: String? = null,
    )
    @Serializable data class CommentsResp(
        val comments: List<CommentRow>,
        val next_cursor: String? = null,
    )
    @Serializable private data class PostCommentBody(val text: String)
    @Serializable private data class PostCommentResp(val comment: CommentRow)

    // ── Endpoints ─────────────────────────────────────────────────────────────────

    /** Presigned PUTs for BOTH the video and its cover frame, in one round-trip. */
    suspend fun presignUpload(mime: String = "video/mp4"): PresignUploadResp =
        api.requestAs(
            "POST", "clips/presign-upload",
            jsonBody = ApiClient.json.encodeToString(
                PresignUploadBody.serializer(), PresignUploadBody(mime)
            )
        )

    /** Raw PUT straight to R2. Bytes never transit the Voiid API. */
    /**
     * PUT a FILE straight to R2, streamed.
     *
     * Takes a [File], never a ByteArray: a clip is capped at 100 MB and the ladder uploads up
     * to four of them, so `file.readBytes()` allocated the whole video as one JVM array and
     * OOM-killed the process on most devices — that was the "upload does nothing, app crashes"
     * bug. `asRequestBody` streams from disk with a fixed buffer, so peak heap is a few KB
     * regardless of clip size.
     */
    suspend fun uploadBlob(url: String, file: File, contentType: String) =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(url)
                .put(file.asRequestBody(contentType.toMediaType()))
                .build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "clip upload failed (${it.code})")
            }
        }

    /**
     * Small in-memory payloads only — the cover JPEG, which is bounded to ~1080px q0.8 (tens of
     * KB). Anything video-sized must use the [File] overload above.
     */
    suspend fun uploadBlob(url: String, bytes: ByteArray, contentType: String) =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(url)
                .put(bytes.toRequestBody(contentType.toMediaType()))
                .build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "clip upload failed (${it.code})")
            }
        }

    /**
     * Create the row. Called only AFTER both R2 PUTs succeed — the server has no
     * 'uploading' state by design (a client that dies mid-upload must not leave a
     * broken tile in everyone's feed).
     */
    suspend fun postClip(
        clipId: String,
        r2Key: String,
        thumbKey: String,
        caption: String?,
        durationMs: Int?,
        width: Int?,
        height: Int?,
        byteSize: Long?,
        renditionKeys: Map<ClipQuality, String> = emptyMap(),
        renditionSizes: Map<ClipQuality, Long> = emptyMap(),
        coverSource: String = "frame",
    ): PostClipResp = api.requestAs(
        "POST", "clips",
        jsonBody = ApiClient.json.encodeToString(
            PostClipBody.serializer(),
            PostClipBody(
                clipId, r2Key, thumbKey, caption, durationMs, width, height, byteSize,
                r2_key_sd = renditionKeys[ClipQuality.SD],
                r2_key_hd = renditionKeys[ClipQuality.HD],
                r2_key_fhd = renditionKeys[ClipQuality.FHD],
                byte_size_sd = renditionSizes[ClipQuality.SD],
                byte_size_hd = renditionSizes[ClipQuality.HD],
                byte_size_fhd = renditionSizes[ClipQuality.FHD],
                cover_source = coverSource,
            )
        )
    )

    /**
     * Explore grid, newest-first. [cursor] is the opaque keyset cursor from the previous
     * page — never an offset (an offset-paged infinite grid duplicates and skips tiles
     * whenever somebody posts mid-scroll).
     */
    suspend fun feed(cursor: String? = null, limit: Int = 30): FeedResp {
        val q = buildString {
            append("clips/feed?limit=$limit")
            cursor?.let { append("&cursor=${URLEncoder.encode(it, "UTF-8")}") }
        }
        return api.requestAs("GET", q)
    }

    suspend fun mine(cursor: String? = null, limit: Int = 30): FeedResp {
        val q = buildString {
            append("clips/mine?limit=$limit")
            cursor?.let { append("&cursor=${URLEncoder.encode(it, "UTF-8")}") }
        }
        return api.requestAs("GET", q)
    }

    /**
     * Short-lived playback URL, minted on demand. Deliberately not returned by the feed:
     * a 30-tile page would mint 30 video URLs that mostly go unused.
     */
    suspend fun playback(clipId: String, quality: ClipQuality = ClipQuality.HD): PlaybackResp =
        api.requestAs("GET", "clips/$clipId/playback?quality=${quality.wire}")

    /**
     * Idempotent per (clip, user), server-side. Call after a >=2s watch — NOT on tile
     * appearance, or scroll-past impressions inflate every count in the grid.
     */
    suspend fun markViewed(clipId: String): Int {
        val resp: ViewResp = api.requestAs("POST", "clips/$clipId/view", jsonBody = "{}")
        return resp.view_count
    }

    /** Returns the AUTHORITATIVE count — the caller overwrites its optimistic number. */
    suspend fun like(clipId: String): LikeResp =
        api.requestAs("POST", "clips/$clipId/like", jsonBody = "{}")

    suspend fun unlike(clipId: String): LikeResp =
        api.requestAs("DELETE", "clips/$clipId/like")

    suspend fun comments(clipId: String, cursor: String? = null, limit: Int = 50): CommentsResp {
        val q = buildString {
            append("clips/$clipId/comments?limit=$limit")
            cursor?.let { append("&cursor=${URLEncoder.encode(it, "UTF-8")}") }
        }
        return api.requestAs("GET", q)
    }

    suspend fun addComment(clipId: String, text: String): CommentRow {
        val resp: PostCommentResp = api.requestAs(
            "POST", "clips/$clipId/comments",
            jsonBody = ApiClient.json.encodeToString(
                PostCommentBody.serializer(), PostCommentBody(text)
            )
        )
        return resp.comment
    }

    suspend fun deleteComment(clipId: String, commentId: String) {
        api.request("DELETE", "clips/$clipId/comments/$commentId")
    }

    // ── Editing (caption + cover only; the video itself is immutable) ──────────────

    @Serializable data class PresignThumbResp(
        val thumb_key: String,
        val thumb_upload_url: String,
    )

    /**
     * A fresh cover key for an existing clip. The server mints a NEW uuid rather than
     * reusing the old one, so caches still holding the previous cover are invalidated.
     */
    suspend fun presignThumb(clipId: String): PresignThumbResp =
        api.requestAs("POST", "clips/$clipId/presign-thumb", jsonBody = "{}")

    @Serializable private data class UpdateClipResp(val clip: ClipRow)

    /**
     * Caption and/or cover, independently applied.
     *
     * The body is built by hand rather than through a @Serializable class because
     * ApiClient's Json sets `explicitNulls = false`, which DROPS a null field instead of
     * emitting `null` — so a serialized "clear the caption" would arrive as "change
     * nothing" and the clear would silently never happen.
     */
    suspend fun updateClip(
        clipId: String,
        caption: String? = null,
        clearCaption: Boolean = false,
        thumbKey: String? = null,
        coverSource: String? = null,
    ): ClipRow {
        val fields = buildList {
            when {
                clearCaption -> add("\"caption\":null")
                caption != null -> add("\"caption\":${JsonPrimitive(caption)}")
            }
            if (thumbKey != null) add("\"thumb_r2_key\":${JsonPrimitive(thumbKey)}")
            if (coverSource != null) add("\"cover_source\":${JsonPrimitive(coverSource)}")
        }
        val resp: UpdateClipResp = api.requestAs(
            "PATCH", "clips/$clipId",
            jsonBody = fields.joinToString(",", prefix = "{", postfix = "}"),
        )
        return resp.clip
    }

    suspend fun deleteClip(clipId: String) {
        api.request("DELETE", "clips/$clipId")
    }
}
