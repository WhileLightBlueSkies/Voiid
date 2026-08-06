package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable

/**
 * What is being reported.
 *
 * `Person` maps to the server's `message_sender`, and the naming difference is deliberate:
 * the wire type says "sender" because that is the relationship, but nothing about a MESSAGE
 * travels — there is no message id here and there is no field to put one in.
 */
sealed class ReportTarget(val type: String, val id: String) {
    class Clip(id: String) : ReportTarget("clip", id)
    class Creator(userId: String) : ReportTarget("creator", userId)
    class Person(userId: String) : ReportTarget("message_sender", userId)
}

class ReportService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    @OptIn(ExperimentalSerializationApi::class)
    @Serializable
    private data class Body(
        // @EncodeDefault on EVERY field: this is a REQUEST body, and the project's
        // encodeDefaults=false would silently drop any field that happened to equal its
        // default — the bug class that has already broken read receipts and stories here.
        @EncodeDefault val target_type: String,
        @EncodeDefault val target_id: String,
        @EncodeDefault val reason: String,
        @EncodeDefault val note: String? = null,
    )

    suspend fun submit(target: ReportTarget, reason: String, note: String) {
        api.request(
            "POST", "reports",
            jsonBody = ApiClient.json.encodeToString(
                Body.serializer(),
                Body(target.type, target.id, reason, note.ifBlank { null }),
            ),
        )
    }
}
