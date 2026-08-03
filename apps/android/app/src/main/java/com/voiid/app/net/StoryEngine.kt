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
    private val prefs = appContext.getSharedPreferences("voiid_story_engine", Context.MODE_PRIVATE)

    /**
     * Story ids whose key ciphertext could NOT be decrypted. An Olm message is decrypt-once: a
     * `type=1` envelope encrypted against a session we no longer hold can never be recovered, no
     * matter how many times we re-fetch it. Recovery comes from the author RE-POSTING, never from
     * retrying a dead id.
     *
     * This mirrors the tombstone discipline `ChatEngine.sync` applies to 1:1 messages (see its
     * `controlSeenIds` union and the "no matching session cascade" comment). Stories had no such
     * guard, so every `includeDelivered` pass re-fetched the same dead envelope and re-failed it
     * — and because that pass only runs while the received-feed is empty, ONE undecryptable story
     * pinned the feed in permanent recovery mode, re-failing on every refresh forever.
     */
    /**
     * Deliberately NEVER cleared. It is tempting to reset this after a fix that widens what we
     * can accept, so previously-rejected stories get another chance — but that is actively
     * harmful: an Olm ciphertext is DECRYPT-ONCE. A story that decrypted and was then rejected
     * downstream has already consumed its one-time key, so re-fetching it decrypts to nothing
     * and the retry merely burns session state (the "no matching session cascade" ChatEngine.sync
     * warns about). Recovery for those stories comes from the author RE-POSTING, never from
     * retrying a dead id.
     */
    private fun deadStoryIds(): Set<String> =
        prefs.getStringSet("undecryptable", emptySet()) ?: emptySet()
    private fun markStoryDead(storyId: String) {
        val cur = HashSet(deadStoryIds()); cur.add(storyId)
        prefs.edit().putStringSet("undecryptable", cur).apply()
    }

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
        // Rows that came from the SERVER **and from someone else**. A failed post leaves an
        // optimistic "pending-<uuid>" row behind (StoriesStore.post) which lives for 24h — and
        // because it made the local feed look non-empty, it silently disabled the
        // include_delivered recovery below for a whole day. One failed post must not cost you
        // every recoverable story.
        //
        // `isMine` is excluded for the same reason iOS excludes it (StoryEngine.swift): YOUR OWN
        // posted story also makes the feed non-empty, so the moment you posted anything the
        // recovery pass turned off and a peer's story that was already marked delivered — the
        // common case on Android, where the pre-fix async-directory bug dropped them — became
        // permanently unrecoverable. That is the "Android can't see anyone else's moment" bug:
        // the keys were delivered once, dropped, and never re-fetched. Recovery must key off
        // stories RECEIVED FROM OTHERS only.
        val serverBacked = live.count { !it.id.startsWith("pending-") && !it.isMine }
        // Envelopes already proven undecryptable. Unioned into the dedup set below so a dead id
        // is never re-fetched and re-failed, and so it cannot hold the feed in recovery mode.
        val dead = deadStoryIds()
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
            // decrypt-once dedup: already stored, OR already proven undecryptable.
            if (existing.contains(row.story_id) || dead.contains(row.story_id)) continue
            val plain = chat.decryptBroadcast(row.ciphertext, row.author_id, row.author_device_id)
            // Tombstone on the DECRYPT ATTEMPT, whichever way it went — not just on failure.
            //
            // An Olm ciphertext is decrypt-once: a successful decrypt consumes the one-time key
            // and advances the ratchet, so the SAME row can never be opened again. If we only
            // tombstoned failures, a story that decrypted fine but was rejected by validate()
            // below stayed un-tombstoned and got re-fetched on the next pass — where it now
            // failed to decrypt, because we ourselves had already consumed it. That turns one
            // recoverable validation bug into a permanent decrypt failure and burns session
            // state on every retry.
            //
            // Marking here makes the rule exact: we attempt each envelope at most once, and
            // recovery is always the author re-posting.
            markStoryDead(row.story_id)
            if (plain == null) {
                android.util.Log.w("VOIID", "⚠️ story key undecryptable id=${row.story_id} — tombstoned, will not retry")
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
        // Lowercased so the membership probe in validate() is case-insensitive: ids reaching us
        // from an iOS sender are uppercase, while these local ones are not.
        return (peers + UserDirectory.knownUserIds())
            .filter { it.isNotEmpty() }.map { it.lowercase() }.toSet()
    }

    /**
     * Receiver-side validation (§1.5) — the server does NOT do this for you; any authenticated user
     * can POST a story targeting your device id. Returns the Story to store, or null to DROP.
     */
    private fun validate(env: StoryEnvelope, row: StoryService.FeedStory, myId: String?, reachable: Set<String>): Story? {
        // Each drop is LOGGED. A silent `return null` here made "the story never arrived"
        // indistinguishable from "it was rejected by rule 1/2/3", with nothing in logcat.
        // UUIDs are compared CASE-INSENSITIVELY. A UUID's canonical form is case-insensitive by
        // spec (RFC 4122 §3), and the two sides of this comparison come from different places
        // with different conventions: iOS mints ids with `UUID().uuidString`, which is
        // UPPERCASE, and that exact string is what rides inside the sealed envelope — while the
        // feed row comes back from a Postgres `uuid` column, which normalises to LOWERCASE on
        // storage. The server's own validation uses a /i regex, so it happily accepts either.
        //
        // Comparing literally therefore dropped EVERY story posted from iOS as a forgery:
        //   envelope 0E6B1DEC-…  vs  row 0e6b1dec-…
        // Same id, different case. That is the "Android can't see iOS moments" bug. The check
        // still binds the envelope to the row — it just no longer treats letter case as a
        // mismatch. (Android is unaffected in the other direction: java.util.UUID renders
        // lowercase, which is why iOS→Android failed while Android→iOS did not.)
        if (!env.story_id.equals(row.story_id, ignoreCase = true)) {        // 1. id must bind
            android.util.Log.w("VOIID", "🚫 story DROPPED id=${row.story_id}: envelope story_id mismatch (${env.story_id})")
            return null
        }
        if (!env.author_id.equals(row.author_id, ignoreCase = true)) {      // 2. no reattribution
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
        // Case-insensitive for the same reason as the id checks above: an iOS-minted author id
        // arrives uppercase inside the envelope while everything local (our own token, the
        // directory, the conversation peers) is lowercase. Comparing literally would make our
        // OWN story from a linked iPhone look like a stranger's.
        val isMine = env.author_id.equals(myId, ignoreCase = true)
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
        // `reachable` is normalised to lowercase by reachableAuthors(), so the probe must be too
        // — otherwise an uppercase iOS author id misses the set and the story is dropped as a
        // stranger's even though that person is a contact.
        if (!isMine && reachable.isNotEmpty() && env.author_id.lowercase() !in reachable) {
            android.util.Log.w("VOIID", "🚫 story DROPPED id=${env.story_id}: author=${env.author_id} is neither a contact nor someone you have a chat with")
            return null
        }
        if (!isMine && reachable.isEmpty()) {
            android.util.Log.i("VOIID", "story ACCEPTED id=${env.story_id} with a cold reachability cache — directory not yet synced")
        }
        return Story(
            // Store the SERVER's rendering of both ids, not the envelope's. The server value is
            // the canonical (lowercase) one that every other local table, the dedup set and the
            // delete/receipt endpoints key on — persisting iOS's uppercase here would split the
            // same story across two spellings.
            id = row.story_id, authorId = row.author_id, isMine = isMine,
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
            // The server does NOT name the viewer (story_receipts has no viewer_user_id column),
            // so we hand the decryptor the audience we saved at post time — those are the only
            // people who could have produced this receipt, and it needs them to rehydrate the
            // right sessions from disk. Unlike iOS we do NOT skip on an empty audience: a story
            // posted before saveAudience existed (or from a linked device) still has receipts
            // worth attributing, and the decryptor falls back to scanning cached sessions.
            val audience = runCatching { StoryLocalStore.audience(appContext, row.story_id) }
                .getOrDefault(emptyList())
            val plain = chat.decryptStoryReceipt(row.ciphertext, audience)
            if (plain == null) {
                android.util.Log.w("VOIID", "⚠️ view receipt undecryptable story=${row.story_id} (audience=${audience.size})")
                continue
            }
            val receipt = runCatching { ApiClient.json.decodeFromString(StoryViewReceipt.serializer(), plain) }.getOrNull()
                ?: continue
            // Bind the receipt to the row the server routed it under, exactly as iOS does —
            // otherwise a peer could record a view against a story that isn't the one they saw.
            if (receipt.story_id != row.story_id) {
                android.util.Log.w("VOIID", "🚫 view receipt DROPPED: story_id mismatch (${receipt.story_id} vs ${row.story_id})")
                continue
            }
            StoryLocalStore.recordView(appContext, receipt.story_id, receipt.viewer_id, receipt.viewed_at)
            changed.add(receipt.story_id)
        }
        if (rows.isNotEmpty()) {
            android.util.Log.i("VOIID", "story receipts: ${rows.size} row(s), ${changed.size} view(s) recorded")
        }
        return changed
    }

    // MARK: - Delete / sweep

    /** Delete a story we authored: R2 object + rows server-side, then local. NOT a security
     *  operation — anyone who already downloaded keeps the media.
     *
     *  Throws if the SERVER delete failed. It used to be swallowed by a bare `runCatching`, which
     *  made an offline delete look successful while the story stayed live for every recipient —
     *  and, because the row was only gone locally, the include_delivered recovery pass pulled it
     *  straight back. A 404 is treated as success: the row is already gone, which is the outcome
     *  we wanted. */
    suspend fun deleteStory(storyId: String) {
        try {
            service.deleteStory(storyId)
        } catch (e: ApiError.Http) {
            if (e.status != 404) throw e
        }
        StoryLocalStore.deleteStory(appContext, storyId)
    }

    /** Foreground sweep of expired local rows + their cached plaintext files. */
    suspend fun sweep() {
        StoryLocalStore.sweepExpired(appContext)
        // Bound the tombstone set. Stories live 24h, so an id the server has long since reaped
        // can never come back and no longer needs suppressing — without this the set would grow
        // without limit for the life of the install. The cap is generous (far more than a day's
        // worth of undecryptable envelopes) and only trims when clearly exceeded.
        val dead = deadStoryIds()
        if (dead.size > 500) {
            prefs.edit().putStringSet("undecryptable", dead.toList().takeLast(250).toSet()).apply()
        }
    }

    // MARK: - helpers

    /** Parse a server timestamptz (ISO-8601 string) to epoch millis, tolerating epoch-ms numbers. */
    private fun parseTs(s: String?): Long? {
        if (s.isNullOrBlank()) return null
        s.toLongOrNull()?.let { return it }
        return runCatching { java.time.Instant.parse(s).toEpochMilli() }.getOrNull()
    }
}
