package com.voiid.app.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Stories API transport (mirrors iOS StoryService). Every blob is encrypted ON-DEVICE before it
 * leaves; the server signs short-lived R2 URLs and stores CIPHERTEXT, opaque object keys, and one
 * opaque per-recipient-device key blob. It never sees the media key, the real mime, the caption,
 * the dimensions, or the bytes.
 *
 * The upload/download here deliberately do NOT reuse [MediaService]: stories have their own
 * presign endpoints (`stories/presign-upload`, `stories/presign-download`) so the download can be
 * entitlement-checked (author OR holds a story_keys row) instead of the generic media endpoint's
 * "authenticated AND key starts with media/" — defence in depth, not a guarantee.
 */
class StoryService(private val tokens: TokenStore) {
    private val api = ApiClient(tokens)

    // Longer timeouts for the direct R2 transfers (a story can be a 50 MB video ciphertext).
    private val blobClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()

    // MARK: - DTOs

    @Serializable private data class PresignUploadBody(val mime: String)
    @Serializable private data class PresignUploadResp(val key: String, val upload_url: String)

    @Serializable data class KeyEntry(val recipient_device_id: String, val ciphertext: String)
    @Serializable private data class PostStoryBody(
        val story_id: String,
        val r2_key: String,
        val media_mime: String,
        val byte_size: Long,
        val sender_device_id: String?,
        val keys: List<KeyEntry>,
    )
    @Serializable data class PostStoryResp(
        val story_id: String,
        val created_at: String? = null,
        val expires_at: String? = null,
        val delivered_devices: Int = 0,
    )

    @Serializable data class FeedStory(
        val story_id: String,
        val author_id: String,
        val author_device_id: String? = null,
        val r2_key: String,
        val media_mime: String,
        val byte_size: Long? = null,
        val created_at: String,
        val expires_at: String,
        val ciphertext: String,
    )
    @Serializable private data class FeedResp(val stories: List<FeedStory> = emptyList())

    @Serializable data class MineStory(
        val story_id: String,
        val r2_key: String,
        val media_mime: String,
        val byte_size: Long? = null,
        val created_at: String,
        val expires_at: String,
        val recipient_device_count: Int = 0,
        val delivered_device_count: Int = 0,
    )
    @Serializable private data class MineResp(val stories: List<MineStory> = emptyList())

    @Serializable private data class PresignDownloadBody(val story_id: String)
    @Serializable private data class PresignDownloadResp(val download_url: String)

    @Serializable private data class ReceiptBody(val receipts: List<KeyEntry>)
    @Serializable private data class KeysBody(val keys: List<KeyEntry>)

    @Serializable data class ReceiptRow(
        val id: String,
        val story_id: String,
        val ciphertext: String,
        val created_at: String? = null,
    )
    @Serializable private data class ReceiptsResp(val receipts: List<ReceiptRow> = emptyList())

    // MARK: - Calls

    /** Presign a PUT and push the CIPHERTEXT straight to R2. Returns the opaque object key. The
     *  mime handed to the presigner is the WRAPPER type; the real media type rides in the envelope. */
    suspend fun uploadCiphertext(ciphertext: ByteArray, wrapperMime: String = "application/octet-stream"): String {
        val body = ApiClient.json.encodeToString(PresignUploadBody.serializer(), PresignUploadBody(wrapperMime))
        val presign: PresignUploadResp = api.requestAs("POST", "stories/presign-upload", jsonBody = body)
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(presign.upload_url)
                .put(ciphertext.toRequestBody(wrapperMime.toMediaType()))
                .build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "story upload failed (${it.code})")
            }
        }
        return presign.key
    }

    suspend fun postStory(
        storyId: String, r2Key: String, mediaMime: String, byteSize: Long,
        senderDeviceId: String?, keys: List<KeyEntry>,
    ): PostStoryResp {
        val body = ApiClient.json.encodeToString(
            PostStoryBody.serializer(),
            PostStoryBody(storyId, r2Key, mediaMime, byteSize, senderDeviceId, keys),
        )
        return api.requestAs("POST", "stories", jsonBody = body)
    }

    /** Append keys for devices skipped at post time (no prekey) or newly-registered inside 24h. */
    suspend fun appendKeys(storyId: String, keys: List<KeyEntry>): Int {
        if (keys.isEmpty()) return 0
        val body = ApiClient.json.encodeToString(KeysBody.serializer(), KeysBody(keys))
        val resp: AddedResp = api.requestAs("POST", "stories/$storyId/keys", jsonBody = body)
        return resp.added
    }
    @Serializable private data class AddedResp(val added: Int = 0)

    suspend fun feed(deviceId: String?, includeDelivered: Boolean = false): List<FeedStory> {
        val q = buildString {
            append("stories/feed")
            val params = buildList {
                deviceId?.let { add("device_id=$it") }
                if (includeDelivered) add("include_delivered=1")
            }
            if (params.isNotEmpty()) append("?" + params.joinToString("&"))
        }
        val resp: FeedResp = api.requestAs("GET", q)
        return resp.stories
    }

    suspend fun mine(deviceId: String?): List<MineStory> {
        val q = "stories/mine" + (deviceId?.let { "?device_id=$it" } ?: "")
        val resp: MineResp = api.requestAs("GET", q)
        return resp.stories
    }

    /** Presign a download of a story's ciphertext and fetch it. Throws ApiError.Http on 403/404. */
    suspend fun downloadCiphertext(storyId: String): ByteArray {
        val body = ApiClient.json.encodeToString(PresignDownloadBody.serializer(), PresignDownloadBody(storyId))
        val presign: PresignDownloadResp = api.requestAs("POST", "stories/presign-download", jsonBody = body)
        return withContext(Dispatchers.IO) {
            val req = Request.Builder().url(presign.download_url).get().build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "story download failed (${it.code})")
                it.body?.bytes() ?: ByteArray(0)
            }
        }
    }

    suspend fun deleteStory(storyId: String) {
        api.request("DELETE", "stories/$storyId")
    }

    suspend fun sendReceipt(storyId: String, receipts: List<KeyEntry>): Int {
        if (receipts.isEmpty()) return 0
        val body = ApiClient.json.encodeToString(ReceiptBody.serializer(), ReceiptBody(receipts))
        val resp: AcceptedResp = api.requestAs("POST", "stories/$storyId/receipt", jsonBody = body)
        return resp.accepted
    }
    @Serializable private data class AcceptedResp(val accepted: Int = 0)

    suspend fun receipts(deviceId: String?): List<ReceiptRow> {
        val q = "stories/receipts" + (deviceId?.let { "?device_id=$it" } ?: "")
        val resp: ReceiptsResp = api.requestAs("GET", q)
        return resp.receipts
    }
}
