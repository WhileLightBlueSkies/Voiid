package com.voiid.app.net

import android.content.Context
import androidx.compose.runtime.Immutable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * DPDP requests (data principal rights) — Android counterpart of iOS `DPDPService`.
 *
 * The server enforces ONE OPEN REQUEST PER KIND and answers 409 with the existing row when
 * there already is one. That is not a failure — the user asked for a thing that is already
 * happening — so [requestErasure] surfaces the 409 row through the same outcome type.
 *
 * An erasure REQUEST is not the same act as deleting the account: the server records it with
 * an SLA due date and a person actions it. The returned [EraseOutcome.note] is the SERVER'S
 * own sentence and is meant to be shown verbatim.
 */
class DpdpService(context: Context) {

    private val api = ApiClient(TokenStore.get(context))

    @Immutable
    data class EraseOutcome(
        val requestId: String?,
        /** SLA deadline the server computed, ISO-8601. */
        val dueAt: String?,
        /** The server's own sentence about what just happened. Show verbatim. */
        val note: String?,
        /** True when a request of this kind was ALREADY open (HTTP 409). */
        val alreadyOpen: Boolean = false,
    )

    /** Open an erasure request. Throws [ApiError] on transport/server failure. */
    suspend fun requestErasure(note: String? = null): EraseOutcome {
        val body = buildString {
            append("{\"kind\":\"erasure\"")
            if (!note.isNullOrBlank()) append(",\"note\":\"").append(jsonEscape(note)).append("\"")
            append("}")
        }
        return try {
            val text = api.request("POST", "dpdp/requests", jsonBody = body)
            parseOutcome(text, alreadyOpen = false)
        } catch (e: ApiError.Http) {
            if (e.status == 409) EraseOutcome(
                requestId = null, dueAt = null,
                note = "You already have an erasure request open. It is still being actioned.",
                alreadyOpen = true,
            ) else throw e
        }
    }

    private fun parseOutcome(text: String, alreadyOpen: Boolean): EraseOutcome {
        val obj = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrDefault(kotlinx.serialization.json.JsonObject(emptyMap()))
        val request = obj["request"]?.let { runCatching { it.jsonObject }.getOrNull() }
        return EraseOutcome(
            requestId = request?.get("id")?.let { runCatching { it.jsonPrimitive.content }.getOrNull() },
            dueAt = request?.get("due_at")?.let { runCatching { it.jsonPrimitive.content }.getOrNull() },
            note = obj["note"]?.let { runCatching { it.jsonPrimitive.content }.getOrNull() },
            alreadyOpen = alreadyOpen,
        )
    }

    private fun jsonEscape(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
}
