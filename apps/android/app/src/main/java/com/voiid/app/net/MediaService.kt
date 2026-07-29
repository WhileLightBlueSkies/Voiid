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
 * Media blob transport (mirrors iOS MediaService).
 *
 * MESSAGE media is encrypted ON-DEVICE (e2e-core encryptMedia) before it leaves; the server
 * only signs short-lived R2 URLs and never sees those bytes or the media key.
 *
 * PROFILE PHOTOS ARE THE EXCEPTION and are stored in the clear — see [uploadProfilePhoto].
 * This header used to claim the blanket "never sees the bytes", which is why the plaintext
 * avatar path read as intentional-and-safe rather than as a gap.
 *
 * This service:
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

    /**
     * Push [payload] to R2 via a presigned PUT and return the opaque object key.
     *
     * The parameter is `payload`, NOT `ciphertext`. It used to be the latter, which asserted at
     * every call site that the bytes were already encrypted — and the avatar path passed a raw
     * JPEG straight into it. The name made that read as correct, which is exactly why the
     * plaintext-avatar bug survived review. This transport is agnostic: whether the bytes are
     * encrypted is the CALLER's responsibility, and the two callers now say which they are.
     */
    suspend fun upload(payload: ByteArray, mime: String): String {
        val body = ApiClient.json.encodeToString(PresignUploadBody.serializer(), PresignUploadBody(mime))
        val presign: PresignUploadResp = api.requestAs("POST", "media/presign-upload", jsonBody = body)
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(presign.upload_url)
                .put(payload.toRequestBody(mime.toMediaType()))
                .build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "media upload failed (${it.code})")
            }
        }
        return presign.key
    }

    /**
     * Profile photo upload — ⚠️ NOT ENCRYPTED. The server can read these bytes.
     *
     * Unlike message media, an avatar has no fixed audience: it is shown to anyone who might
     * contact you, including a stranger who found your @username and has never had a ratchet
     * session with you. There is therefore no established channel to deliver a key over.
     *
     * The fix is a Signal-style PROFILE KEY — one long-lived key per user, wrapped to each
     * contact over the ratchet. It is blocked on `encryptMediaWithKey` (e2e-core has only
     * `encryptMedia`, which always mints a fresh key) and on regenerated uniffi bindings. See
     * `generate_profile_key` / `encrypt_media_with_key` in packages/e2e-core/src/media.rs.
     *
     * Until that ships, the privacy copy must NOT claim avatars are encrypted. They are not.
     */
    suspend fun uploadProfilePhoto(imageData: ByteArray, mime: String = "image/jpeg"): String {
        // Named local: the plaintext-ness is stated where it happens, not inferred.
        val plaintextJpeg = imageData
        return upload(plaintextJpeg, mime)
    }

    /**
     * Plain GET of an ABSOLUTE url — no presign, no auth header, no decryption.
     *
     * For avatars only ([AvatarCache]): a `photo_url` may be an opaque R2 key (use [download])
     * or an absolute CDN url from an older profile write. Same blob client so the timeouts and
     * connection pool are shared rather than standing up a second OkHttp instance per face.
     */
    suspend fun fetchAbsolute(url: String): ByteArray = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url).get().build()
        blobClient.newCall(req).execute().use {
            if (!it.isSuccessful) throw ApiError.Http(it.code, "avatar fetch failed (${it.code})")
            it.body?.bytes() ?: ByteArray(0)
        }
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
