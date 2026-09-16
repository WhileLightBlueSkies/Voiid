package com.voiid.app

import com.voiid.app.net.ConversationReadQueue
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class ConversationReadQueueTest {
    @Test fun persistedIntentSurvivesRestartAndKeepsItsBoundary() {
        val dir = Files.createTempDirectory("voiid-read-queue").toFile()
        try {
            fun queue() = ConversationReadQueue(
                load = { key -> dir.resolve(key).takeIf { it.exists() }?.readText() },
                save = { key, value -> dir.resolve(key).writeText(value); true },
            )
            val sent = ConversationReadQueue.Intent(12345, true)
            assertTrue(queue().enqueue("alice", "chat", sent))
            val restarted = queue()
            assertEquals(sent, restarted.snapshot("alice")["chat"])
            assertTrue(restarted.snapshot("bob").isEmpty())
            assertFalse(sent.shouldDisclose(false))
            val newer = ConversationReadQueue.Intent(23456, false)
            restarted.enqueue("alice", "chat", newer)
            restarted.acknowledge("alice", "chat", sent)
            assertEquals(newer, queue().snapshot("alice")["chat"])
            restarted.acknowledge("alice", "chat", newer)
            assertTrue(queue().snapshot("alice").isEmpty())
        } finally { dir.deleteRecursively() }
    }
    @Test fun failedPersistenceIsNotAcknowledged() {
        val queue = ConversationReadQueue(load = { null }, save = { _, _ -> false })
        assertFalse(queue.enqueue("alice", "chat", ConversationReadQueue.Intent(123, true)))
    }
}
