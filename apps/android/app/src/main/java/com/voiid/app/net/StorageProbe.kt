package com.voiid.app.net

import android.content.Context
import com.voiid.app.store.VoiidDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Measures what Voiid actually occupies on this device, and clears the only thing on it
 * that is genuinely re-derivable. Port of iOS `StorageProbe.swift`.
 *
 * WHY A PROBE TYPE AT ALL: a Storage screen is worthless unless its numbers are measured
 * rather than asserted. Everything here runs on [Dispatchers.IO] and hands back a plain
 * data class of Ints/Longs, so the composable renders a value it cannot recompute by
 * accident on a recomposition.
 *
 * WHAT IS DELIBERATELY NOT HERE — same reasoning as iOS:
 *  - No "clear message history": `voiid_messages.json` is live (ChatEngine rewrites it on
 *    every append/receipt) and is the plaintext `BackupManager.backupNow()` seals for the
 *    encrypted cloud backup. Deleting it loses history the server's ciphertext can never
 *    decrypt again.
 *  - No "clear database": deleting `conversations`/`messages` rows loses the same
 *    plaintext, and clearing `users` would blank every direct-chat title (resolved from
 *    `peer_user_id` at read time).
 *  - No media cache clear beyond Coil's disk cache: `MediaService.download`-fetched bytes
 *    otherwise never touch disk.
 */
data class StorageSnapshot(
    /** Everything under [Context.getFilesDir] + the Room DB — walked file by file. */
    val containerTotalBytes: Long,
    /** `voiid.db` + its `-wal`/`-shm` siblings, summed as ONE number (real disk usage). */
    val databaseBytes: Long,
    /** `voiid_messages.json` — the decrypt-once plaintext store ChatEngine owns. */
    val messageHistoryBytes: Long,
    val conversationCount: Int?,
    val messageCount: Int?,
    val callCount: Int?,
    /** Coil's image disk cache — the only genuinely re-derivable on-disk cache here. */
    val imageCacheBytes: Long,
    /** Orphaned `vn*.m4a` voice-note scratch files in [Context.getCacheDir]. */
    val temporaryFileBytes: Long,
) {
    /** Whatever in files/ isn't the database or the message store. Keeps itemised rows
     *  visibly summing to the total instead of leaving an unexplained gap. */
    val otherBytes: Long get() = maxOf(0L, containerTotalBytes - databaseBytes - messageHistoryBytes)

    /** Bytes [StorageProbe.clearCaches] can actually reclaim. Drives the Clear button. */
    val clearableBytes: Long get() = imageCacheBytes + temporaryFileBytes
}

object StorageProbe {

    suspend fun measure(context: Context): StorageSnapshot = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext

        val dbFile = appContext.getDatabasePath("voiid.db")
        val databaseBytes = allocatedSize(dbFile) +
            allocatedSize(File(dbFile.path + "-wal")) +
            allocatedSize(File(dbFile.path + "-shm"))

        val messageStoreFile = File(appContext.filesDir, "voiid_messages.json")
        val messageHistoryBytes = allocatedSize(messageStoreFile)

        val filesWalked = directoryAllocatedSize(appContext.filesDir)
        val containerTotal = maxOf(filesWalked, databaseBytes + messageHistoryBytes)

        val db = VoiidDatabase.get(appContext)
        val counts = runCatching {
            Triple(db.conversations().count(), db.messages().count(), db.calls().count())
        }.getOrNull()

        val imageCacheDir = File(appContext.cacheDir, "image_cache")
        val imageCacheBytes = directoryAllocatedSize(imageCacheDir)

        StorageSnapshot(
            containerTotalBytes = containerTotal,
            databaseBytes = databaseBytes,
            messageHistoryBytes = messageHistoryBytes,
            conversationCount = counts?.first,
            messageCount = counts?.second,
            callCount = counts?.third,
            imageCacheBytes = imageCacheBytes,
            temporaryFileBytes = orphanedVoiceNoteFiles(appContext).sumOf { allocatedSize(it) },
        )
    }

    /** Clears Coil's disk cache and orphaned voice-note scratch files. Both are re-created
     *  on demand: a thumbnail on the next load, a scratch file on the next recording. */
    suspend fun clearCaches(context: Context) = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        File(appContext.cacheDir, "image_cache").deleteRecursively()
        for (f in orphanedVoiceNoteFiles(appContext)) f.delete()
    }

    /**
     * `vn*.m4a` scratch files older than [minimumAgeMillis] in cacheDir — mirrors iOS's
     * `orphanedVoiceNoteURLs`. A short-lived recording still being written is skipped so a
     * live recorder never has its file pulled out from under it.
     */
    private fun orphanedVoiceNoteFiles(context: Context, minimumAgeMillis: Long = 120_000): List<File> {
        val cutoff = System.currentTimeMillis() - minimumAgeMillis
        val files = context.cacheDir.listFiles() ?: return emptyList()
        return files.filter {
            it.isFile && it.name.startsWith("vn") && it.name.endsWith(".m4a") &&
                it.lastModified() < cutoff
        }
    }

    private fun allocatedSize(file: File): Long = if (file.isFile) file.length() else 0L

    private fun directoryAllocatedSize(dir: File): Long {
        if (!dir.exists()) return 0L
        var total = 0L
        dir.walkTopDown().forEach { f -> if (f.isFile) total += f.length() }
        return total
    }
}
