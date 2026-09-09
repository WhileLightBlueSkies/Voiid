package com.voiid.app

import com.voiid.app.net.ChatEngine.DecryptedMessage
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class ChatActionStateTest {
    private fun message() = DecryptedMessage("local", "me", "Hello", 1000, true, serverId = "server", reactions = mapOf("peer" to "❤️"))
    @Test fun removingOwnMatchingEmojiPreservesThePeer() {
        val both = message().reacting("me", "❤️")
        assertEquals(2, both.reactions?.size)
        assertEquals(mapOf("peer" to "❤️"), both.reacting("me", null).reactions)
    }
    @Test fun replacementsKeepOneReactionPerUser() {
        val changed = message().reacting("me", "❤️").reacting("me", "🔥")
        assertEquals(mapOf("peer" to "❤️", "me" to "🔥"), changed.reactions)
    }
    @Test fun localDeleteSurvivesReloadAndRetainsDedupIds() {
        val hidden = message().copy(pending = true).hiddenForMe()
        val restored = Json.decodeFromString(DecryptedMessage.serializer(), Json.encodeToString(DecryptedMessage.serializer(), hidden))
        assertTrue(restored.deletedForMe)
        assertEquals("local", restored.id)
        assertEquals("server", restored.serverId)
        assertEquals("", restored.text)
        assertNull(restored.reactions)
        assertFalse(restored.pending)
        assertEquals(restored, restored.reacting("peer", "🔥"))
    }
    @Test fun remoteTombstoneRejectsLateReactions() {
        val deleted = message().copy(deletedForEveryone = true, reactions = null)
        assertEquals(deleted, deleted.reacting("peer", "❤️"))
    }
    @Test fun olderStoredRowsRemainVisible() {
        val restored = Json.decodeFromString(DecryptedMessage.serializer(), """{"id":"old","senderId":"peer","text":"Hello","createdAt":1000,"isMine":false}""")
        assertFalse(restored.deletedForMe)
    }
}
