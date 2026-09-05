package com.voiid.app.net

import java.io.File

/**
 * Writing a conversation shard, and admitting when it did not happen (I03).
 *
 * ── WHAT THIS REPLACES ───────────────────────────────────────────────────────────
 *
 * `persistShard` wrote a temp file, renamed it over the shard, and if the rename failed it
 * wrote the payload STRAIGHT OVER THE LIVE FILE and deleted the temp. That fallback throws
 * away the only thing the temp-and-rename dance was for: an interruption during it leaves a
 * half-written shard where a complete one used to be. Every failure was then swallowed into a
 * log line, so the caller could not tell a durable write from one that never happened.
 *
 * There is no fallback here. Either the replacement lands atomically or the previous shard is
 * left exactly as it was and the failure is returned.
 */
object ShardStore {

    sealed interface Write {
        /** On disk, replacing whatever was there, atomically. */
        object Committed : Write

        /** Not on disk. The previous contents are untouched, and the caller must keep the
         *  conversation dirty so the next pass tries again. */
        data class Failed(val error: Throwable) : Write
    }

    /**
     * Write [text] to [file] via a temp file and a rename.
     *
     * The temp lives beside the target on purpose: a rename is only atomic within a
     * filesystem, and a temp in some other directory can silently degrade to a copy.
     */
    fun write(
        file: File,
        text: String,
        /**
         * The replacement step, injectable ONLY so a test can force it to fail.
         *
         * Forcing that is otherwise impractical: POSIX `rename` needs write permission on the
         * directory, not the target, so an unwritable target still renames fine and a
         * read-only directory fails at the temp write instead — never reaching the step this
         * seam exists to pin. Production always passes the default.
         */
        rename: (File, File) -> Boolean = { from, to -> from.renameTo(to) },
    ): Write {
        val tmp = File(file.parentFile, "${file.name}.tmp")
        return try {
            tmp.writeText(text)
            if (!rename(tmp, file)) {
                // The previous shard is still intact, and that is the point. Clean up the temp
                // so a later load cannot mistake it for a real shard, and report the failure.
                tmp.delete()
                return Write.Failed(IllegalStateException("could not replace ${file.name}"))
            }
            Write.Committed
        } catch (e: Throwable) {
            runCatching { tmp.delete() }
            Write.Failed(e)
        }
    }

    /** Where a shard goes when it cannot be read. Under files/, covered by the backup allowlist. */
    private const val QUARANTINE_DIR = "messages-quarantine"

    /**
     * Move an unreadable shard aside, preserving it.
     *
     * WHY THIS EXISTS. An undecodable shard used to be skipped on load, so the conversation
     * came back EMPTY — and the next persist wrote that emptiness over the file. One bad shard
     * silently replaced a whole conversation's history, and there was nothing left to recover
     * from. Moving it aside frees the path for a fresh shard AND keeps the bytes: they may be
     * repairable, and they are certainly the evidence.
     *
     * Returns the new location, or null if there was nothing to move.
     */
    fun quarantine(file: File, at: Long): File? {
        if (!file.exists()) return null
        return runCatching {
            val dir = File(file.parentFile?.parentFile ?: file.parentFile!!, QUARANTINE_DIR).apply { mkdirs() }
            val target = File(dir, quarantineName(file.name, at))
            if (!file.renameTo(target)) {
                file.copyTo(target, overwrite = true)
                file.delete()
            }
            target
        }.getOrNull()
    }

    /** Keeps the conversation legible and stamps the time, so a repeat cannot erase the first. */
    fun quarantineName(fileName: String, at: Long): String =
        "${fileName.removeSuffix(".json")}.corrupt-$at.json"
}

/**
 * Which conversations still need writing.
 *
 * The old code took a snapshot and CLEARED the set in the same breath, then wrote. Anything
 * that failed to write had already been forgotten, so it was never retried — the app carried
 * an in-memory copy that disappeared at exit. Since M02 that also produces a false
 * acknowledgement: the client tells the server it stored a message it did not store.
 *
 * Claiming and settling are therefore separate. A marker is removed only by a write that
 * actually committed, and a conversation touched again while its write was in flight stays
 * dirty — the version that reached the disk is already out of date.
 */
class DirtyConversations {
    /**
     * Marker count per conversation. A COUNT, not a flag, because "is this still dirty?" and
     * "is this the version I just wrote?" are different questions and a boolean answers only
     * the first. A message arriving while the shard is being written bumps the count, so the
     * write that lands is recognisably stale and the marker survives it.
     */
    private val versions = LinkedHashMap<String, Long>()

    /** The counts as they were when the current pass claimed its work. */
    private var claimed = emptyMap<String, Long>()

    fun mark(conversationId: String) = synchronized(versions) {
        versions[conversationId] = (versions[conversationId] ?: 0L) + 1L
        Unit
    }

    /** What to write this pass. Does NOT clear: nothing has been written yet. */
    fun claim(): Set<String> = synchronized(versions) {
        claimed = HashMap(versions)
        LinkedHashSet(versions.keys)
    }

    /**
     * Forget only what reached the disk AND has not changed since it was claimed.
     *
     * The second half is the subtle one: a conversation touched mid-write had its new message
     * added to the in-memory copy after the bytes were serialised, so the file on disk is
     * already out of date. Clearing it here would lose that message at exit.
     */
    fun settle(committed: Set<String>) = synchronized(versions) {
        for (id in committed) {
            if (versions[id] != null && versions[id] == claimed[id]) versions.remove(id)
        }
    }

    /**
     * Forget everything, unconditionally.
     *
     * For SIGN-OUT only, where the in-memory store is being discarded along with the account
     * and there is nothing left to write. Deliberately named so it cannot be confused with
     * [settle] — clearing markers without writing is the bug this class exists to prevent.
     */
    fun clear() = synchronized(versions) { versions.clear(); claimed = emptyMap() }

    val pending: Set<String> get() = synchronized(versions) { LinkedHashSet(versions.keys) }

    val isEmpty: Boolean get() = synchronized(versions) { versions.isEmpty() }
}
