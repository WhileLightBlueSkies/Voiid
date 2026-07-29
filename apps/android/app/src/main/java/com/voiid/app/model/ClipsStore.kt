package com.voiid.app.model

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voiid.app.main.clips.ClipExporter
import com.voiid.app.net.ApiError
import com.voiid.app.net.ClipQuality
import com.voiid.app.net.ClipService
import com.voiid.app.net.TokenStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

// ── Models ────────────────────────────────────────────────────────────────────────

/**
 * A clip as the UI consumes it. Distinct from [ClipService.ClipRow] (the wire shape) so
 * optimistic local state ([uploadState], [localThumbPath]) has somewhere to live.
 */
data class VClip(
    val id: String,
    val authorId: String,
    val authorName: String,
    val authorPhotoUrl: String? = null,
    val thumbUrl: String? = null,
    val caption: String? = null,
    val durationMs: Int? = null,
    val width: Int? = null,
    val height: Int? = null,
    val viewCount: Int = 0,
    val likeCount: Int = 0,
    val commentCount: Int = 0,
    val likedByMe: Boolean = false,
    val createdAt: String = "",
    val uploadState: ClipUploadState = ClipUploadState.None,
    val localThumbPath: String? = null,
) {
    companion object {
        fun from(row: ClipService.ClipRow) = VClip(
            id = row.id,
            authorId = row.author_id,
            authorName = row.author_name ?: "Unknown",
            authorPhotoUrl = row.author_photo_url,
            thumbUrl = row.thumb_url,
            caption = row.caption,
            durationMs = row.duration_ms,
            width = row.width,
            height = row.height,
            viewCount = row.view_count,
            likeCount = row.like_count,
            commentCount = row.comment_count,
            likedByMe = row.liked_by_me,
            createdAt = row.created_at,
        )
    }
}

sealed class ClipUploadState {
    object None : ClipUploadState()
    data class Uploading(val progress: Float) : ClipUploadState()
    data class Failed(val message: String) : ClipUploadState()
}

data class VClipComment(
    val id: String,
    val authorId: String,
    val authorName: String,
    val authorPhotoUrl: String? = null,
    val text: String,
    val createdAt: String = "",
    val sendState: CommentSendState = CommentSendState.SENT,
) {
    companion object {
        fun from(row: ClipService.CommentRow) = VClipComment(
            id = row.id,
            authorId = row.author_id,
            authorName = row.author_name ?: "Unknown",
            authorPhotoUrl = row.author_photo_url,
            text = row.text,
            createdAt = row.created_at,
        )
    }
}

enum class CommentSendState { SENDING, SENT, FAILED }

// ── Store ─────────────────────────────────────────────────────────────────────────

/**
 * Clips app state — paging the explore grid, background uploads, and
 * optimistic-but-reconciled likes/comments/views. Port of iOS `ClipsEngine.swift`.
 *
 * Replaces the old dummy store (a hardcoded `DummyData.clips` array whose likes were lost
 * on every relaunch). See docs/CLIPS.md.
 *
 * CLIPS ARE NOT E2EE — see the note at the top of [ClipService].
 */
class ClipsStore(app: Application) : AndroidViewModel(app) {

    private val svc = ClipService(TokenStore.get(app))

    /** The signed-in user, resolved here so the UI never has to thread identity through. */
    val myUserId: String get() = TokenStore.get(getApplication()).userId ?: ""
    val myName: String get() = com.voiid.app.store.UserDirectory.displayName(myUserId)

    val clips = mutableStateListOf<VClip>()
    val commentsByClip = mutableStateMapOf<String, List<VClipComment>>()
    val commentsLoading = mutableStateListOf<String>()

    var loading by mutableStateOf(false)
        private set
    var loadingMore by mutableStateOf(false)
        private set

    /**
     * Non-null means the LOAD FAILED. The UI must render this as an error state with a
     * retry — never as the "no clips yet" empty state, which is the single most common
     * bug in this feature shape.
     */
    var loadError by mutableStateOf<String?>(null)
        private set

    /** True once a load has completed, so the UI can tell "empty" from "not tried yet". */
    var hasLoadedOnce by mutableStateOf(false)
        private set

