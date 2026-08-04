package com.voiid.app.model

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voiid.app.net.CreatorService
import com.voiid.app.net.TokenStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Creator profiles, the follow graph and the Following feed (mirrors iOS `CreatorEngine`).
 * Transport lives in [CreatorService]; this owns the cache and the optimistic updates.
 *
 * NOT E2EE — see the header of [CreatorService]. A follow grants no messaging right.
 */
class CreatorStore(app: Application) : AndroidViewModel(app) {

    private val svc = CreatorService(TokenStore.get(app))

    // ── Your own profile (the gate) ───────────────────────────────────────────────

    /**
     * Your profile, or null if you have none. Null is ambiguous on its own — it means both
     * "not loaded yet" and "you have none" — so [hasLoadedMe] distinguishes them. Without
     * that split the composer cannot tell a cold start from a genuine no-profile and would
     * show the handle picker to someone who already has a handle.
     */
    var me by mutableStateOf<CreatorService.Profile?>(null)
        private set
    var hasLoadedMe by mutableStateOf(false)
        private set
    var meLoading by mutableStateOf(false)
        private set

    /**
     * Whether the gate should open before posting. False until [me] has actually loaded, so
     * a slow network never fires a spurious picker.
     */
    val needsProfile: Boolean get() = hasLoadedMe && me == null

    suspend fun refreshMe(): CreatorService.Profile? {
        meLoading = true
        try {
            me = svc.me()
            hasLoadedMe = true
        } catch (e: Exception) {
            // Deliberately does NOT set hasLoadedMe: a failed fetch is not evidence that the
            // user lacks a profile, and treating it as such would gate a creator out of
            // posting whenever the network blips.
            android.util.Log.w("VOIID", "creator me fetch failed: ${e.message}")
        } finally {
            meLoading = false
        }
        return me
    }

    /** Ensures [me] is loaded, fetching only once. Called before the composer opens. */
    suspend fun ensureMeLoaded(): CreatorService.Profile? {
        if (hasLoadedMe) return me
        return refreshMe()
    }

    suspend fun createProfile(
        handle: String,
        displayName: String?,
        bio: String?,
        linkUrl: String?,
    ): CreatorService.Profile {
        val p = svc.create(handle, displayName, bio, linkUrl)
        me = p
        hasLoadedMe = true
        cache[p.handle.lowercase()] = p
        return p
    }

    suspend fun updateProfile(
        handle: String? = null,
        displayName: String? = null,
        bio: String? = null,
        linkUrl: String? = null,
    ): CreatorService.Profile {
        val old = me?.handle?.lowercase()
        val p = svc.update(handle, displayName, bio, linkUrl)
        me = p
        // A rename leaves the old key pointing at a handle that no longer resolves.
        if (old != null && old != p.handle.lowercase()) cache.remove(old)
        cache[p.handle.lowercase()] = p
        return p
    }

    suspend fun uploadAvatar(jpeg: ByteArray): CreatorService.Profile {
        val p = svc.uploadAvatar(jpeg)
        me = p
        cache[p.handle.lowercase()] = p
        return p
    }

    // ── Handle availability ───────────────────────────────────────────────────────

    sealed interface HandleState {
        data object Idle : HandleState
        data object Checking : HandleState
        data object Available : HandleState
        data object Taken : HandleState
        data object BadFormat : HandleState
        data class Failed(val message: String) : HandleState
    }

    var handleState by mutableStateOf<HandleState>(HandleState.Idle)
        private set

    private var handleCheckJob: Job? = null

    /**
     * Debounced availability check. Each call cancels the in-flight one, so a fast typist
     * issues one request at the end rather than one per keystroke — and, more importantly, a
     * slow earlier response can never overwrite the answer for what is now in the field.
     */
    fun checkHandle(raw: String, debounceMs: Long = 350) {
        handleCheckJob?.cancel()
        val handle = raw.trim().lowercase()

        if (handle.isEmpty()) { handleState = HandleState.Idle; return }
        if (!CreatorService.isWellFormed(handle)) { handleState = HandleState.BadFormat; return }

        handleState = HandleState.Checking
        handleCheckJob = viewModelScope.launch {
            delay(debounceMs)
            runCatching { svc.handleAvailable(handle) }
                .onSuccess { resp ->
                    handleState = when {
                        resp.available -> HandleState.Available
                        resp.reason == "format" -> HandleState.BadFormat
                        else -> HandleState.Taken
                    }
                }
                .onFailure {
                    // Advisory only — a failed check must not block submission. The create
                    // call re-validates under the real constraint anyway.
                    handleState = HandleState.Failed("Couldn't check that handle.")
                }
        }
    }

    fun resetHandleState() {
        handleCheckJob?.cancel()
        handleState = HandleState.Idle
    }

    /** Set directly when the server settles the race at submit time (409). */
    fun markHandleTaken() { handleState = HandleState.Taken }

    // ── Public profiles ───────────────────────────────────────────────────────────

    /**
     * Keyed on the lowercased handle. Small and short-lived: a profile carries a presigned
     * avatar URL that expires, so this is a within-session convenience, not a store.
     */
    val cache = mutableStateMapOf<String, CreatorService.Profile>()

    var profileError by mutableStateOf<String?>(null)
        private set
    var profileLoading by mutableStateOf(false)
        private set

