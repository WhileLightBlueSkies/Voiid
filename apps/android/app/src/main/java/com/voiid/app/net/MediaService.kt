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
 * Media blob transport (mirrors iOS MediaService). The blob is encrypted
 * ON-DEVICE (e2e-core encryptMedia) before it ever leaves; the server only signs
 * short-lived R2 URLs and never sees the bytes or the media key. This service:
 *   - asks the backend for a presigned PUT url (POST /media/presign-upload)
 *   - PUTs the CIPHERTEXT straight to R2
 *   - asks for a presigned GET url (POST /media/presign-download) and downloads
 * The per-message media key travels INSIDE the E2EE message (see ChatEngine).
 */
class MediaService(private val tokens: TokenStore) {
    private val api = ApiClient(tokens)

    // A separate (longer-timeout) client for the direct R2 transfers — blobs can
    // be larger than JSON API calls.
    private val blobClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    @Serializable private data class PresignUploadBody(val mime: String)
    @Serializable private data class PresignUploadResp(val key: String, val upload_url: String)
    @Serializable private data class PresignDownloadBody(val key: String)
    @Serializable private data class PresignDownloadResp(val download_url: String)

    /** Encrypted upload: presigned PUT → push ciphertext to R2 → return object key. */
    suspend fun upload(ciphertext: ByteArray, mime: String): String {
        val body = ApiClient.json.encodeToString(PresignUploadBody.serializer(), PresignUploadBody(mime))
        val presign: PresignUploadResp = api.requestAs("POST", "media/presign-upload", jsonBody = body)
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(presign.upload_url)
                .put(ciphertext.toRequestBody(mime.toMediaType()))
                .build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "media upload failed (${it.code})")
            }
        }
        return presign.key
    }

    /** Encrypted download: presigned GET for `key` → fetch the ciphertext bytes. */
    suspend fun download(key: String): ByteArray {
        val body = ApiClient.json.encodeToString(PresignDownloadBody.serializer(), PresignDownloadBody(key))
        val presign: PresignDownloadResp = api.requestAs("POST", "media/presign-download", jsonBody = body)
        return withContext(Dispatchers.IO) {
            val req = Request.Builder().url(presign.download_url).get().build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "media download failed (${it.code})")
                it.body?.bytes() ?: ByteArray(0)
            }
        }
    }
}
