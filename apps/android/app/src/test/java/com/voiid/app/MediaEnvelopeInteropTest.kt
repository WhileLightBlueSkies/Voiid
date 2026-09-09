package com.voiid.app

import com.voiid.app.net.ChatEngine.MediaEnvelope
import com.voiid.app.net.ChatEngine.MediaRef
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class MediaEnvelopeInteropTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun mediaIncludesVersionAndEmptyCaptionForIos() {
        val folder = File("build/media-interop-fixtures").apply { mkdirs() }
        for ((index, mime) in listOf("image/jpeg", "video/mp4", "audio/m4a").withIndex()) {
            val ref = MediaRef("fixture/$index", mime, "test-key", "test-nonce", "test-sha")
            val encoded = json.encodeToString(MediaEnvelope.serializer(), MediaEnvelope(media = ref))
            val fields = json.parseToJsonElement(encoded).jsonObject
            assertEquals("1", fields.getValue("v").jsonPrimitive.content)
            assertEquals("", fields.getValue("caption").jsonPrimitive.content)
            assertEquals(ref, json.decodeFromString(MediaEnvelope.serializer(), encoded).media)
            // Consumed by the Swift production-decoder check, never real account data.
            File(folder, "$index.json").writeText(encoded)
        }
    }

    @Test fun olderAndroidMediaWithoutVersionStillDecodes() {
        val old = """{"media":{"mediaUrl":"fixture","mime":"image/png","key":"k","nonce":"n","sha256":"s"},"caption":"A photo"}"""
        val parsed = json.decodeFromString(MediaEnvelope.serializer(), old)
        assertEquals(1, parsed.v)
        assertEquals("A photo", parsed.caption)
        assertEquals("image/png", parsed.media.mime)
    }
}