    private var nextCursor: String? = null
    private var reachedEnd = false

    /** In-flight like requests — a rapid double-tap must not fire two mutations. */
    private val likeInFlight = mutableSetOf<String>()

    /** Clips already counted as viewed this session (the server dedupes too). */
    private val viewedThisSession = mutableSetOf<String>()

    // ── Feed paging ───────────────────────────────────────────────────────────────

    fun refresh() {
        viewModelScope.launch {
            loading = true
            loadError = null
            runCatching { svc.feed() }
                .onSuccess { resp ->
                    // Keep still-uploading local tiles pinned at the top; the server has no
                    // row for them yet, so a naive replace makes the user's post vanish
                    // mid-upload.
                    val pending = clips.filter { it.uploadState != ClipUploadState.None }
                    clips.clear()
                    clips.addAll(pending)
                    clips.addAll(resp.clips.map(VClip::from))
                    nextCursor = resp.next_cursor
                    reachedEnd = resp.next_cursor == null
                }
                .onFailure { loadError = message(it) }
            hasLoadedOnce = true
            loading = false
        }
    }

    /** Called as the grid nears its end. Keyset-paged, never offset-paged. */
    fun loadMoreIfNeeded(index: Int) {
        if (reachedEnd || loadingMore || loading) return
        val cursor = nextCursor ?: return
        if (index < clips.size - 6) return

        viewModelScope.launch {
            loadingMore = true
            runCatching { svc.feed(cursor = cursor) }
                .onSuccess { resp ->
                    val existing = clips.map { it.id }.toSet()
                    clips.addAll(resp.clips.map(VClip::from).filter { it.id !in existing })
                    nextCursor = resp.next_cursor
                    reachedEnd = resp.next_cursor == null
                }
                .onFailure {
                    // A failed page-append must not wipe the grid the user is reading.
                    // Stop paging; pull-to-refresh is the recovery.
                    reachedEnd = true
                }
            loadingMore = false
        }
    }

    /**
     * Resolve a playback URL at the quality this connection warrants. The server may
     * serve a DIFFERENT rung than requested (a 480p source has no 1080p rendition), so
     * it reports back what it actually served.
     */
    suspend fun playbackUrl(clipId: String): String? = runCatching {
        val quality = ClipQuality.preferred(getApplication())
        svc.playback(clipId, quality).playback_url
    }.getOrNull()

    // ── Interactions ──────────────────────────────────────────────────────────────

    /**
     * Optimistic flip, then OVERWRITE with the server's authoritative count. Optimistic UI
     * must never become the source of truth.
     */
    fun toggleLike(clipId: String) {
        if (clipId in likeInFlight) return
        val i = clips.indexOfFirst { it.id == clipId }
        if (i < 0) return

        val wasLiked = clips[i].likedByMe
        val previousCount = clips[i].likeCount
        likeInFlight += clipId
        clips[i] = clips[i].copy(
            likedByMe = !wasLiked,
            likeCount = (previousCount + if (wasLiked) -1 else 1).coerceAtLeast(0),
        )

        viewModelScope.launch {
            runCatching { if (wasLiked) svc.unlike(clipId) else svc.like(clipId) }
                .onSuccess { resp ->
                    val j = clips.indexOfFirst { it.id == clipId }
                    if (j >= 0) clips[j] = clips[j].copy(
                        likedByMe = resp.liked, likeCount = resp.like_count,
                    )
                }
                .onFailure {
                    // Revert — a like that silently failed is a lie the user acts on.
                    val j = clips.indexOfFirst { it.id == clipId }
                    if (j >= 0) clips[j] = clips[j].copy(
                        likedByMe = wasLiked, likeCount = previousCount,
                    )
                }
            likeInFlight -= clipId
        }
    }

    /** Call after a >=2s watch, never on tile appearance. */
    fun markViewed(clipId: String) {
        if (clipId in viewedThisSession) return
        viewedThisSession += clipId
        viewModelScope.launch {
            runCatching { svc.markViewed(clipId) }
                .onSuccess { count ->
                    val i = clips.indexOfFirst { it.id == clipId }
                    if (i >= 0) clips[i] = clips[i].copy(viewCount = count)
                }
                .onFailure { viewedThisSession -= clipId }
        }
    }

