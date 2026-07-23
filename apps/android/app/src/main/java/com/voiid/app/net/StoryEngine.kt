package com.voiid.app.net

import android.content.Context
import com.voiid.app.model.Story
import com.voiid.app.model.StoryDownloadState
import com.voiid.app.model.StoryEnvelope
import com.voiid.app.model.StoryUploadState
import com.voiid.app.model.StoryViewReceipt
import com.voiid.app.store.StoryLocalStore
import com.voiid.app.store.UserDirectory
import uniffi.voiid.MediaKey
import uniffi.voiid.decryptMedia
import uniffi.voiid.encryptMedia
import java.io.File
import java.util.UUID

/**
 * Stories crypto + sync orchestration — the seam between [StoryService] (dumb transport),
 * [ChatEngine] (the frozen Double Ratchet primitives, widened to a broadcast fan-out), and
 * [StoryLocalStore] (local-first render). Mirrors iOS StoryEngine.
 *
 * THE PROTOCOL, once, so no one has to reread the spec: a story is `ChatEngine.sendMedia` with the
 * recipient set widened from one peer to a chosen audience. The blob is encrypted ONCE with a fresh
 * random AES-256-GCM key, the ciphertext is PUT ONCE to R2, and a ~400-byte envelope carrying that
 * key is encrypted ONCE PER TARGET DEVICE over that device's existing ratchet. The server stores
 * ciphertext, opaque object keys, and routing ids only.
 */
class StoryEngine private constructor(context: Context) {

    companion object {
        @Volatile private var instance: StoryEngine? = null
        fun get(context: Context): StoryEngine =
            instance ?: synchronized(this) {
                instance ?: StoryEngine(context.applicationContext).also { instance = it }
            }

        private const val TWENTY_FOUR_HOURS_MS = 24L * 60 * 60 * 1000
    }

    private val appContext = context.applicationContext
    private val tokens = TokenStore.get(appContext)
    private val e2e = E2EManager.get(appContext)
    private val chat = ChatEngine.get(appContext)
    private val service = StoryService(tokens)

    /** One decrypted, validated story returned from a feed sync (already persisted locally). */
    data class SyncResult(val newStories: List<Story>)

    // MARK: - Posting

    /**
     * Post a story to [audienceUserIds]. Ordering deliberately matches `sendMedia`: encrypt + upload
     * happen FIRST (they don't touch the ratchet), then the ratchet-mutating fan-out. We already hold
     * the plaintext, so the story is cached READY on this device instantly — "Your story" needs no
     * round-trip. Returns the stored Story (isMine, uploadState = SENT).
     */
    suspend fun postStory(
        bytes: ByteArray, mime: String, caption: String,
        width: Int?, height: Int?, durationMs: Long?, allowsReplies: Boolean,
        audienceUserIds: List<String>,
    ): Story {
        val myId = tokens.userId ?: throw ApiError.NotAuthenticated
        val storyId = UUID.randomUUID().toString()

        // 1. Encrypt the blob → ciphertext + fresh random media key. 2. PUT ciphertext to R2.
        val enc = encryptMedia(bytes)
        val r2Key = service.uploadCiphertext(enc.ciphertext)
        val ref = ChatEngine.MediaRef(r2Key, mime, enc.mediaKey.key, enc.mediaKey.nonce, enc.mediaKey.ciphertextSha256)

        val createdAt = System.currentTimeMillis()
        val claimExpiry = createdAt + TWENTY_FOUR_HOURS_MS   // the author's claim; server recomputes

        // 3. Build the AUTHENTICATED PLAINTEXT envelope (story_id/author/expiry are validated by the
        //    receiver because there is no AAD on e2e-core's AEAD).
        val env = StoryEnvelope(
            story_id = storyId, author_id = myId,
            created_at = createdAt, expires_at = claimExpiry,
            media = ref, caption = caption,
            durationMs = durationMs, width = width, height = height, allowsReplies = allowsReplies,
        )
        val envJson = ApiClient.json.encodeToString(StoryEnvelope.serializer(), env)

        // 4. Fan out: encrypt ONCE PER TARGET DEVICE (audience devices + our own linked devices).
        val bcast = chat.encryptBroadcast(envJson.encodeToByteArray(), audienceUserIds, includeOwnDevices = true)
        if (bcast.isEmpty()) throw ApiError.Http(409, "no deliverable devices for this audience")
        val keys = bcast.map { StoryService.KeyEntry(it.recipientDeviceId, it.ciphertext) }

        // 5. POST — server computes expires_at and returns it. Bounded at 1000 keys/POST by the API.
        val resp = service.postStory(
            storyId, r2Key, mediaMime = "application/octet-stream",
            byteSize = enc.ciphertext.size.toLong(), senderDeviceId = e2e.deviceId, keys = keys,
        )
        val expiresAt = parseTs(resp.expires_at) ?: claimExpiry

        // 6. Cache the plaintext we already hold so "Your story" renders with no download.
        val localPath = runCatching {
            File(StoryLocalStore.mediaDir(appContext), "$storyId.bin").also { it.writeBytes(bytes) }.absolutePath
        }.getOrNull()

        val story = Story(
            id = storyId, authorId = myId, isMine = true,
            createdAt = createdAt, expiresAt = expiresAt, media = ref, caption = caption,
            durationMs = durationMs, width = width, height = height, allowsReplies = allowsReplies,
            viewedAt = createdAt, localPath = localPath,
            downloadState = if (localPath != null) StoryDownloadState.READY else StoryDownloadState.NONE,
            uploadState = StoryUploadState.SENT,
        )
        StoryLocalStore.upsert(appContext, story)
        StoryLocalStore.saveAudience(appContext, storyId, audienceUserIds)
        android.util.Log.i("VOIID", "📸 story posted id=$storyId keys=${keys.size}/${audienceUserIds.size} users")
        return story
    }