    fun loadProfile(handle: String) {
        viewModelScope.launch {
            profileLoading = true
            profileError = null
            runCatching { svc.profile(handle) }
                .onSuccess { p ->
                    cache[p.handle.lowercase()] = p
                    // The server is authoritative about whether this is you; keep `me` in
                    // step so an edit made on another device shows up here.
                    if (p.is_self) { me = p; hasLoadedMe = true }
                }
                .onFailure { profileError = it.message ?: "Couldn't load that profile." }
            profileLoading = false
        }
    }

    fun cachedProfile(handle: String): CreatorService.Profile? = cache[handle.lowercase()]

    // ── Follow ────────────────────────────────────────────────────────────────────

    /**
     * Optimistic: the button flips and the count moves immediately, then both are overwritten
     * by the server's authoritative count. On failure the original state is restored — a
     * follow button that lies about its state is worse than a slow one.
     */
    fun toggleFollow(handle: String) {
        val key = handle.lowercase()
        val p = cache[key] ?: return
        val wasFollowing = p.following

        cache[key] = p.copy(
            following = !wasFollowing,
            follower_count = (p.follower_count + if (wasFollowing) -1 else 1).coerceAtLeast(0),
        )

        viewModelScope.launch {
            runCatching {
                if (wasFollowing) svc.unfollow(handle) else svc.follow(handle)
            }.onSuccess { resp ->
                cache[key]?.let {
                    cache[key] = it.copy(
                        following = resp.following,
                        follower_count = resp.follower_count,
                    )
                }
                // The set of people you follow changed, so the Following feed is stale.
                followingLoadedOnce = false
            }.onFailure {
                cache[key]?.let {
                    cache[key] = it.copy(
                        following = wasFollowing,
                        follower_count = (it.follower_count + if (wasFollowing) 1 else -1)
                            .coerceAtLeast(0),
                    )
                }
            }
        }
    }

    // ── A creator's grid ──────────────────────────────────────────────────────────

    val grids = mutableStateMapOf<String, List<CreatorService.CreatorClipRow>>()
    private val gridCursors = mutableMapOf<String, String?>()
    private val gridLoading = mutableSetOf<String>()

    fun clipsFor(handle: String): List<CreatorService.CreatorClipRow> =
        grids[handle.lowercase()] ?: emptyList()

    fun refreshClips(handle: String) {
        val key = handle.lowercase()
        if (key in gridLoading) return
        gridLoading.add(key)
        viewModelScope.launch {
            runCatching { svc.clips(handle) }
                .onSuccess {
                    grids[key] = it.clips
                    gridCursors[key] = it.next_cursor
                }
                .onFailure { android.util.Log.w("VOIID", "creator clips failed: ${it.message}") }
            gridLoading.remove(key)
        }
    }

    /** Keyset pagination, triggered by a tile near the end of the grid coming into view. */
    fun loadMoreClipsIfNeeded(handle: String, index: Int) {
        val key = handle.lowercase()
        val rows = grids[key] ?: return
        val cursor = gridCursors[key] ?: return
        // Prefetch a screenful early so the grid does not visibly stall at the bottom.
        if (key in gridLoading || index < rows.size - 6) return

        gridLoading.add(key)
        viewModelScope.launch {
            runCatching { svc.clips(handle, cursor) }
                .onSuccess { resp ->
                    // De-duplicated: a clip posted mid-scroll shifts the keyset window, and a
                    // repeated id would break a LazyGrid keyed on it.
                    val existing = rows.map { it.id }.toSet()
                    grids[key] = rows + resp.clips.filter { it.id !in existing }
                    gridCursors[key] = resp.next_cursor
                }
                .onFailure { android.util.Log.w("VOIID", "creator clips page failed: ${it.message}") }
            gridLoading.remove(key)
        }
    }

    // ── Following feed ────────────────────────────────────────────────────────────

    val following = mutableStateListOf<CreatorService.CreatorClipRow>()
    var followingLoading by mutableStateOf(false)
        private set
    var followingError by mutableStateOf<String?>(null)
        private set
    var followingLoadedOnce by mutableStateOf(false)
        private set
    private var followingCursor: String? = null

    fun refreshFollowing() {
        if (followingLoading) return
        followingLoading = true
        followingError = null
        viewModelScope.launch {
            runCatching { svc.followingFeed() }
                .onSuccess { resp ->
                    following.clear()
                    following.addAll(resp.clips)
                    followingCursor = resp.next_cursor
                    followingLoadedOnce = true
                }
                .onFailure { followingError = it.message ?: "Couldn't load your feed." }
            followingLoading = false
        }
    }

    fun loadMoreFollowingIfNeeded(index: Int) {
        val cursor = followingCursor ?: return
        if (followingLoading || index < following.size - 6) return
        followingLoading = true
        viewModelScope.launch {
            runCatching { svc.followingFeed(cursor) }
                .onSuccess { resp ->
                    val existing = following.map { it.id }.toSet()
                    following.addAll(resp.clips.filter { it.id !in existing })
                    followingCursor = resp.next_cursor
                }
                .onFailure {
                    android.util.Log.w("VOIID", "following feed page failed: ${it.message}")
                }
            followingLoading = false
        }
    }
}
