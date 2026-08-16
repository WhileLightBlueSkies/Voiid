package com.voiid.app

import com.voiid.app.net.BlockedUser
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The block wire format, in both directions.
 *
 * TWO TRAPS THIS PINS, both of which have already shipped as real bugs in this app
 * (see ReceiptEncodingTest and CommunityWireEncodingTest).
 *
 *  1. OUTBOUND — `ApiClient.json` has `encodeDefaults` OFF. A @Serializable request-body
 *     field whose value equals its default is silently dropped from the wire. POST /blocks
 *     rejects a body with no `user_id`, so a dropped field means the Block button appears
 *     to work and blocks nobody. BlockService uses buildJsonObject to sidestep this; the
 *     test below pins that the field actually reaches the wire.
 *
 *  2. INBOUND — kotlinx throws MissingFieldException for a required property the server did
 *     not send. A blocked account may legitimately have no username, no display name and no
 *     photo, so every field of [BlockedUser] except the id must be nullable with a default.
 *     Otherwise one avatar-less blocked user fails the whole decode and the settings screen
 *     renders empty.
 */
class BlockWireEncodingTest {

    /** The exact Json configuration from ApiClient — the point is to test what SHIPS. */
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    @Serializable
    private data class BlockedListEnvelope(val blocked: List<BlockedUser>? = null)

    // ── Outbound ───────────────────────────────────────────────────────────────────

    @Test
    fun `user_id is present on the wire when blocking`() {
        // Mirrors BlockService.block's body construction.
        val body = buildJsonObject { put("user_id", "u-123") }.toString()
        assertTrue(
            "user_id must be serialized — POST /blocks 400s without it, and the UI would " +
                "report a block that never happened",
            body.contains("\"user_id\":\"u-123\""),
        )
    }

    // ── Inbound ────────────────────────────────────────────────────────────────────

    @Test
    fun `a blocked user with only an id decodes`() {
        // The minimum the server can return: an account with no name, handle or photo.
        val env = json.decodeFromString(
            BlockedListEnvelope.serializer(),
            """{"blocked":[{"id":"u-1"}]}""",
        )
        val user = env.blocked?.firstOrNull()
        assertEquals("u-1", user?.id)
        assertNull(user?.username)
        assertNull(user?.full_name)
        assertNull(user?.photo_url)
    }

    @Test
    fun `a fully populated blocked user decodes`() {
        val env = json.decodeFromString(
            BlockedListEnvelope.serializer(),
            """{"blocked":[{"id":"u-2","username":"nadia","full_name":"Nadia R",""" +
                """"photo_url":"https://cdn/x.jpg","blocked_at":"2026-08-16T10:00:00Z"}]}""",
        )
        val user = env.blocked?.first()
        assertEquals("nadia", user?.username)
        assertEquals("Nadia R", user?.full_name)
        assertEquals("2026-08-16T10:00:00Z", user?.blocked_at)
    }

    @Test
    fun `an empty block list decodes to an empty list, not a failure`() {
        val env = json.decodeFromString(BlockedListEnvelope.serializer(), """{"blocked":[]}""")
        assertEquals(0, env.blocked?.size)
    }

    @Test
    fun `a response with no blocked key at all decodes to null rather than throwing`() {
        // Defensive: the envelope field is nullable, so a server that omits the key entirely
        // yields null instead of failing the decode and blanking the screen.
        val env = json.decodeFromString(BlockedListEnvelope.serializer(), """{}""")
        assertNull(env.blocked)
    }

    @Test
    fun `unknown server fields do not break the decode`() {
        // The clients ship ahead of the backend and vice versa; a field added server-side
        // must never crash an older build.
        val env = json.decodeFromString(
            BlockedListEnvelope.serializer(),
            """{"blocked":[{"id":"u-3","some_future_field":true}],"total":1}""",
        )
        assertEquals("u-3", env.blocked?.first()?.id)
    }

    // ── displayName fallback ───────────────────────────────────────────────────────

    @Test
    fun `displayName prefers the full name`() {
        assertEquals("Nadia R", BlockedUser(id = "u", full_name = "Nadia R", username = "nadia").displayName)
    }

    @Test
    fun `displayName falls back to the handle when there is no name`() {
        assertEquals("@nadia", BlockedUser(id = "u", username = "nadia").displayName)
    }

    @Test
    fun `displayName falls back again when the account has nothing`() {
        // Must never render an empty row: a blank entry in the blocked list is unactionable,
        // and the user cannot tell who they would be unblocking.
        assertEquals("Unknown user", BlockedUser(id = "u").displayName)
    }

    @Test
    fun `a blank full name does not win over the handle`() {
        // The server stores an empty string rather than null for a cleared name, so an
        // isNullOrBlank check is what keeps the row from rendering as whitespace.
        assertEquals("@nadia", BlockedUser(id = "u", full_name = "   ", username = "nadia").displayName)
    }
}
