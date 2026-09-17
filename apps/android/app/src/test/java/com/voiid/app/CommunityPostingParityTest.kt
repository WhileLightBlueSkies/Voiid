package com.voiid.app

import com.voiid.app.net.CommunityService
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class CommunityPostingParityTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun selectedMembershipUsesServerCapabilityRatherThanLocalRole() {
        for (allowed in listOf(true, false)) {
            val envelope = json.decodeFromString<CommunityService.CommunityEnvelope>("""
                {"community":{"id":"c","handle":"topic","name":"Topic","posting_policy":"selected"},
                 "membership_state":"active","membership_role":"member","can_post":$allowed}
            """.trimIndent())
            val card = envelope.merged(null)
            assertTrue(card.isMember)
            assertEquals(allowed, card.can_post)
        }
    }

    @Test fun missingCapabilityNeverGrantsPostingEvenToOwner() {
        val envelope = json.decodeFromString<CommunityService.CommunityEnvelope>("""
            {"community":{"id":"c","handle":"topic","name":"Topic","posting_policy":"none"},
             "membership_state":"active","membership_role":"owner"}
        """.trimIndent())
        assertTrue(envelope.merged(null).isManager)
        assertFalse(envelope.merged(null).can_post)
    }

    @Test fun spaceMetadataAndFeedCountersDecodeIndependentOfChatKind() {
        val space = json.decodeFromString<CommunityService.Channel>("""
            {"conversation_id":"space","kind":"chat","posting":"none","can_post":false,
             "purpose":"Read only","pinned_at":"2026-09-17T00:00:00Z"}
        """.trimIndent())
        assertFalse(space.isAnnouncement)
        assertEquals("none", space.posting)
        assertFalse(space.can_post)
        assertEquals("Read only", space.purpose)
        assertNotNull(space.pinned_at)
        val page = json.decodeFromString<CommunityService.PostPage>("""
            {"posts":[{"id":"post","view_count":27,"like_count":4,"liked_by_me":true,
             "channel_id":"space","author_is_official":true}],"can_post":false,"next_cursor":"opaque"}
        """.trimIndent())
        assertEquals(27, page.posts.single().view_count)
        assertEquals(4, page.posts.single().likes)
        assertTrue(page.posts.single().isLiked)
        assertEquals(true, page.posts.single().author_is_official)
        assertEquals("opaque", page.next_cursor)
        assertFalse(page.can_post)
    }
}
