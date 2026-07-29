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
        // The address book loads ASYNCHRONOUSLY on Android; without awaiting it the "known
        // author" gate below runs against an empty directory and DROPS every story (the
        // "Android stories nobody can see" bug — the drop is permanent because the feed is
        // deliver-once). iOS loads the directory synchronously, so it never hit this.
        UserDirectory.ready(appContext)
        val live = runCatching { StoryLocalStore.liveStories(appContext) }.getOrDefault(emptyList())
        val existing = live.map { it.id }.toHashSet()
        // Rows that came from the SERVER. A failed post leaves an optimistic "pending-<uuid>"
        // row behind (StoriesStore.post) which lives for 24h — and because it made the local
        // feed look non-empty, it silently disabled the include_delivered recovery below for a
        // whole day. One failed post must not cost you every recoverable story.
        val serverBacked = live.count { !it.id.startsWith("pending-") }
        // RECOVERY: if we hold no live stories at all, re-fetch with include_delivered so a
        // device whose keys were already marked delivered — a lost local DB, OR a story dropped
        // by the pre-fix async-directory bug — still gets its live feed back. The normal
        // (deliver-once) pass would return nothing in that case and the feed would stay empty.
        val includeDelivered = serverBacked == 0
        val rows = service.feed(e2e.deviceId, includeDelivered)
        // How many envelopes the SERVER had for this device. Zero is the single most useful
        // fact when a moment "never arrives": it proves nothing was ever addressed here, so
        // the fault is on the SEND side (audience, or the sender's device lookup) rather than
        // anywhere in the decrypt/validate path below. Without this the two are
        // indistinguishable from the receiving phone.
        android.util.Log.i(
            "VOIID",
            "story feed: ${rows.size} envelope(s) for device=${e2e.deviceId} " +
                "(includeDelivered=$includeDelivered, ${existing.size} already local)",
        )
        // Computed ONCE for the batch: it reads the conversations table, and validate() is not
        // a suspend function, so it cannot do this per row.
        val reachable = reachableAuthors()
        val fresh = mutableListOf<Story>()
        for (row in rows) {
            if (existing.contains(row.story_id)) continue    // decrypt-once dedup
            val plain = chat.decryptBroadcast(row.ciphertext, row.author_id, row.author_device_id)
            if (plain == null) {
                android.util.Log.w("VOIID", "⚠️ story key undecryptable id=${row.story_id}")
                continue
            }
            // Logged, not silent: a wire-shape mismatch here (the iOS→Android direction of the
            // encodeDefaults/Codable bug) would otherwise drop the story with no trace at all.
            val env = runCatching { ApiClient.json.decodeFromString(StoryEnvelope.serializer(), plain) }
                .onFailure { android.util.Log.w("VOIID", "🚫 story DROPPED id=${row.story_id} from=${row.author_id}: envelope decode failed", it) }
                .getOrNull()
                ?: continue
            val story = validate(env, row, myId, reachable) ?: continue
            StoryLocalStore.upsert(appContext, story)
            fresh.add(story)
        }
        if (rows.isNotEmpty() && fresh.isEmpty()) {
            // Envelopes arrived but none survived. Every drop above logs its own reason; this
            // line is the summary that says "look up" rather than assuming nothing was sent.
            android.util.Log.w("VOIID", "🚫 story feed: ${rows.size} envelope(s) arrived, 0 stored — see the DROPPED lines above")
        }
        return SyncResult(fresh)
    }

    /**
     * Everyone whose story we accept: the address-book directory UNION every 1:1 conversation
     * peer. The same set the composer offers (StoriesStore.candidateAudience) and the same
     * rule iOS applies (UserDirectory.storyReachableUserIds) — send and receive must agree, or
     * a story is offered to someone who will silently discard it.
     */
    private suspend fun reachableAuthors(): Set<String> {
        val convs = runCatching { com.voiid.app.store.LocalStore.conversations(appContext) }
            .getOrDefault(emptyList())
        val peers = convs.asSequence()
            .filter { it.type == com.voiid.app.model.ConversationType.DIRECT }
            .mapNotNull { it.peerUserId }
        return (peers + UserDirectory.knownUserIds()).filter { it.isNotEmpty() }.toSet()
    }

    /**
     * Receiver-side validation (§1.5) — the server does NOT do this for you; any authenticated user
     * can POST a story targeting your device id. Returns the Story to store, or null to DROP.
     */
    private fun validate(env: StoryEnvelope, row: StoryService.FeedStory, myId: String?, reachable: Set<String>): Story? {
        // Each drop is LOGGED. A silent `return null` here made "the story never arrived"
        // indistinguishable from "it was rejected by rule 1/2/3", with nothing in logcat.
        if (env.story_id != row.story_id) {                                 // 1. id must bind
            android.util.Log.w("VOIID", "🚫 story DROPPED id=${row.story_id}: envelope story_id mismatch (${env.story_id})")
            return null
        }
        if (env.author_id != row.author_id) {                               // 2. no reattribution
            android.util.Log.w("VOIID", "🚫 story DROPPED id=${row.story_id}: author mismatch (${env.author_id} vs ${row.author_id})")
            return null
        }
        if (env.media.mediaUrl != row.r2_key) {                             // 3. object key must match
            android.util.Log.w("VOIID", "🚫 story DROPPED id=${row.story_id}: media ref does not match the feed row's r2_key")
            return null
        }
        val createdAt = parseTs(row.created_at) ?: env.created_at
        // 4. clamp the author's expiry claim to created_at + 24h (+60s skew).
        val serverExpiry = parseTs(row.expires_at)
        val cappedClaim = createdAt + TWENTY_FOUR_HOURS_MS + 60_000
        val expiresAt = (serverExpiry ?: minOf(env.expires_at, cappedClaim)).coerceAtMost(cappedClaim)
        // 5. author must be a known contact (in the local directory) and not ourselves-as-stranger.
        //    Our OWN stories are always allowed; a story from someone we have never seen is dropped
        //    silently so strangers can't push media into the feed.
        val isMine = env.author_id == myId
        // Author must be someone we actually know. Note: we only reach here AFTER successfully
        // decrypting the broadcast key (decryptBroadcast != null), which itself REQUIRES an
        // established E2E session with the author — a stranger can't forge that. So the
        // directory check is a secondary filter, not the only guard; with the directory now
        // loaded (awaited in syncFeed) it passes for real contacts and only drops genuine
        // strangers who somehow hold a session.
        // "Known" is REACHABLE — in the address book OR someone we have a 1:1 chat with — not
        // directory-only. You can chat with someone daily without ever saving them, and their
        // story was being discarded; the feed is deliver-once, so that drop was permanent.
        // Matches the send side (candidateAudience) and iOS (storyReachableUserIds).
        // NOT a hard drop when the local cache is COLD. reachable is built from the local
        // conversation list + address-book directory, both of which are legitimately EMPTY on
        // a fresh install or right after sign-in — and the feed is deliver-once, so discarding
        // here loses a real contact's moment permanently. That was the iOS→Android
        // "moments never arrive" bug. An empty set means "we don't know yet", not "stranger".
        if (!isMine && reachable.isNotEmpty() && env.author_id !in reachable) {
            android.util.Log.w("VOIID", "🚫 story DROPPED id=${env.story_id}: author=${env.author_id} is neither a contact nor someone you have a chat with")
            return null
        }
        if (!isMine && reachable.isEmpty()) {
            android.util.Log.i("VOIID", "story ACCEPTED id=${env.story_id} with a cold reachability cache — directory not yet synced")
        }
        return Story(
            id = env.story_id, authorId = env.author_id, isMine = isMine,
            createdAt = createdAt, expiresAt = expiresAt, media = env.media,
            // Coalesce the now-nullable wire fields to the envelope's declared defaults: an
            // absent or explicitly-null caption is a normal empty value, not a dropped story.
            caption = env.caption ?: "",
            durationMs = env.durationMs, width = env.width, height = env.height,
            allowsReplies = env.allowsReplies ?: true, viewedAt = null, localPath = null,
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
