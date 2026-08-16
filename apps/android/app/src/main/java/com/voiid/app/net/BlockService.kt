package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The client half of user blocking. Twin of iOS `BlockService.swift`.
 *
 * Until this file existed the Block button raised "Blocking isn't available yet" beneath a
 * dialog promising "They won't be able to message or call you." The backend now enforces
 * that promise (043_user_blocks.sql, routes/blocks.ts) across messages, calls, profile,
 * presence, conversation creation, group invitations, stories and typing indicators; this
 * is what lets a person actually press it.
 *
 * BLOCKING IS SYMMETRIC ON THE SERVER, AND THAT MATTERS HERE
 * ----------------------------------------------------------
 * A block stops traffic in BOTH directions — the person who blocked can no longer message
 * the person they blocked either. The UI has to say so, because a user who expects Block to
 * be a one-way mute will read their own failed sends as a bug. See the dialog copy in
 * ContactProfileView and the footer in BlockedContactsScreen.
 *
 * WHAT THIS DELIBERATELY CANNOT ANSWER
 * ------------------------------------
 * "Has someone blocked ME." There is no route for it and there must never be: the whole
 * point of blocking silently is that the blocked party cannot distinguish a block from a
 * dead phone. [isBlocked] answers only about the CALLER's own outgoing blocks, which is
 * what the Block/Unblock row needs to render itself.
 *
 * WHY THIS IS AN `object` AND NOT A PER-SCREEN SERVICE
 * ----------------------------------------------------
 * Two screens need the same answer at the same time: ContactProfileView must know on open
 * whether to draw Block or Unblock, and BlockedContactsScreen shows the list. A per-call
 * service would make the profile screen fetch on every open, putting a spinner on a row
 * that is usually just "Block".
 */

// ── Wire models ────────────────────────────────────────────────────────────────────

/**
 * One blocked user, as GET /blocks returns them.
 *
 * EVERY field except [id] is nullable with a default. A blocked account may have no
 * username, no display name and no photo, and kotlinx throws `MissingFieldException` for a
 * required property the server did not send — so a stricter model would fail the whole
 * decode and leave the settings screen empty for someone who blocked one person with no
 * avatar. Same rule the Community and Consent wire types follow.
 */
@Serializable
data class BlockedUser(
    val id: String,
    val username: String? = null,
    val full_name: String? = null,
    val photo_url: String? = null,
    val blocked_at: String? = null,
) {
    /** What to show in a row. Falls through the fields the server may not have. */
    val displayName: String
        get() = when {
            !full_name.isNullOrBlank() -> full_name
            !username.isNullOrEmpty() -> "@$username"
            else -> "Unknown user"
        }
}

@Serializable
private data class BlockedListEnvelope(val blocked: List<BlockedUser>? = null)

// ── Service ────────────────────────────────────────────────────────────────────────

object BlockService {

    /** The caller's own outgoing blocks, newest first. Empty until the first fetch. */
    private val _blocked = MutableStateFlow<List<BlockedUser>>(emptyList())
    val blocked: StateFlow<List<BlockedUser>> = _blocked.asStateFlow()

    /**
     * True once a fetch has completed, so the UI can tell "no blocks" from "not loaded".
     * Without it an empty list renders identically either way, and the settings screen
     * would claim "You haven't blocked anyone" while the request was still in flight.
     */
    private val _didLoad = MutableStateFlow(false)
    val didLoad: StateFlow<Boolean> = _didLoad.asStateFlow()

    /**
     * Ids being mutated right now, so one row can disable its own button without freezing
     * the whole list. Keyed by user id because two rows can be in flight at once.
     */
    private val _pending = MutableStateFlow<Set<String>>(emptySet())
    val pending: StateFlow<Set<String>> = _pending.asStateFlow()

    // ── Queries ────────────────────────────────────────────────────────────────────

