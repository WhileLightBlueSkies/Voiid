package com.voiid.app

import com.voiid.app.net.DirtyConversations
import com.voiid.app.net.ShardStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * I03 — local persistence that tells the truth about whether it persisted.
 *
 * THREE BUGS, and they compound.
 *
 *  1. `persist()` cleared the dirty set BEFORE writing, and `persistShard` swallowed every
 *     failure into a log line. A disk-full or permission error meant the conversation was
 *     never written and never retried — the app carried on with an in-memory copy that
 *     vanished at exit.
 *  2. The atomic write fell back to overwriting the live file in place when the rename failed.
 *     That is the opposite of atomic: an interruption there leaves a half-written shard where
 *     a complete one used to be.
 *  3. An undecodable shard was skipped on load, so the conversation came back EMPTY — and the
 *     next persist wrote that emptiness over the file. One bad shard silently replaced a whole
 *     conversation's history.
 *
 * Since M02 the first bug also produces a false acknowledgement: the client tells the server it
 * has stored a message it did not store, and the server stops offering it.
 */
class ShardStoreTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun shard(name: String = "conv.json") = File(tmp.root, name)

    // ── Writing ──────────────────────────────────────────────────────────────────

    @Test
    fun `a successful write replaces the file and leaves no temporary behind`() {
        val file = shard()
        assertEquals(ShardStore.Write.Committed, ShardStore.write(file, "[1,2,3]"))
        assertEquals("[1,2,3]", file.readText())
        assertTrue(
            "a leftover .tmp is a half-written shard waiting to be mistaken for a real one",
            tmp.root.listFiles()!!.none { it.name.endsWith(".tmp") }
        )
    }

    @Test
    fun `a rewrite replaces the previous contents entirely`() {
        val file = shard()
        ShardStore.write(file, "[1,2,3]")
        ShardStore.write(file, "[4]")
        assertEquals("[4]", file.readText())
    }

    /**
     * THE REMOVED FALLBACK. When the rename failed, the old code wrote the payload straight
     * over the live shard. If THAT is interrupted the good copy is gone — which is the exact
     * thing temp-and-rename exists to prevent, undone in the error path.
     */
    @Test
    fun `a failed replacement never writes over the live shard`() {
        val file = shard()
        ShardStore.write(file, "[\"the history that already exists\"]")
        val before = file.readText()

        val result = ShardStore.write(file, "[\"the replacement\"]", rename = { _, _ -> false })

        assertTrue("the failure must be reported, not papered over", result is ShardStore.Write.Failed)
        assertEquals("the previous shard was overwritten by a replacement that failed", before, file.readText())
        assertTrue(
            "and no temp may be left where a later load could mistake it for a shard",
            tmp.root.listFiles()!!.none { it.name.endsWith(".tmp") }
        )
    }

    @Test
    fun `a write that cannot complete leaves the previous shard intact, never truncated`() {
        val file = shard()
        ShardStore.write(file, "[\"the history that already exists\"]")
        val before = file.readText()

        // A directory nothing may write to: the replacement cannot land.
        tmp.root.setWritable(false)
        try {
            val result = ShardStore.write(file, "[\"the replacement\"]")
            assertTrue("the failure must be reported, not logged and forgotten", result is ShardStore.Write.Failed)
            assertEquals("the existing shard was damaged by a write that could not finish", before, file.readText())
        } finally {
            tmp.root.setWritable(true)
        }
    }

    @Test
    fun `a write into a directory that does not exist reports failure rather than pretending`() {
        val missing = File(File(tmp.root, "nope"), "conv.json")
        val result = ShardStore.write(missing, "[1]")
        assertTrue(result is ShardStore.Write.Failed)
        assertFalse(missing.exists())
    }

    // ── Quarantine, so an unreadable shard is never silently replaced ────────────

    @Test
    fun `quarantining an unreadable shard preserves the original bytes`() {
        val file = shard()
        file.writeText("{ this is not the json we expected")
        val moved = ShardStore.quarantine(file, at = 1_700_000_000_000)
        assertTrue("the corrupt shard must be kept, not deleted", moved != null && moved.exists())
        assertEquals("{ this is not the json we expected", moved!!.readText())
        assertFalse("and the path must be free so a fresh shard can be written", file.exists())
    }

    @Test
    fun `a second quarantine of the same conversation does not overwrite the first`() {
        val a = ShardStore.quarantineName("conv.json", at = 1_700_000_000_000)
        val b = ShardStore.quarantineName("conv.json", at = 1_700_000_001_000)
        assertNotEquals(a, b)
        assertTrue("the conversation it came from must stay legible", a.contains("conv"))
    }

    @Test
    fun `quarantining a file that is not there is not an error`() {
        assertEquals(null, ShardStore.quarantine(File(tmp.root, "absent.json"), at = 1))
    }

    // ── Dirty markers, cleared only by a commit that happened ────────────────────

    @Test
    fun `a conversation stays dirty until its write actually commits`() {
        val dirty = DirtyConversations()
        dirty.mark("a"); dirty.mark("b"); dirty.mark("c")

        val claimed = dirty.claim()
        assertEquals(setOf("a", "b", "c"), claimed)
        assertEquals(
            "claiming is not committing — the old code cleared here and lost anything that failed",
            setOf("a", "b", "c"), dirty.pending
        )

        dirty.settle(committed = setOf("a", "c"))
        assertEquals("only what reached the disk may be forgotten", setOf("b"), dirty.pending)
    }

    @Test
    fun `a failed conversation is retried on the next pass`() {
        val dirty = DirtyConversations()
        dirty.mark("a")
        dirty.claim()
        dirty.settle(committed = emptySet())
        assertEquals(setOf("a"), dirty.claim())
        dirty.settle(committed = setOf("a"))
        assertTrue(dirty.pending.isEmpty())
    }

    @Test
    fun `a conversation changed again while its write was in flight stays dirty`() {
        val dirty = DirtyConversations()
        dirty.mark("a")
        dirty.claim()
        // A new message lands mid-write: the version being written is already stale.
        dirty.mark("a")
        dirty.settle(committed = setOf("a"))
        assertEquals(
            "settling the version that was written must not discard a change made after it",
            setOf("a"), dirty.pending
        )
    }

    @Test
    fun `marking the same conversation twice queues one write`() {
        val dirty = DirtyConversations()
        dirty.mark("a"); dirty.mark("a")
        assertEquals(setOf("a"), dirty.claim())
    }
}
