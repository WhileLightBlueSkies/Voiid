package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Host verification — the gate in front of selling tickets (routes/kyc.ts). Mirrors iOS
 * `KycService.swift`.
 *
 * The PAN and the bank account number are sent ONCE, in [verify], and never cached: the server
 * passes them to Cashfree Secure ID and payout onboarding in that same request and keeps only the
 * last four characters. Documents go straight to private storage through a presigned PUT and are
 * never served back to the app.
 */
class KycService(context: Context) {
    private val api = ApiClient(TokenStore.get(context.applicationContext))
    private val blobClient = OkHttpClient()

    @Serializable
    data class Document(val id: String, val kind: String, val mime: String? = null, val uploaded_at: String? = null)

    /** `status`: not_started | draft | pending_review | verified | rejected. */
    @Serializable
    data class Verification(
        val status: String = "not_started",
        val legal_name: String? = null,
        val email: String? = null,
        val pan_last4: String? = null,
        val pan_registered_name: String? = null,
        val bank_last4: String? = null,
        val ifsc: String? = null,
        val bank_name: String? = null,
        val submitted_at: String? = null,
        val reviewed_at: String? = null,
        val rejection_reason: String? = null,
        val documents: List<Document> = emptyList(),
        /** False when the server has no verification provider configured. */
        val available: Boolean = true,
    ) {
        val isVerified get() = status == "verified"
        val isInReview get() = status == "pending_review"
        val isRejected get() = status == "rejected"
    }

    @Serializable private data class Envelope(val verification: Verification)

    suspend fun me(): Verification = api.requestAs<Envelope>("GET", "kyc/me").verification

    @Serializable
    data class VerifyInput(val legal_name: String, val email: String, val pan: String, val bank_account: String, val ifsc: String)

    suspend fun verify(input: VerifyInput): Verification =
        api.requestAs<Envelope>("POST", "kyc/verify",
            ApiClient.json.encodeToString(VerifyInput.serializer(), input)).verification

    enum class DocumentKind(val wire: String, val title: String) {
        PAN_CARD("pan_card", "PAN card"),
        BANK_PROOF("bank_proof", "Cancelled cheque or bank statement"),
        INSTITUTION_LETTER("institution_letter", "Letter from your institution"),
        OTHER("other", "Something else"),
    }

    @Serializable private data class PresignBody(val kind: String, val mime: String)
    @Serializable private data class PresignedDoc(val id: String)
    @Serializable private data class Presigned(val document: PresignedDoc, val upload_url: String)

    /** Presign → PUT → confirm; a reviewer sees a document only once the upload has landed. */
    suspend fun upload(jpeg: ByteArray, kind: DocumentKind) {
        val p = api.requestAs<Presigned>("POST", "kyc/documents",
            ApiClient.json.encodeToString(PresignBody.serializer(), PresignBody(kind.wire, "image/jpeg")))
        withContext(Dispatchers.IO) {
            val req = Request.Builder().url(p.upload_url)
                .put(jpeg.toRequestBody("image/jpeg".toMediaType())).build()
            blobClient.newCall(req).execute().use {
                if (!it.isSuccessful) throw ApiError.Http(it.code, "Upload failed. Try again.")
            }
        }
        api.request("POST", "kyc/documents/${p.document.id}/confirm")
    }

    suspend fun removeDocument(id: String) { api.request("DELETE", "kyc/documents/$id") }
}
