package com.voiid.app

import com.voiid.app.model.StoryEnvelope
import com.voiid.app.model.StoryViewReceipt
import com.voiid.app.net.ChatEngine.MediaRef
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class StoryEnvelopeInteropTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun storyWireSupportsIosOptionalsAndKeepsMediaKeysRequired() {
        val folder = File("build/story-interop-fixtures").apply { mkdirs() }
        for ((index, mime) in listOf("image/jpeg", "video/mp4").withIndex()) {
            val story = StoryEnvelope(story_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                author_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", created_at = 1000, expires_at = 86401000,
                media = MediaRef("fixture/$index", mime, "test-key", "test-nonce", "test-hash"),
                durationMs = if (index == 1) 12000 else null)
            val encoded = json.encodeToString(StoryEnvelope.serializer(), story)
            assertEquals(story, json.decodeFromString(StoryEnvelope.serializer(), encoded))
            File(folder, "$index.json").writeText(encoded)
            val nullable = encoded.dropLast(1) + ",\"caption\":null,\"allowsReplies\":null}"
            assertNull(json.decodeFromString(StoryEnvelope.serializer(), nullable).caption)
            try {
                json.decodeFromString(StoryEnvelope.serializer(), encoded.replace("\"key\":\"test-key\",", ""))
                fail("A story without its encryption key must not decode")
            } catch (_: kotlinx.serialization.SerializationException) { }
        }
        val receipt = StoryViewReceipt(story_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            viewer_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", viewed_at = 2000)
        File(folder, "receipt.json").writeText(json.encodeToString(StoryViewReceipt.serializer(), receipt))
    }
}
