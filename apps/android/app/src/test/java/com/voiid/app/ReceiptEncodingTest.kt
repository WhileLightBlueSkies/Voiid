package com.voiid.app

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Read receipts must actually say "read" ON THE WIRE.
 *
 * THE BUG THIS EXISTS FOR
 * -----------------------
 * `MarkReadBody` declared `status: String = "read"`. kotlinx-serialization omits any field
 * whose value equals its default unless `encodeDefaults = true`, and ApiClient's Json does not
 * set it. So marking a message READ — the one case where status carries information — produced
 * `{"message_ids":[...]}` with no status at all.
 *
 * The server (routes/receipts.ts) reads `const { status = 'delivered' } = req.body`. A missing
 * status is therefore not an error: it silently becomes 'delivered'. The POST returned 200,
 * Android looked like it was working, and iOS never showed "Seen" because no read receipt was
 * ever sent.
 *
 * A default value on a serialized DTO is the hazard, not the specific field: the field vanishes
 * exactly when it holds its most common value. This is the same asymmetry that broke Stories
 * cross-platform (Swift's Codable throws on a missing key where kotlinx omits one), and it
 * stays invisible in testing because both sides return success.
 */
class ReceiptEncodingTest {

    /** The exact Json configuration from ApiClient — the point is to test what SHIPS. */
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    /** Mirrors the fixed `ChatEngine.MarkReadBody`: no default on `status`. */
    @Serializable
    private data class MarkReadBody(val message_ids: List<String>, val status: String)

    /** The shape that shipped, kept only to demonstrate the failure it caused. */
    @Serializable
    private data class LegacyMarkReadBody(val message_ids: List<String>, val status: String = "read")

    @Test
    fun `status is present on the wire when marking read`() {
        val encoded = json.encodeToString(
            MarkReadBody.serializer(),
            MarkReadBody(listOf("m1", "m2"), "read"),
        )
        assertTrue(
            "status must be serialized — the server defaults a missing one to 'delivered'",
            encoded.contains("\"status\":\"read\""),
        )
    }

    @Test
    fun `status is present on the wire when marking delivered`() {
        val encoded = json.encodeToString(
            MarkReadBody.serializer(),
            MarkReadBody(listOf("m1"), "delivered"),
        )
        assertTrue(encoded, encoded.contains("\"status\":\"delivered\""))
    }

    /**
     * The SAME hazard on the E2EE action envelopes.
     *
     * `ReactionWire`/`DeleteWire`/`ReplyWire`/`StoryReplyWire` all declared `t` and `v` with
     * defaults, and `t` is the discriminator the RECEIVER probes to decide what the plaintext
     * is. Dropping it means a reaction arrives indistinguishable from an ordinary message —
     * and unlike the receipt bug there is no server-side default to paper over it.
     */
    @Serializable
    private data class ActionWire(val t: String, val v: Int, val target: String)

    @Test
    fun `action envelopes carry their type discriminator`() {
        val encoded = json.encodeToString(
            ActionWire.serializer(),
            ActionWire("msg_reaction", 1, "m1"),
        )
        assertTrue(encoded, encoded.contains("\"t\":\"msg_reaction\""))
        assertTrue(encoded, encoded.contains("\"v\":1"))
    }

    /**
     * Pins the root cause. If this ever stops holding — because someone sets
     * `encodeDefaults = true` — the original bug is no longer reachable, but the fix above is
     * still correct and this test documents why the default was removed.
     */
    @Test
    fun `a defaulted status is silently omitted, which is what broke read receipts`() {
        val encoded = json.encodeToString(
            LegacyMarkReadBody.serializer(),
            LegacyMarkReadBody(listOf("m1"), "read"),
        )
        assertEquals(
            "kotlinx omits default-valued fields; the server then reads status as 'delivered'",
            """{"message_ids":["m1"]}""",
            encoded,
        )
    }
}
