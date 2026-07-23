package com.voiid.app.model

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voiid.app.model.ConversationType
import com.voiid.app.net.ChatEngine
import com.voiid.app.net.ChatService
import com.voiid.app.net.StoryEngine
import com.voiid.app.store.LocalStore
import com.voiid.app.store.StoryLocalStore
import com.voiid.app.store.UserDirectory
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

/**
 * Per-device Stories prefs, shared so the Settings toggle can read/write the view-receipts opt-in
 * without a handle to [StoriesStore]. Per-device, synced nowhere (like the rest of the app's local
 * prefs) — deliberately.
 */
object StoryPrefs {
    const val NAME = "voiid_story_prefs"
    const val KEY_RECEIPTS = "view_receipts"
    fun receiptsEnabled(context: android.content.Context): Boolean =
        context.getSharedPreferences(NAME, 0).getBoolean(KEY_RECEIPTS, false)
    fun setReceiptsEnabled(context: android.content.Context, on: Boolean) =
        context.getSharedPreferences(NAME, 0).edit().putBoolean(KEY_RECEIPTS, on).apply()
}

/**
 * Stories app state — Compose state in an AndroidViewModel, the house idiom for a screen-scoped
 * store (contrast the service singletons which use StateFlow). Local-first: the tray renders from
 * [StoryLocalStore] and a failed sync never blanks it.
 *
 * VIEW RECEIPTS ARE OFF BY DEFAULT and per-device (synced nowhere). Sending one tells the SERVER
 * that you opened someone's story at time T — a new behavioural fact it otherwise never learns
 * (delivering a key is not opening it), and there is no sealed sender to hide the viewer. The
 * privacy-preserving default is therefore "empty viewer list until people opt in". The opt-out is
 * reciprocal: OFF means you send none AND you see none.
 */
class StoriesStore(app: Application) : AndroidViewModel(app) {

    private val appContext = app.applicationContext
    private val engine = StoryEngine.get(app)
    private val chatService = ChatService(app)
    private val prefs = appContext.getSharedPreferences(StoryPrefs.NAME, 0)

    /** Author contexts (one per person), ready for the tray + viewer. Recomposes on change. */
    val contexts = mutableStateListOf<StoryContext>()
    /** Delivered/recipient device counts for OUR stories: story_id -> (delivered, recipient). */
    val deliveredCounts = mutableStateMapOf<String, Pair<Int, Int>>()
    /** Cached viewer lists for OUR stories (author-side), story_id -> viewers. */
    val viewersByStory = mutableStateMapOf<String, List<StoryViewer>>()

    var loadError by mutableStateOf<String?>(null)
        private set
    var posting by mutableStateOf(false)
        private set

    /**
     * Per-device opt-in for view receipts (default OFF). Read fresh from prefs each access so a
     * toggle flipped in Settings (which writes the SAME prefs directly, without a handle to this
     * store) is honoured immediately — no cross-store observation needed.
     */
    val receiptsEnabled: Boolean get() = prefs.getBoolean(StoryPrefs.KEY_RECEIPTS, false)

    fun setReceiptsEnabled(on: Boolean) {
        prefs.edit().putBoolean(StoryPrefs.KEY_RECEIPTS, on).apply()
    }

    /** True when any unexpired, unviewed story exists — drives the tab's unread dot. */
    val hasUnread: Boolean get() = contexts.any { !it.isMine && it.hasUnviewed }

    val myContext: StoryContext? get() = contexts.firstOrNull { it.isMine }
    val othersContexts: List<StoryContext> get() = contexts.filter { !it.isMine }

    // MARK: - Load / sync

    /** Render local first, then sweep expired, then sync the feed + counts + receipts. */
    fun refresh() {
        viewModelScope.launch {
            loadLocal()
            engine.sweep()
            loadLocal()
            runCatching { engine.syncFeed() }
                .onFailure { loadError = "Couldn't refresh stories." }
            loadLocal()
            runCatching { deliveredCounts.putAll(engine.mineCounts()) }
            runCatching { engine.fetchReceipts(receiptsEnabled) }
        }
    }

    private suspend fun loadLocal() {
        val live = runCatching { StoryLocalStore.liveStories(appContext) }.getOrDefault(emptyList())
        val grouped = live.groupBy { it.authorId }.map { (authorId, stories) ->
            StoryContext(
                authorId = authorId,
                authorName = UserDirectory.displayName(authorId),
                photoUrl = UserDirectory.photoUrl(authorId),
                stories = stories.sortedBy { it.createdAt },
            )
        }
        // Order: mine first, then unviewed (newest), then viewed (newest).
        val ordered = grouped.sortedWith(
            compareByDescending<StoryContext> { it.isMine }
                .thenByDescending { it.hasUnviewed }
                .thenByDescending { it.newest?.createdAt ?: 0 },
        )
        contexts.clear(); contexts.addAll(ordered)
    }

    // MARK: - Audience

    /** One selectable recipient in the composer's audience picker. */
    data class AudienceEntry(val userId: String, val name: String, val photoUrl: String?)

