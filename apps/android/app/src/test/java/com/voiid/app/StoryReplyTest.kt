package com.voiid.app

import com.voiid.app.net.ChatEngine.DecryptedMessage
import com.voiid.app.net.ChatEngine.StoryReplyWire
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class StoryReplyTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val reference = "\"storyId\":\"story-a\",\"storyAuthorId\":\"author-a\",\"storyCreatedAt\":1000"

    @Test fun iosTextAndReactionRepliesRetainTheirReferenceAfterPersistence() {
        for (body in listOf("\"text\":\"Nice photo\"", "\"reaction\":\"❤️\"", "\"text\":null,\"reaction\":\"❤️\"")) {
            val wire = json.decodeFromString(StoryReplyWire.serializer(), "{\"v\":1,\"t\":\"story_reply\",$reference,$body}")
            for (mine in listOf(false, true)) {
                val message = wire.toMessage("reply-a", "sender-a", 2000, mine)
                val restored = json.decodeFromString(DecryptedMessage.serializer(), json.encodeToString(DecryptedMessage.serializer(), message))
                assertEquals("story-a", restored.storyQuoteId)
                assertEquals("author-a", restored.storyQuoteAuthorId)
                assertEquals(1000L, restored.storyQuoteCreatedAt)
                assertEquals(2000L, restored.createdAt)
                assertEquals(mine, restored.isMine)
                assertEquals(if (body.contains("Nice photo")) "Nice photo" else "❤️", restored.text)
                assertNull(restored.media)
                assertNull(restored.hiddenForMe().storyQuoteId)
            }
        }
    }

    @Test fun oldStoredMessagesAndLegacyReplyOptionalsRemainReadable() {
        val old = "{\"id\":\"old\",\"senderId\":\"sender\",\"text\":\"hello\",\"createdAt\":1000,\"isMine\":false}"
        assertNull(json.decodeFromString(DecryptedMessage.serializer(), old).storyQuoteId)
        val wire = json.decodeFromString(StoryReplyWire.serializer(), "{\"v\":null,\"t\":null,$reference,\"text\":\"Hi\"}")
        assertEquals("Hi", wire.toMessage("reply", "sender", 2000, false).text)
    }

    @Test fun outgoingReplyKeepsTheCrossPlatformDiscriminatorAndBothBodies() {
        val wire = StoryReplyWire(storyId = "story-a", storyAuthorId = "author-a", storyCreatedAt = 1000, text = "Nice", reaction = "❤️")
        val encoded = json.encodeToString(StoryReplyWire.serializer(), wire)
        assertTrue(encoded.contains("\"t\":\"story_reply\""))
        assertTrue(encoded.contains("\"v\":1"))
        assertEquals("❤️ Nice", wire.toMessage("reply", "sender", 2000, true).text)
    }

    @Test(expected = IllegalArgumentException::class)
    fun unsupportedVersionDoesNotBecomeAQuotedMessage() {
        StoryReplyWire(v = 2, storyId = "story", storyAuthorId = "author", storyCreatedAt = 1000)
            .toMessage("reply", "sender", 2000, false)
    }
}