    // ── Comments ──────────────────────────────────────────────────────────────────

    fun loadComments(clipId: String) {
        viewModelScope.launch {
            commentsLoading += clipId
            runCatching { svc.comments(clipId) }
                .onSuccess { resp -> commentsByClip[clipId] = resp.comments.map(VClipComment::from) }
                .onFailure { if (commentsByClip[clipId] == null) commentsByClip[clipId] = emptyList() }
            commentsLoading -= clipId
        }
    }

    /**
     * Inserts a SENDING row immediately, then swaps in the server row. On failure the row
     * is marked FAILED and kept — never silently dropped.
     */
    fun addComment(clipId: String, text: String, authorId: String, authorName: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return

        val tempId = "pending-${UUID.randomUUID()}"
        val pending = VClipComment(
            id = tempId, authorId = authorId, authorName = authorName,
            text = trimmed, sendState = CommentSendState.SENDING,
        )
        commentsByClip[clipId] = (commentsByClip[clipId] ?: emptyList()) + pending
        bumpCommentCount(clipId, +1)

        viewModelScope.launch {
            runCatching { svc.addComment(clipId, trimmed) }
                .onSuccess { row ->
                    commentsByClip[clipId] = commentsByClip[clipId]?.map {
                        if (it.id == tempId) VClipComment.from(row) else it
                    } ?: emptyList()
                }
                .onFailure {
                    commentsByClip[clipId] = commentsByClip[clipId]?.map {
                        if (it.id == tempId) it.copy(sendState = CommentSendState.FAILED) else it
                    } ?: emptyList()
                    bumpCommentCount(clipId, -1)
                }
        }
    }

    fun retryComment(clipId: String, commentId: String, authorId: String, authorName: String) {
        val failed = commentsByClip[clipId]?.firstOrNull {
            it.id == commentId && it.sendState == CommentSendState.FAILED
        } ?: return
        commentsByClip[clipId] = commentsByClip[clipId]?.filterNot { it.id == commentId } ?: emptyList()
        addComment(clipId, failed.text, authorId, authorName)
    }

    private fun bumpCommentCount(clipId: String, delta: Int) {
        val i = clips.indexOfFirst { it.id == clipId }
        if (i >= 0) clips[i] = clips[i].copy(
            commentCount = (clips[i].commentCount + delta).coerceAtLeast(0),
        )
    }

    // ── Posting ───────────────────────────────────────────────────────────────────

