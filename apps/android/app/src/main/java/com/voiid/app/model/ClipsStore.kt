package com.voiid.app.model

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voiid.app.main.clips.ClipEdit
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

    /**
     * Set when a commit was rejected with `profile_required`. The Clips screen observes it to
     * raise the handle picker, so an upload parked at the last step is recoverable rather than
     * silently stuck behind a generic "failed" tile.
     */
    var needsCreatorProfile by mutableStateOf(false)

    /**
     * Uploads whose bytes reached R2 but whose row was never created, keyed by clip id.
     * Holding the lambda means the retry re-sends only the row — the presigned keys and
     * measured sizes it closes over are still valid, so nothing is uploaded twice.
     */
    private val pendingCommits = mutableMapOf<String, suspend () -> Unit>()

    val hasPendingCommits: Boolean get() = pendingCommits.isNotEmpty()

    /**
     * Everything a failed upload needs to be attempted again. Held so the retry does not
     * re-run the export: transcoding a 90s clip into three renditions is the expensive part,
     * and the files are already on disk.
     */
    private data class PendingUpload(
        val ladder: ClipExporter.LadderOutput,
        val caption: String?,
    )
    private val pendingUploads = mutableStateMapOf<String, PendingUpload>()

    /** Whether a failed tile can be retried (as opposed to only dismissed). */
    fun canRetryUpload(clipId: String): Boolean = pendingUploads.containsKey(clipId)

    /**
     * Run a failed upload again from the start. The export is not repeated — the ladder is
     * still on disk, which is the whole point of holding it.
     */
    fun retryUpload(clipId: String) {
        val pending = pendingUploads[clipId] ?: return
        val i = clips.indexOfFirst { it.id == clipId }
        if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.Uploading(0f))
        viewModelScope.launch { uploadLadder(clipId, pending.ladder, pending.caption, null) }
    }

    /**
     * Finish every upload parked on the profile gate. Called once a creator profile exists;
     * safe to call when there is nothing pending.
     */
    fun retryPendingCommits() {
        if (pendingCommits.isEmpty()) return
        val pending = pendingCommits.toMap()
        pendingCommits.clear()
        viewModelScope.launch {
            for ((clipId, commit) in pending) {
                runCatching { commit() }
                    .onSuccess {
                        val i = clips.indexOfFirst { it.id == clipId }
                        if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.None)
                    }
                    .onFailure { e ->
                        val i = clips.indexOfFirst { it.id == clipId }
                        if (i >= 0) clips[i] =
                            clips[i].copy(uploadState = ClipUploadState.Failed(message(e)))
                        // Keep it parked so a later attempt can still finish it.
                        pendingCommits[clipId] = commit
                    }
            }
            refresh()
        }
    }

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
    /** A minted playback URL plus the moment it stops being usable. */
    private data class CachedPlayback(
        val url: String,
        val quality: ClipQuality,
        val expiresAtMs: Long,
    )

    /**
     * PLAYBACK URL CACHE — the single largest scroll-stutter fix in this screen.
     *
     * Every page change used to mint a fresh presigned URL, which is a network round-trip
     * sitting directly on the critical path of a swipe. Swiping back to a clip seen two
     * seconds ago re-fetched it, and on a slow connection ExoPlayer could not even begin
     * buffering until that round-trip returned — exactly the "laggy" feel.
     *
     * Presigned URLs are valid for an hour, so they are cacheable by construction; the only
     * requirement is never to serve one past its expiry.
     */
    private val playbackCache = mutableMapOf<String, CachedPlayback>()

    /**
     * Safety margin subtracted from the server's TTL. A URL that passes the freshness check
     * must stay valid long enough to finish playing the clip it was minted for — clips cap
     * at 90s, so five minutes covers a paused-and-resumed watch with room to spare.
     */
    private val PLAYBACK_URL_SAFETY_MARGIN_MS = 300_000L

    /**
     * Fallback TTL for a server that does not send `expires_in`. Deliberately far shorter
     * than the real hour: guessing high risks handing ExoPlayer a dead URL, while the cost
     * of guessing low is one extra round-trip.
     */
    private val PLAYBACK_URL_FALLBACK_TTL_S = 600L

    suspend fun playbackUrl(clipId: String): String? {
        val quality = ClipQuality.preferred(getApplication())
        val now = System.currentTimeMillis()

        // Reusable only if still valid AND minted for the quality we now want — the network
        // may have moved from wifi to cellular, and replaying a stale 1080p URL on a metered
        // connection is worse than re-minting.
        playbackCache[clipId]?.let { hit ->
            if (hit.quality == quality && hit.expiresAtMs > now) return hit.url
        }

        return runCatching {
            val resp = svc.playback(clipId, quality)
            val ttlMs = (resp.expires_in ?: PLAYBACK_URL_FALLBACK_TTL_S) * 1000
            playbackCache[clipId] = CachedPlayback(
                url = resp.playback_url,
                quality = quality,
                // coerceAtLeast so a pathologically short server TTL still caches briefly
                // rather than storing an already-expired entry that re-fetches every swipe.
                expiresAtMs = now + (ttlMs - PLAYBACK_URL_SAFETY_MARGIN_MS).coerceAtLeast(60_000),
            )
            resp.playback_url
        }.getOrNull()
    }

    /** Drops entries that can no longer be used, so the map does not grow all session. */
    fun prunePlaybackCache() {
        val now = System.currentTimeMillis()
        playbackCache.entries.removeAll { it.value.expiresAtMs <= now }
    }

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
     * Optimistic post: the tile appears in the grid immediately and the export + upload run
     * in the background, so Post never blocks on a 100 MB PUT. Mirrors the story composer's
     * reasoning for the same decision.
     *
     * THE EXPORT RUNS HERE, on viewModelScope, and that placement is the whole point. It
     * used to run in the composer's rememberCoroutineScope, which the composer's own
     * onClose() tears down — so closing the composer (the very next thing the user does)
     * cancelled the export before it produced a single frame and the upload silently never
     * happened. viewModelScope outlives the composer; a composable's scope cannot be used
     * for work that is supposed to continue after it leaves the screen.
     */
    fun post(
        sourceFile: File,
        edit: ClipEdit,
        caption: String?,
        authorId: String,
        authorName: String,
    ) {
        val clipId = UUID.randomUUID().toString()

        // The tile appears NOW, before the export, showing indeterminate progress. Waiting
        // for the export to finish would leave the grid looking like the post was dropped
        // for however many seconds a 90s transcode takes.
        clips.add(
            0,
            VClip(
                id = clipId,
                authorId = authorId,
                authorName = authorName,
                caption = caption,
                uploadState = ClipUploadState.Uploading(0f),
            )
        )

        viewModelScope.launch {
            val ladder = withContext(Dispatchers.IO) {
                runCatching { ClipExporter.exportLadder(getApplication(), sourceFile, edit) }
                    .getOrNull()
            }
            if (ladder == null) {
                val i = clips.indexOfFirst { it.id == clipId }
                if (i >= 0) clips[i] = clips[i].copy(
                    uploadState = ClipUploadState.Failed("Couldn't process that video."),
                )
                return@launch
            }

            // Held so a FAILED upload can be run again from the tile, rather than offering
            // only "Dismiss" — which threw away a video the user had already waited through
            // an export for. The ladder files stay on disk until success or explicit discard.
            pendingUploads[clipId] = PendingUpload(ladder, caption)

            // Persist the cover so the tile has something real to draw from here on.
            val thumbFile = File(getApplication<Application>().cacheDir, "clip_thumb_$clipId.jpg")
            runCatching { thumbFile.writeBytes(ladder.thumbnailJpeg) }
            val ti = clips.indexOfFirst { it.id == clipId }
            if (ti >= 0) clips[ti] = clips[ti].copy(
                durationMs = ladder.durationMs.toInt(),
                width = ladder.width,
                height = ladder.height,
                localThumbPath = thumbFile.absolutePath,
            )

            uploadLadder(clipId, ladder, caption, sourceFile)
        }
    }

    /**
     * One attempt at uploading an already-exported ladder and committing the row. Separate
     * from [post] so [retryUpload] can run it again WITHOUT re-exporting — the transcode is
     * the expensive part and its output is still on disk.
     *
     * [sourceFile] is the copy made by copyAndProbe, reaped on success. Null on a retry: the
     * first attempt already deleted it.
     */
    private suspend fun uploadLadder(
        clipId: String,
        ladder: ClipExporter.LadderOutput,
        caption: String?,
        sourceFile: File?,
    ) {
            runCatching {
                val presign = svc.presignUpload()

                // The cover goes FIRST and is tiny: once it lands, a failure further down
                // still leaves the tile with a real image rather than a grey box.
                setProgress(clipId, 0.05f)
                svc.uploadBlob(presign.thumb_upload_url, ladder.thumbnailJpeg, "image/jpeg")

                // Baseline is REQUIRED — it is what every playback falls back to. Streamed from
                // disk (never readBytes) so a 100 MB clip cannot OOM the process.
                val baselineSize = ladder.baseline.length()
                // 0.10..0.40 is the baseline's own band, advanced by BYTES SENT rather than
                // jumped at the end. The renditions take 0.40..0.95 below.
                setProgress(clipId, 0.10f)
                svc.uploadBlob(presign.upload_url, ladder.baseline, "video/mp4") { f ->
                    setProgress(clipId, 0.10f + 0.30f * f)
                }

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
                    var progress = 0.40f
                    val step = 0.55f / plan.size
                    for ((quality, target) in plan) {
                        val rendition = ladder.renditions[quality]
                        if (rendition != null) {
                            val base = progress
                            runCatching {
                                svc.uploadBlob(
                                    target.upload_url, rendition.first, "video/mp4",
                                ) { f -> setProgress(clipId, base + step * f) }
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
                // Committing the row is retried on `profile_required` ALONE. The bytes are
                // already in R2 by this point, so re-running `post` would re-upload the whole
                // ladder; and the gate is normally satisfied before the composer even opens,
                // so reaching here means the profile vanished mid-flight (deleted on another
                // device, or a first post racing the check). Only the commit is repeated.
                val commit: suspend () -> Unit = {
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
                }
                try {
                    commit()
                } catch (e: ApiError.Http) {
                    if (e.code != "profile_required") throw e
                    // Park the upload rather than fail it: the video is safely in R2, and
                    // discarding it because the user has no handle yet would throw away work
                    // they can still complete. The feed surfaces the prompt; retryPendingCommits
                    // finishes the job once a profile exists.
                    val i = clips.indexOfFirst { it.id == clipId }
                    if (i >= 0) clips[i] = clips[i].copy(
                        uploadState = ClipUploadState.Failed("Choose a handle to finish posting."),
                    )
                    pendingCommits[clipId] = commit
                    needsCreatorProfile = true
                    return
                }
            }.onSuccess {
                val i = clips.indexOfFirst { it.id == clipId }
                if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.None)
                pendingUploads.remove(clipId)
                cleanUp(ladder)
                // The copy made by copyAndProbe is ours to reap; the export is done with it.
                sourceFile?.let { runCatching { it.delete() } }
                refresh()
            }.onFailure { e ->
                // The pending entry is deliberately KEPT so retryUpload can run this again.
                // It is dropped only on success or on an explicit discard.
                val i = clips.indexOfFirst { it.id == clipId }
                if (i >= 0) clips[i] = clips[i].copy(uploadState = ClipUploadState.Failed(message(e)))
            }
    }

    /** Three renditions of a 90s clip is a lot of cache to leave lying around. */
    private fun cleanUp(ladder: ClipExporter.LadderOutput) {
        ladder.renditions.values.forEach { (file, _) -> runCatching { file.delete() } }
    }

    /** Drop a failed optimistic tile (the user tapped dismiss on the retry affordance). */
    fun discardFailedUpload(clipId: String) {
        clips.removeAll { it.id == clipId && it.uploadState != ClipUploadState.None }
        // Drop any parked commit too, or a tile the user dismissed would quietly reappear
        // the next time the gate is satisfied.
        pendingCommits.remove(clipId)
        // Discard is the ONLY place the retained ladder is reaped on failure — it is kept
        // across a failed attempt so retry has bytes to send, so without this a dismissed
        // upload would leave three renditions of a 90s video in the cache forever.
        pendingUploads.remove(clipId)?.let { pending ->
            cleanUp(pending.ladder)
            runCatching { pending.ladder.baseline.delete() }
        }
    }

    fun deleteClip(clipId: String) {
        val snapshot = clips.toList()
        val mineSnapshot = myClips.toList()
        clips.removeAll { it.id == clipId }
        myClips.removeAll { it.id == clipId }
        viewModelScope.launch {
            runCatching { svc.deleteClip(clipId) }.onFailure {
                // Put it back rather than lie about the delete.
                clips.clear()
                clips.addAll(snapshot)
                myClips.clear()
                myClips.addAll(mineSnapshot)
            }
        }
    }

    // ── My Clips ──────────────────────────────────────────────────────────────────

    val myClips = mutableStateListOf<VClip>()
    var myLoading by mutableStateOf(false)
        private set
    var myLoadError by mutableStateOf<String?>(null)
        private set
    var myHasLoadedOnce by mutableStateOf(false)
        private set
    private var myNextCursor: String? = null
    private var myReachedEnd = false

    fun refreshMine() {
        viewModelScope.launch {
            myLoading = true
            myLoadError = null
            runCatching { svc.mine() }
                .onSuccess { resp ->
                    myClips.clear()
                    myClips.addAll(resp.clips.map(VClip::from))
                    myNextCursor = resp.next_cursor
                    myReachedEnd = resp.next_cursor == null
                }
                .onFailure { myLoadError = message(it) }
            myHasLoadedOnce = true
            myLoading = false
        }
    }

    fun loadMoreMineIfNeeded(index: Int) {
        if (myReachedEnd || myLoading) return
        val cursor = myNextCursor ?: return
        if (index < myClips.size - 6) return
        viewModelScope.launch {
            runCatching { svc.mine(cursor = cursor) }
                .onSuccess { resp ->
                    val existing = myClips.map { it.id }.toSet()
                    myClips.addAll(resp.clips.map(VClip::from).filter { it.id !in existing })
                    myNextCursor = resp.next_cursor
                    myReachedEnd = resp.next_cursor == null
                }
                .onFailure { myReachedEnd = true }
        }
    }

    /**
     * Edit the caption and/or cover of an existing clip. The VIDEO is never replaced —
     * people have already watched and engaged with those bytes, so swapping them under a
     * stable id would turn existing likes into an endorsement of something nobody saw.
     *
     * [onResult] receives null on success, or a message to show.
     */
    fun updateClip(
        clipId: String,
        caption: String?,
        clearCaption: Boolean,
        newCoverJpeg: ByteArray? = null,
        onResult: (String?) -> Unit = {},
    ) {
        viewModelScope.launch {
            runCatching {
                var thumbKey: String? = null
                if (newCoverJpeg != null) {
                    val presign = svc.presignThumb(clipId)
                    svc.uploadBlob(presign.thumb_upload_url, newCoverJpeg, "image/jpeg")
                    thumbKey = presign.thumb_key
                }
                svc.updateClip(
                    clipId = clipId,
                    caption = caption,
                    clearCaption = clearCaption,
                    thumbKey = thumbKey,
                    coverSource = if (thumbKey != null) "upload" else null,
                )
            }.onSuccess { row ->
                // Replace in BOTH lists — the same clip is on the explore grid too, and
                // leaving a stale caption there is exactly the kind of thing that reads
                // as "the edit didn't save".
                val updated = VClip.from(row)
                listOf(myClips, clips).forEach { list ->
                    val i = list.indexOfFirst { it.id == clipId }
                    if (i >= 0) list[i] = updated
                }
                onResult(null)
            }.onFailure { onResult(message(it)) }
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