    // MARK: - Feed sync

    /** Fetch this device's pending story keys, decrypt+validate each, persist. Local-first: a failed
     *  network call throws to the caller but never touches the already-stored feed. */
    suspend fun syncFeed(): SyncResult {
        val myId = tokens.userId
        val existing = runCatching { StoryLocalStore.liveStories(appContext).map { it.id }.toHashSet() }
            .getOrDefault(HashSet())
        val rows = service.feed(e2e.deviceId)
        val fresh = mutableListOf<Story>()
        for (row in rows) {
            if (existing.contains(row.story_id)) continue    // decrypt-once dedup
            val plain = chat.decryptBroadcast(row.ciphertext, row.author_id, row.author_device_id)
            if (plain == null) {
                android.util.Log.w("VOIID", "⚠️ story key undecryptable id=${row.story_id}")
                continue
            }
            val env = runCatching { ApiClient.json.decodeFromString(StoryEnvelope.serializer(), plain) }.getOrNull()
                ?: continue
            val story = validate(env, row, myId) ?: continue
            StoryLocalStore.upsert(appContext, story)
            fresh.add(story)
        }
        return SyncResult(fresh)
    }

    /**
     * Receiver-side validation (§1.5) — the server does NOT do this for you; any authenticated user
     * can POST a story targeting your device id. Returns the Story to store, or null to DROP.
     */
    private fun validate(env: StoryEnvelope, row: StoryService.FeedStory, myId: String?): Story? {
        if (env.story_id != row.story_id) return null                       // 1. id must bind
        if (env.author_id != row.author_id) return null                     // 2. no reattribution
        if (env.media.mediaUrl != row.r2_key) return null                   // 3. object key must match
        val createdAt = parseTs(row.created_at) ?: env.created_at
        // 4. clamp the author's expiry claim to created_at + 24h (+60s skew).
        val serverExpiry = parseTs(row.expires_at)
        val cappedClaim = createdAt + TWENTY_FOUR_HOURS_MS + 60_000
        val expiresAt = (serverExpiry ?: minOf(env.expires_at, cappedClaim)).coerceAtMost(cappedClaim)
        // 5. author must be a known contact (in the local directory) and not ourselves-as-stranger.
        //    Our OWN stories are always allowed; a story from someone we have never seen is dropped
        //    silently so strangers can't push media into the feed.
        val isMine = env.author_id == myId
        if (!isMine && UserDirectory.user(env.author_id) == null) {
            android.util.Log.w("VOIID", "🚫 story from unknown author dropped id=${env.story_id}")
            return null
        }
        return Story(
            id = env.story_id, authorId = env.author_id, isMine = isMine,
            createdAt = createdAt, expiresAt = expiresAt, media = env.media, caption = env.caption,
            durationMs = env.durationMs, width = env.width, height = env.height,
            allowsReplies = env.allowsReplies, viewedAt = null, localPath = null,
            downloadState = StoryDownloadState.NONE, uploadState = StoryUploadState.NONE,
        )
    }

    /** Delivered/recipient device counts for our OWN live stories (routing metadata the server
     *  already has — not a view). Keyed by story_id. */
    suspend fun mineCounts(): Map<String, Pair<Int, Int>> =
        runCatching { service.mine(e2e.deviceId) }.getOrDefault(emptyList())
            .associate { it.story_id to (it.delivered_device_count to it.recipient_device_count) }

    // MARK: - Download (on open)

