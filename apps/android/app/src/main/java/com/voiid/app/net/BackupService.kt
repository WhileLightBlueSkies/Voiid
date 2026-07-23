package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Encrypted-backup blob transport. The blob is sealed ON-DEVICE
 * (encryptBackup under the master secret) before it leaves; the server stores opaque
 * bytes in R2 and never sees plaintext or the key.
 *   - PUT /backup   RAW application/octet-stream body → {stored, size_bytes} (max 50 MiB)
 *   - GET /backup   → {download_url (presigned R2), size_bytes, updated_at}; 404 = none
 *
 * The raw PUT and JSON metadata GET go through [ApiClient.requestRaw] (JWT-attached,
 * versioned /v1/backup). The presigned download is a plain GET to R2 (mirrors
 * [MediaService]'s blobClient).
 */
class BackupService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    private val blobClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()

    @Serializable
    data class BackupMeta(
        val download_url: String? = null,
        val size_bytes: Long = 0,
        val updated_at: String? = null,
    )

    @Serializable private data class UploadResp(val stored: Boolean = false, val size_bytes: Long = 0)

    /** Upload the encrypted backup blob (raw octet-stream). */
    suspend fun uploadBackup(blob: ByteArray) {
        val resp = api.requestRaw("PUT", "backup", body = blob, contentType = "application/octet-stream")
        if (!resp.isSuccessful) {
            throw ApiError.Http(resp.code, "Backup upload failed (${resp.code}).")
        }
    }

    /** Backup metadata (last size / time + presigned download url), or null if none (404). */
    suspend fun fetchBackupMeta(): BackupMeta? {
        val resp = api.requestRaw("GET", "backup")
        return when {
            resp.code == 404 -> null
            resp.isSuccessful -> ApiClient.json.decodeFromString(BackupMeta.serializer(), String(resp.body))
            else -> throw ApiError.Http(resp.code, "Couldn't fetch backup info (${resp.code}).")
        }
    }

    /** Download the encrypted backup blob via the presigned R2 url. */
    suspend fun downloadBackup(): ByteArray {
        val meta = fetchBackupMeta() ?: throw ApiError.Http(404, "No backup found.")
        val url = meta.download_url ?: throw ApiError.Http(404, "No backup found.")
        return withContext(Dispatchers.IO) {
            val req = Request.Builder().url(url).get().build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "Backup download failed (${it.code}).")
                it.body?.bytes() ?: ByteArray(0)
            }
        }
    }
}
