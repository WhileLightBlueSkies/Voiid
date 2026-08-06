package com.voiid.app

import com.voiid.app.net.CommunityHostThreads
import com.voiid.app.net.CommunityService
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The community wire types, against the two serialization traps this repo has already shipped
 * bugs from (repair-plan item 3.24). ReceiptEncodingTest pins the general rule; this pins the
 * community/host-thread surface specifically, because it is new and because the host-thread
 * endpoint is the one place where a silently-dropped or silently-failed field decides whether a
 * private conversation gets opened.
 *
 * TRAP 1 — KOTLINX OMITS DEFAULT-VALUED FIELDS ON THE WAY OUT.
 * ApiClient's Json leaves `encodeDefaults` off, so any property equal to its default vanishes
 * from a request body exactly when it holds its most common value. `@EncodeDefault` is the fix.
 *
 * TRAP 2 — A MISSING FIELD IS FATAL ON THE WAY IN.
 * kotlinx throws MissingFieldException for a required property the server did not send; Swift's
 * Codable throws `keyNotFound` for the same shape. Both clients ship ahead of the backend here,
 * so every response field is nullable or defaulted, and these tests are what stops someone
 * "tidying" that up into required fields later.
 */
class CommunityWireEncodingTest {

    /** The exact Json configuration from ApiClient — the point is to test what SHIPS. */
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    // ── TRAP 2: responses must decode from what an older server actually sends ──────

    /**
     * The host-thread response, as a server that only knows about the conversation would send
     * it. If this throws, "Message host" fails with "unexpected server response" over fields the
     * button does not even read.
     */
    @Test
    fun `host thread response decodes from a minimal body`() {
        val decoded = json.decodeFromString(
            CommunityHostThreads.HostThread.serializer(),
            """{"conversation_id":"c1","host_user_id":"u1"}""",
        )
        assertEquals("c1", decoded.conversation_id)
        assertEquals("u1", decoded.host_user_id)
        assertFalse("absent existed must not be treated as true", decoded.existed)
        assertNull(decoded.opened_via)
        assertFalse(decoded.isCommunityThread)
    }

    /**
     * "No thread yet" is the NORMAL state, not an error: the GET returns a null conversation id
     * rather than a 404 so the info card can render "Message host" without creating anything.
     */
    @Test
    fun `host thread response decodes when there is no thread yet`() {
        val decoded = json.decodeFromString(
            CommunityHostThreads.HostThread.serializer(),
            """{"conversation_id":null,"host_user_id":"u1"}""",
        )
        assertNull(decoded.conversation_id)
        assertEquals("u1", decoded.host_user_id)
    }

    /**
     * `opened_via` is the ledger of HOW a chat came to exist (020_reachability.sql widened by
     * 030_communities.sql). A reused personal 1:1 comes back with a null, and the client must not
     * relabel it as a community thread — that would move a private conversation into a Community
     * inbox section and lie about its provenance.
     */
    @Test
    fun `a reused personal chat is not a community thread`() {
        val reused = json.decodeFromString(
            CommunityHostThreads.HostThread.serializer(),
            """{"conversation_id":"c1","host_user_id":"u1","existed":true}""",
        )
        assertFalse(reused.isCommunityThread)

        val opened = json.decodeFromString(
            CommunityHostThreads.HostThread.serializer(),
            """{"conversation_id":"c2","host_user_id":"u1","existed":false,"opened_via":"community"}""",
        )
        assertTrue(opened.isCommunityThread)
    }

    /** The inbox listing: ids and community card fields, every one of them optional. */
    @Test
    fun `host thread summary decodes from a minimal row`() {
        val row = json.decodeFromString(
            CommunityHostThreads.HostThreadSummary.serializer(),
            """{"conversation_id":"c1","community_id":"g1"}""",
        )
        assertEquals("c1", row.conversation_id)
        assertNull(row.community_name)
        assertFalse("absent role must not read as host", row.amHost)
    }

    /** Unknown fields are additive, not fatal — a newer server must not break an older build. */
    @Test
    fun `unknown server fields are ignored`() {
        val row = json.decodeFromString(
            CommunityHostThreads.HostThreadSummary.serializer(),
            """{"conversation_id":"c1","some_future_field":{"a":1}}""",
        )
        assertEquals("c1", row.conversation_id)
    }

    /** The public info card, as a backend that has not grown the invite fields would send it. */
    @Test
    fun `community card decodes without the optional fields`() {
        val card = json.decodeFromString(
            CommunityService.CommunityCard.serializer(),
            """{"id":"g1","handle":"acme","name":"Acme"}""",
        )
        assertEquals(0, card.member_count)
        assertEquals("open", card.join_policy)
        assertFalse("membership must never be inferred from a link resolving", card.isMember)
        assertNull(card.invite_valid)
    }

    // ── TRAP 1: request bodies must actually say what they mean ─────────────────────

    /**
     * The join body's token has NO default, so it is always encoded when present. With
     * `explicitNulls = false` a null is dropped rather than sent, which is exactly the
     * "no token presented" case the server reads as `undefined`.
     */
    @Serializable
    private data class JoinBody(val invite_token: String?)

    @Test
    fun `an invite token is present on the wire`() {
        val encoded = json.encodeToString(JoinBody.serializer(), JoinBody("tok_abc"))
        assertTrue(encoded, encoded.contains("\"invite_token\":\"tok_abc\""))
    }

    @Test
    fun `a missing invite token is omitted, not sent as null`() {
        assertEquals("{}", json.encodeToString(JoinBody.serializer(), JoinBody(null)))
    }

    /**
     * The rule for any FUTURE community request body or E2EE envelope.
     *
     * The host-thread POST deliberately has no body at all — there is nothing a client is
     * allowed to say about who the host is — so the trap has no purchase there today. It gets
     * one the moment somebody adds a defaulted discriminator, which is what these two types
     * demonstrate side by side.
     */
    @Serializable
    private data class BrokenEnvelope(val t: String = "community_ask", val target: String)

    @Serializable
    private data class FixedEnvelope(@EncodeDefault val t: String = "community_ask", val target: String)

    @Test
    fun `a defaulted discriminator vanishes without EncodeDefault`() {
        assertEquals(
            "kotlinx omits default-valued fields; the receiver then cannot tell what this is",
            """{"target":"m1"}""",
            json.encodeToString(BrokenEnvelope.serializer(), BrokenEnvelope(target = "m1")),
        )
    }

    @Test
    fun `EncodeDefault keeps the discriminator on the wire`() {
        val encoded = json.encodeToString(FixedEnvelope.serializer(), FixedEnvelope(target = "m1"))
        assertTrue(encoded, encoded.contains("\"t\":\"community_ask\""))
    }
}