    /**
     * Has the CALLER blocked this user? Answers from the cache — see the header note on
     * why this cannot and must not answer the reverse question.
     */
    fun isBlocked(userId: String?): Boolean =
        userId != null && _blocked.value.any { it.id == userId }

    /**
     * Refresh the list. Never throws: a failed refresh must not break a settings screen or
     * a profile view, and the previously-known list stays on screen rather than blanking.
     */
    suspend fun refresh(context: Context) {
        if (TokenStore.get(context).jwt == null) {
            _blocked.value = emptyList()
            _didLoad.value = false
            return
        }
        try {
            val env: BlockedListEnvelope =
                ApiClient(TokenStore.get(context)).requestAs("GET", "blocks")
            _blocked.value = env.blocked ?: emptyList()
            _didLoad.value = true
        } catch (e: Exception) {
            // Keep whatever we had. Rendering "you have blocked nobody" because the network
            // hiccuped would invite someone to re-block a person who is already blocked.
        }
    }

    /** Load once per session unless a refresh is explicitly asked for. */
    suspend fun loadIfNeeded(context: Context) {
        if (!_didLoad.value) refresh(context)
    }

    // ── Mutations ──────────────────────────────────────────────────────────────────

    /**
     * Block a user. Idempotent on the server, so pressing twice is harmless.
     *
     * Optimistic: the row is inserted locally before the request lands, because the
     * confirmation dialog has already closed and a row that stays "Block" for a second
     * afterwards reads as a failure. Rolled back if the request fails.
     *
     * Returns true on success. The caller shows an error on false — a silent failure here
     * is the dangerous case, someone believing they are protected when they are not.
     */
    suspend fun block(
        context: Context,
        userId: String,
        displayName: String? = null,
        username: String? = null,
        photoUrl: String? = null,
    ): Boolean {
        if (_pending.value.contains(userId)) return false
        _pending.value = _pending.value + userId

        val hadIt = isBlocked(userId)
        if (!hadIt) {
            _blocked.value = listOf(
                BlockedUser(id = userId, username = username, full_name = displayName,
                            photo_url = photoUrl)
            ) + _blocked.value
        }

        return try {
            // buildJsonObject, NOT a @Serializable body: ApiClient's Json has
            // encodeDefaults off, so a data-class field equal to its default is silently
            // dropped from the wire. See ReceiptEncodingTest for the bug that taught us.
            val body = buildJsonObject { put("user_id", userId) }
            ApiClient(TokenStore.get(context)).request("POST", "blocks", jsonBody = body.toString())
            // Re-fetch so the row carries the server's blocked_at and canonical profile
            // fields rather than the placeholder above.
            refresh(context)
            true
        } catch (e: Exception) {
            if (!hadIt) _blocked.value = _blocked.value.filterNot { it.id == userId }
            false
        } finally {
            _pending.value = _pending.value - userId
        }
    }

    /** Unblock a user. Also idempotent server-side. */
    suspend fun unblock(context: Context, userId: String): Boolean {
        if (_pending.value.contains(userId)) return false
        _pending.value = _pending.value + userId

        val removed = _blocked.value.firstOrNull { it.id == userId }
        _blocked.value = _blocked.value.filterNot { it.id == userId }

        return try {
            val encoded = java.net.URLEncoder.encode(userId, "UTF-8")
            ApiClient(TokenStore.get(context)).request("DELETE", "blocks/$encoded")
            true
        } catch (e: Exception) {
            // Put it back — showing someone as unblocked while the server still blocks them
            // is the more dangerous of the two wrong answers.
            if (removed != null && !isBlocked(userId)) {
                _blocked.value = listOf(removed) + _blocked.value
            }
            false
        } finally {
            _pending.value = _pending.value - userId
        }
    }

    /** Clear on sign-out. The next account must not inherit this one's blocked list. */
    fun reset() {
        _blocked.value = emptyList()
        _didLoad.value = false
        _pending.value = emptySet()
    }
}