    /**
     * Ensure the decrypted plaintext file for [story] exists, downloading + decrypting on demand.
     * Returns the local file path, or null on failure (the viewer surfaces "couldn't load" /
     * "no longer available"). `decryptMedia` verifies the ciphertext SHA-256 before decrypting.
     */
    suspend fun ensureDownloaded(story: Story): String? {
        story.localPath?.let { p -> if (File(p).exists()) return p }
        StoryLocalStore.setDownload(appContext, story.id, null, StoryDownloadState.DOWNLOADING)
        return try {
            val ciphertext = service.downloadCiphertext(story.id)
            val plain = decryptMedia(MediaKey(story.media.key, story.media.nonce, story.media.sha256), ciphertext)
            val file = File(StoryLocalStore.mediaDir(appContext), "${story.id}.bin").apply { writeBytes(plain) }
            StoryLocalStore.setDownload(appContext, story.id, file.absolutePath, StoryDownloadState.READY)
            file.absolutePath
        } catch (e: Exception) {
            // A 404/403 means the object is gone (reaped) or we lost entitlement — distinct from a
            // decrypt failure, but both end as "can't show this". 404 => GONE so the UI says "no
            // longer available"; anything else => FAILED ("couldn't be loaded").
            val gone = (e as? ApiError.Http)?.status == 404
            StoryLocalStore.setDownload(
                appContext, story.id, null,
                if (gone) StoryDownloadState.GONE else StoryDownloadState.FAILED,
            )
            android.util.Log.w("VOIID", "story download failed id=${story.id}: ${e.message}")
            null
        }
    }

    // MARK: - View receipts (opt-in, OFF by default)

    /** Record that WE opened [story] on this device (always, never transmitted), and — only if the
     *  per-device receipts setting is ON and it isn't our own story — send an encrypted view receipt
     *  to the author's devices. */
    suspend fun onViewed(story: Story, receiptsEnabled: Boolean) {
        StoryLocalStore.markViewed(appContext, story.id)
        if (!receiptsEnabled || story.isMine) return
        val myId = tokens.userId ?: return
        val receipt = StoryViewReceipt(story_id = story.id, viewer_id = myId, viewed_at = System.currentTimeMillis())
        val json = ApiClient.json.encodeToString(StoryViewReceipt.serializer(), receipt)
        runCatching {
            // Author DEVICES only — never our own devices (a receipt must not wake our siblings).
            val bcast = chat.encryptBroadcast(json.encodeToByteArray(), listOf(story.authorId), includeOwnDevices = false)
            if (bcast.isNotEmpty()) {
                service.sendReceipt(story.id, bcast.map { StoryService.KeyEntry(it.recipientDeviceId, it.ciphertext) })
            }
        }.onFailure { android.util.Log.w("VOIID", "view receipt send failed story=${story.id}: ${it.message}") }
    }

    /**
     * Author-side: pull pending view receipts and, IF our receipts setting is ON, upsert them into
     * the local viewer list. When OFF, incoming receipts are discarded on decrypt (§4.4) — the
     * opt-out is reciprocal. Returns the story ids whose viewer list changed.
     */
    suspend fun fetchReceipts(receiptsEnabled: Boolean): Set<String> {
        val rows = runCatching { service.receipts(e2e.deviceId) }.getOrDefault(emptyList())
        if (!receiptsEnabled) return emptySet()   // discarded on decrypt: we don't even store them
        val changed = HashSet<String>()
        for (row in rows) {
            val plain = chat.decryptStoryReceipt(row.ciphertext) ?: continue
            val receipt = runCatching { ApiClient.json.decodeFromString(StoryViewReceipt.serializer(), plain) }.getOrNull()
                ?: continue
            StoryLocalStore.recordView(appContext, receipt.story_id, receipt.viewer_id, receipt.viewed_at)
            changed.add(receipt.story_id)
        }
        return changed
    }

    // MARK: - Delete / sweep

    /** Delete a story we authored: R2 object + rows server-side, then local. NOT a security
     *  operation — anyone who already downloaded keeps the media. */
    suspend fun deleteStory(storyId: String) {
        runCatching { service.deleteStory(storyId) }
        StoryLocalStore.deleteStory(appContext, storyId)
    }

    /** Foreground sweep of expired local rows + their cached plaintext files. */
    suspend fun sweep() { StoryLocalStore.sweepExpired(appContext) }

    // MARK: - helpers

    /** Parse a server timestamptz (ISO-8601 string) to epoch millis, tolerating epoch-ms numbers. */
    private fun parseTs(s: String?): Long? {
        if (s.isNullOrBlank()) return null
        s.toLongOrNull()?.let { return it }
        return runCatching { java.time.Instant.parse(s).toEpochMilli() }.getOrNull()
    }
}