    /**
     * Everyone you can reach: every direct-conversation peer in the local store, name-resolved
     * through [UserDirectory]. Local-first (no network needed to open the composer).
     */
    suspend fun candidateAudience(): List<AudienceEntry> {
        val convs = runCatching { LocalStore.conversations(appContext) }.getOrDefault(emptyList())
        return convs.asSequence()
            .filter { it.type == ConversationType.DIRECT }
            .mapNotNull { it.peerUserId }
            .distinct()
            .map { AudienceEntry(it, UserDirectory.displayName(it), UserDirectory.photoUrl(it)) }
            .sortedBy { it.name.lowercase() }
            .toList()
    }

    /** The remembered audience for the NEXT post. "All contacts" re-expands to include new ones;
     *  a custom selection is remembered verbatim (intersected with who's still reachable). */
    fun rememberedSelection(candidates: List<AudienceEntry>): Set<String> {
        val all = candidates.map { it.userId }.toSet()
        if (prefs.getBoolean(KEY_AUDIENCE_ALL, true)) return all
        val saved = prefs.getStringSet(KEY_AUDIENCE_CUSTOM, emptySet()) ?: emptySet()
        return saved.intersect(all)
    }

    fun saveSelection(selected: Set<String>, candidates: List<AudienceEntry>) {
        val all = candidates.map { it.userId }.toSet()
        val isAll = selected.size == all.size && selected.containsAll(all)
        prefs.edit()
            .putBoolean(KEY_AUDIENCE_ALL, isAll)
            .putStringSet(KEY_AUDIENCE_CUSTOM, if (isAll) emptySet() else selected)
            .apply()
    }

    // MARK: - Post

    /**
     * Optimistic post: the story shows in "Your story" as UPLOADING the instant Share is tapped
     * (we already hold the plaintext), while the real upload + fan-out run in the background. On
     * failure it's marked FAILED with a Retry affordance; the UI never blocks on a 50 MB upload.
     */
    fun post(
        bytes: ByteArray, mime: String, caption: String,
        width: Int?, height: Int?, durationMs: Long?, allowsReplies: Boolean,
        audienceUserIds: List<String>,
    ) {
        val myId = com.voiid.app.net.TokenStore.get(appContext).userId ?: return
        posting = true
        // Optimistic local echo with a temp id + cached bytes, so it appears immediately.
        val tempId = "pending-" + UUID.randomUUID()
        val now = System.currentTimeMillis()
        val localPath = runCatching {
            File(StoryLocalStore.mediaDir(appContext), "$tempId.bin").also { it.writeBytes(bytes) }.absolutePath
        }.getOrNull()
        val placeholderRef = ChatEngine.MediaRef(mediaUrl = "", mime = mime, key = "", nonce = "", sha256 = "")
        viewModelScope.launch {
            StoryLocalStore.upsert(
                appContext,
                Story(
                    id = tempId, authorId = myId, isMine = true, createdAt = now,
                    expiresAt = now + 24L * 60 * 60 * 1000, media = placeholderRef, caption = caption,
                    durationMs = durationMs, width = width, height = height, allowsReplies = allowsReplies,
                    viewedAt = now, localPath = localPath,
                    downloadState = StoryDownloadState.READY, uploadState = StoryUploadState.UPLOADING,
                ),
            )
            loadLocal()
            try {
                engine.postStory(bytes, mime, caption, width, height, durationMs, allowsReplies, audienceUserIds)
                StoryLocalStore.deleteStory(appContext, tempId)   // real row replaces the placeholder
            } catch (e: Exception) {
                StoryLocalStore.setUpload(appContext, tempId, StoryUploadState.FAILED)
                loadError = (e as? com.voiid.app.net.ApiError)?.message ?: "Couldn't post your story."
            } finally {
                posting = false
                loadLocal()
            }
        }
    }

    // MARK: - Viewing

    /** Ensure a story's plaintext is downloaded; returns the local path (or null on failure). */
    suspend fun ensureDownloaded(story: Story): String? = engine.ensureDownloaded(story)

    /** First full display of a story: record it viewed locally (always) + send a receipt if opted in. */
    fun onViewed(story: Story) {
        viewModelScope.launch {
            engine.onViewed(story, receiptsEnabled)
            loadLocal()
        }
    }

    /** Load the viewer list for one of OUR stories (author-side). */
    fun loadViewers(storyId: String) {
        viewModelScope.launch {
            viewersByStory[storyId] = StoryLocalStore.viewers(appContext, storyId)
        }
    }

    // MARK: - Reply

    /** Send a reply to a story as an ordinary 1:1 message into the chat with the author. */
    fun sendReply(story: Story, text: String, reaction: String?, onDone: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val ok = runCatching {
                val convId = chatService.createDirect(story.authorId)
                ChatEngine.get(appContext).sendStoryReply(
                    convId, story.authorId, story.id, story.createdAt, text, reaction,
                )
            }.isSuccess
            if (!ok) loadError = "Couldn't send your reply."
            onDone(ok)
        }
    }

    // MARK: - Delete

    fun delete(storyId: String, onDone: () -> Unit = {}) {
        viewModelScope.launch {
            engine.deleteStory(storyId)
            loadLocal()
            onDone()
        }
    }

    companion object {
        private const val KEY_AUDIENCE_ALL = "audience_all"
        private const val KEY_AUDIENCE_CUSTOM = "audience_custom"
    }
}
