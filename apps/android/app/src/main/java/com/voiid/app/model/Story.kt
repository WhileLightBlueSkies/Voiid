package com.voiid.app.model

import com.voiid.app.net.ChatEngine
import kotlinx.serialization.Serializable

/**
 * Stories domain models + the on-the-wire envelopes.
 *
 * TIME UNITS: everything here is epoch MILLIS (like the rest of the app models). The Room columns
 * hold SECONDS; the only place that converts is [com.voiid.app.store.StoryLocalStore].
 *
 * THE PRIVACY MODEL, in one line so nobody re-litigates it in a PR: the media blob is encrypted
 * ONCE on-device with a fresh random AES-256-GCM key and PUT to R2; the key travels inside a
 * ~400-byte [StoryEnvelope] encrypted ONCE PER RECIPIENT DEVICE over that device's existing
 * Double Ratchet session. The server sees ciphertext, opaque object keys, and the set of device
 * ids that received key material (= the audience — metadata we do NOT claim to hide). It never
 * sees the media key, the real mime, the caption, the dimensions, or the bytes.
 */

/** Download lifecycle of the ciphertext blob for one story on THIS device. */
enum class StoryDownloadState { NONE, DOWNLOADING, READY, FAILED, GONE }

fun String.toStoryDownloadState(): StoryDownloadState = when (this) {
    "downloading" -> StoryDownloadState.DOWNLOADING
    "ready" -> StoryDownloadState.READY
    "failed" -> StoryDownloadState.FAILED
    "gone" -> StoryDownloadState.GONE
    else -> StoryDownloadState.NONE
}

fun StoryDownloadState.wire(): String = when (this) {
    StoryDownloadState.DOWNLOADING -> "downloading"
    StoryDownloadState.READY -> "ready"
    StoryDownloadState.FAILED -> "failed"
    StoryDownloadState.GONE -> "gone"
    StoryDownloadState.NONE -> "none"
}

/** Upload lifecycle of one of OUR outgoing stories (optimistic post). */
enum class StoryUploadState { NONE, UPLOADING, SENT, FAILED }

fun String.toStoryUploadState(): StoryUploadState = when (this) {
    "uploading" -> StoryUploadState.UPLOADING
    "sent" -> StoryUploadState.SENT
    "failed" -> StoryUploadState.FAILED
    else -> StoryUploadState.NONE
}

fun StoryUploadState.wire(): String = when (this) {
    StoryUploadState.UPLOADING -> "uploading"
    StoryUploadState.SENT -> "sent"
    StoryUploadState.FAILED -> "failed"
    StoryUploadState.NONE -> "none"
}

/** One story (ours or someone else's). Times in epoch MILLIS. */
data class Story(
    val id: String,
    val authorId: String,
    val isMine: Boolean,
    val createdAt: Long,
    val expiresAt: Long,
    /** The R2 object key + media key + nonce + ciphertext hash. The key stops on-device. */
    val media: ChatEngine.MediaRef,
    val caption: String,
    val durationMs: Long?,
    val width: Int?,
    val height: Int?,
    val allowsReplies: Boolean,
    /** Epoch MILLIS, null = unseen. Recorded on this device only, never transmitted. */
    val viewedAt: Long?,
    /** Absolute path to the decrypted plaintext file, once downloaded. */
    val localPath: String?,
    val downloadState: StoryDownloadState,
    val uploadState: StoryUploadState,
) {
    val isImage: Boolean get() = media.mime.startsWith("image/")
    val isVideo: Boolean get() = media.mime.startsWith("video/")
    fun isExpired(nowMs: Long = System.currentTimeMillis()): Boolean = expiresAt <= nowMs
}

/**
 * A *context* — one author's set of unexpired stories, the unit the tray and the outer viewer
 * pager work in (one row / one page per author, never one per story).
 */
data class StoryContext(
    val authorId: String,
    val authorName: String,
    val photoUrl: String?,
    val stories: List<Story>,
) {
    val isMine: Boolean get() = stories.firstOrNull()?.isMine == true
    val hasUnviewed: Boolean get() = stories.any { it.viewedAt == null }
    val newest: Story? get() = stories.maxByOrNull { it.createdAt }
    /** The next story to auto-advance to: first unviewed, else the first. */
    val startIndex: Int get() = stories.indexOfFirst { it.viewedAt == null }.let { if (it < 0) 0 else it }
}

/** One viewer of one of OUR stories (author-side, from decrypted receipts). */
data class StoryViewer(val userId: String, val name: String, val viewedAtMs: Long)

// MARK: - Wire envelopes (the AUTHENTICATED PLAINTEXT of a ratchet message)
//
// There is NO AAD parameter on any AEAD in e2e-core, so story_id / author / expiry cannot be
// bound at the AEAD layer — they go INSIDE the plaintext, where GCM authenticates them. Receivers
// MUST validate them (see StoryEngine.validate). Field names match the iOS Codable + the spec.

@Serializable
data class StoryEnvelope(
    val v: Int? = 1,
    val t: String? = "story",
    val story_id: String,
    val author_id: String,
    val created_at: Long,       // epoch MILLIS
    val expires_at: Long,       // epoch MILLIS (author's claim)
    val media: ChatEngine.MediaRef,   // the SAME MediaRef shape used for chat media — the real mime lives here
    // NULLABLE, not just defaulted. Kotlin defaults cover an ABSENT key, but iOS's
    // JSONEncoder emits `"caption": null` explicitly for a nil Optional, and kotlinx
    // throws on an explicit null for a non-nullable property. That threw on every
    // iOS→Android moment and the story was dropped for good (the feed is deliver-once).
    // The mirror of the Android→iOS bug already fixed in iOS's Story.swift.
    val caption: String? = "",
    val durationMs: Long? = null,
    val width: Int? = null,
    val height: Int? = null,
    val allowsReplies: Boolean? = true,
)

/** A reply to a story — sent as an ORDINARY 1:1 message with content_type "story_reply". */
@Serializable
data class StoryReplyEnvelope(
    val v: Int = 1,
    val t: String = "story_reply",
    val storyId: String,
    val storyAuthorId: String,
    val storyCreatedAt: Long,
    val text: String,
    val reaction: String? = null,
)

/** A view receipt — encrypted once per AUTHOR device. The viewer id is IN here, not in a column. */
@Serializable
data class StoryViewReceipt(
    val v: Int = 1,
    val t: String = "story_view",
    val story_id: String,
    val viewer_id: String,
    val viewed_at: Long,        // epoch MILLIS
)