    /**
     * Optimistic post: the tile appears in the grid immediately and the upload runs in the
     * background, so Post never blocks on a 100 MB PUT. Mirrors the story composer's
     * reasoning for the same decision.
     */
    fun post(
        ladder: ClipExporter.LadderOutput,
        caption: String?,
        authorId: String,
        authorName: String,
    ) {
        val clipId = UUID.randomUUID().toString()

        // Persist the cover so the optimistic tile has something to draw.
        val thumbFile = File(getApplication<Application>().cacheDir, "clip_thumb_$clipId.jpg")
        runCatching { thumbFile.writeBytes(ladder.thumbnailJpeg) }

        clips.add(
            0,
            VClip(
                id = clipId,
                authorId = authorId,
                authorName = authorName,
                caption = caption,
                durationMs = ladder.durationMs.toInt(),
                width = ladder.width,
                height = ladder.height,
                uploadState = ClipUploadState.Uploading(0f),
                localThumbPath = thumbFile.absolutePath,
            )
        )

        viewModelScope.launch {
            runCatching {
                val presign = svc.presignUpload()

                // The cover goes FIRST and is tiny: once it lands, a failure further down
                // still leaves the tile with a real image rather than a grey box.
                setProgress(clipId, 0.05f)
                svc.uploadBlob(presign.thumb_upload_url, ladder.thumbnailJpeg, "image/jpeg")

                // Baseline is REQUIRED — it is what every playback falls back to. Streamed from
                // disk (never readBytes) so a 100 MB clip cannot OOM the process.
                val baselineSize = ladder.baseline.length()
                setProgress(clipId, 0.15f)
                svc.uploadBlob(presign.upload_url, ladder.baseline, "video/mp4")

                // Renditions are BEST-EFFORT. A failed rung is dropped from the row rather
                // than failing the post: the clip still plays from the baseline, and losing
                // a whole upload because the 480p copy timed out would be absurd.
                val keys = mutableMapOf<ClipQuality, String>()
                val sizes = mutableMapOf<ClipQuality, Long>()
                presign.renditions?.let { targets ->
                    val plan = listOf(
                        ClipQuality.SD to targets.sd,
                        ClipQuality.HD to targets.hd,
                        ClipQuality.FHD to targets.fhd,
                    )
                    var progress = 0.2f
                    val step = 0.75f / plan.size
                    for ((quality, target) in plan) {
                        val rendition = ladder.renditions[quality]
                        if (rendition != null) {
                            runCatching {
                                svc.uploadBlob(target.upload_url, rendition.first, "video/mp4")
                            }.onSuccess {
                                keys[quality] = target.key
                                sizes[quality] = rendition.second
                            }.onFailure {
                                android.util.Log.w(
                                    "VOIID",
                                    "clip rendition ${quality.wire} upload failed — continuing",
                                )
                            }
                        }
                        progress += step
                        setProgress(clipId, progress)
                    }
                }

                setProgress(clipId, 0.95f)
                svc.postClip(
                    clipId = clipId,
                    r2Key = presign.key,
                    thumbKey = presign.thumb_key,
                    caption = caption,
                    durationMs = ladder.durationMs.toInt(),
                    width = ladder.width,
                    height = ladder.height,
                    byteSize = baselineSize,
                    renditionKeys = keys,
                    renditionSizes = sizes,
                    coverSource = ladder.coverSource,
                )
            }.onSuccess {
                val i = clips.indexOfFirst { it.id == clipId }
                if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.None)
                cleanUp(ladder)
                refresh()
            }.onFailure { e ->
                val i = clips.indexOfFirst { it.id == clipId }
                if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.Failed(message(e)))
            }
        }
    }

    /** Three renditions of a 90s clip is a lot of cache to leave lying around. */
    private fun cleanUp(ladder: ClipExporter.LadderOutput) {
        ladder.renditions.values.forEach { (file, _) -> runCatching { file.delete() } }
    }

    /** Drop a failed optimistic tile (the user tapped dismiss on the retry affordance). */
    fun discardFailedUpload(clipId: String) {
        clips.removeAll { it.id == clipId && it.uploadState != ClipUploadState.None }
    }

    fun deleteClip(clipId: String) {
        val snapshot = clips.toList()
        clips.removeAll { it.id == clipId }
        viewModelScope.launch {
            runCatching { svc.deleteClip(clipId) }.onFailure {
                // Put it back rather than lie about the delete.
                clips.clear()
                clips.addAll(snapshot)
            }
        }
    }

    private fun setProgress(clipId: String, p: Float) {
        val i = clips.indexOfFirst { it.id == clipId }
        if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.Uploading(p))
    }

    private fun message(e: Throwable): String =
        (e as? ApiError)?.message ?: "Something went wrong. Try again."
}

/** "4.7M" / "732K" — the grid's view-count style. Mirrors iOS `ClipCount.compact`. */
object ClipCount {
    /**
     * Deliberately NOT `"%,d".format(n)`, which groups to "4,700,000" and blows the tile's
     * layout apart. Truncates rather than rounds (949_999 -> "949K") so a count can never
     * appear to jump past a threshold it has not reached.
     */
    fun compact(n: Int): String = when {
        n < 0 -> "0"
        n < 1_000 -> "$n"
        n < 10_000 -> String.format("%.1fK", Math.floor(n / 100.0) / 10)
        n < 1_000_000 -> "${n / 1_000}K"
        n < 10_000_000 -> String.format("%.1fM", Math.floor(n / 100_000.0) / 10)
        n < 1_000_000_000 -> "${n / 1_000_000}M"
        else -> String.format("%.1fB", Math.floor(n / 100_000_000.0) / 10)
    }
}
