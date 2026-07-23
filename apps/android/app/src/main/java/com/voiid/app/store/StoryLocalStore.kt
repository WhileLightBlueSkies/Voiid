package com.voiid.app.store

import android.content.Context
import com.voiid.app.model.Story
import com.voiid.app.model.StoryDownloadState
import com.voiid.app.model.StoryUploadState
import com.voiid.app.model.StoryViewer
import com.voiid.app.model.toStoryDownloadState
import com.voiid.app.model.toStoryUploadState
import com.voiid.app.model.wire
import com.voiid.app.net.ApiClient
import com.voiid.app.net.ChatEngine
import com.voiid.app.store.UserDirectory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Disk persistence for Stories — the ONLY place epoch SECONDS (the columns) becomes epoch MILLIS
 * (the models). Every read multiplies by 1000, every write divides by 1000, and nowhere else in
 * the codebase does this conversion for stories. See the giant time-units warning in [StoryRows].
 *
 * Local-first, exactly like [LocalStore]: the tray and the viewer render from HERE, and a failed
 * feed sync never empties the screen.
 */
object StoryLocalStore {

    private fun dao(context: Context) = VoiidDatabase.get(context).stories()

    /** Where decrypted story plaintext lands — a dedicated cache subdir we are free to sweep. */
    fun mediaDir(context: Context): File =
        File(context.cacheDir, "stories").apply { mkdirs() }

    // MARK: - Reads

    /** Every unexpired story, newest-first. Times converted to MILLIS at this boundary. */
    suspend fun liveStories(context: Context): List<Story> = withContext(Dispatchers.IO) {
        val nowSec = System.currentTimeMillis() / 1000
        runCatching { dao(context).live(nowSec) }.getOrDefault(emptyList()).mapNotNull { it.toModel() }
    }

    suspend fun story(context: Context, id: String): Story? = withContext(Dispatchers.IO) {
        runCatching { dao(context).byId(id) }.getOrNull()?.toModel()
    }

    suspend fun viewers(context: Context, storyId: String): List<StoryViewer> = withContext(Dispatchers.IO) {
        runCatching { dao(context).views(storyId) }.getOrDefault(emptyList()).map {
            StoryViewer(it.viewerUserId, UserDirectory.displayName(it.viewerUserId), it.viewedAt * 1000)
        }
    }

    suspend fun viewCount(context: Context, storyId: String): Int = withContext(Dispatchers.IO) {
        runCatching { dao(context).viewCount(storyId) }.getOrDefault(0)
    }

    suspend fun audience(context: Context, storyId: String): List<String> = withContext(Dispatchers.IO) {
        runCatching { dao(context).audience(storyId) }.getOrDefault(emptyList())
    }

    // MARK: - Writes

    /** Upsert a story (feed sync OR our own optimistic post). MILLIS -> SECONDS here. */
    suspend fun upsert(context: Context, story: Story) = withContext(Dispatchers.IO) {
        runCatching { dao(context).upsert(story.toRow()) }
    }

    /** Persist the audience of one of our stories (author-side only). */
    suspend fun saveAudience(context: Context, storyId: String, userIds: List<String>) = withContext(Dispatchers.IO) {
        if (userIds.isEmpty()) return@withContext
        runCatching { dao(context).insertAudience(userIds.distinct().map { StoryAudienceRow(storyId, it) }) }
    }

    /** Record that WE opened a story on THIS device (never transmitted). Idempotent. */
    suspend fun markViewed(context: Context, storyId: String) = withContext(Dispatchers.IO) {
        runCatching { dao(context).markViewed(storyId, System.currentTimeMillis() / 1000) }
    }

    suspend fun setDownload(context: Context, storyId: String, localPath: String?, state: StoryDownloadState) =
        withContext(Dispatchers.IO) { runCatching { dao(context).setDownload(storyId, localPath, state.wire()) } }

    suspend fun setUpload(context: Context, storyId: String, state: StoryUploadState) =
        withContext(Dispatchers.IO) { runCatching { dao(context).setUpload(storyId, state.wire()) } }

    /** Upsert a decrypted view receipt (author-side). Idempotent by (story, viewer). SECONDS in DB. */
    suspend fun recordView(context: Context, storyId: String, viewerUserId: String, viewedAtMs: Long) =
        withContext(Dispatchers.IO) {
            runCatching { dao(context).insertView(StoryViewRow(storyId, viewerUserId, viewedAtMs / 1000)) }
        }

    suspend fun deleteStory(context: Context, storyId: String) = withContext(Dispatchers.IO) {
        runCatching {
            dao(context).byId(storyId)?.localPath?.let { runCatching { File(it).delete() } }
            dao(context).delete(storyId)
            dao(context).deleteAudience(storyId)
        }
    }

    /**
     * Foreground sweep: delete every expired row AND its cached plaintext file, regardless of
     * server state (visibility never depends on the server-side reaper — see the spec). Returns
     * the number of rows swept.
     */
    suspend fun sweepExpired(context: Context): Int = withContext(Dispatchers.IO) {
        val nowSec = System.currentTimeMillis() / 1000
        val d = dao(context)
        val gone = runCatching { d.expired(nowSec) }.getOrDefault(emptyList())
        gone.forEach { row -> row.localPath?.let { runCatching { File(it).delete() } } }
        runCatching { d.deleteExpired(nowSec); d.pruneAudience(); d.pruneViews() }
        gone.size
    }

    // MARK: - Mapping (the SECONDS <-> MILLIS boundary)

    private fun StoryRow.toModel(): Story? {
        val ref = runCatching {
            ApiClient.json.decodeFromString(ChatEngine.MediaRef.serializer(), mediaJson)
        }.getOrNull() ?: return null
        return Story(
            id = id,
            authorId = authorId,
            isMine = isMine,
            createdAt = createdAt * 1000,
            expiresAt = expiresAt * 1000,
            media = ref,
            caption = caption,
            durationMs = durationMs,
            width = width,
            height = height,
            allowsReplies = allowsReplies,
            viewedAt = viewedAt?.let { it * 1000 },
            localPath = localPath,
            downloadState = downloadState.toStoryDownloadState(),
            uploadState = uploadState.toStoryUploadState(),
        )
    }

    private fun Story.toRow(): StoryRow = StoryRow(
        id = id,
        authorId = authorId,
        isMine = isMine,
        createdAt = createdAt / 1000,
        expiresAt = expiresAt / 1000,
        mediaJson = ApiClient.json.encodeToString(ChatEngine.MediaRef.serializer(), media),
        caption = caption,
        durationMs = durationMs,
        width = width,
        height = height,
        allowsReplies = allowsReplies,
        viewedAt = viewedAt?.let { it / 1000 },
        localPath = localPath,
        downloadState = downloadState.wire(),
        uploadState = uploadState.wire(),
    )
}
