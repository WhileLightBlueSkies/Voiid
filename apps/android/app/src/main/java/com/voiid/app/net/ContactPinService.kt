package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable

/**
 * The CONTACT PIN — how someone who found you by @username is allowed to message you
 * (see 020_reachability.sql and routes/reachability.ts). Mirrors iOS `ContactPinService.swift`.
 *
 * Address-book discovery used to BE the gate: the only way to learn someone's user id was to
 * have their number. Username search removes that, so a 6-digit PIN takes its place — you give
 * it out of band ("my Voiid is @nehal, PIN 418302") and it lets that person open a REQUEST,
 * which you still have to accept.
 *
 * IT IS NOT A PASSWORD and must never gate account access. Knowing it does exactly one thing:
 * permits a request. Two independent gates, so a leaked PIN alone is not enough.
 *
 * THE PIN IS VIEWABLE. It is stored encrypted at rest (migration 026) rather than hashed, so
 * the owner can look it up whenever they need to share it. A PIN you cannot re-read is one you
 * must write down, and forgetting it would force a rotation that locks out everyone already
 * holding the old one.
 *
 * It is NOT end-to-end encrypted — the server holds the key. What that buys is that a stolen
 * database dump alone yields ciphertext. Messages, calls and media are E2E and unaffected.
 */
class ContactPinService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    /** The caller's own PIN. */
    @Serializable
    data class PinState(
        val has_pin: Boolean = false,
        /**
         * The digits, in the clear. Null with [has_pin] true means a PIN minted before
         * migration 026, stored only as an unreversible hash — it still WORKS, it just can't
         * be shown. Rotating replaces it with a viewable one.
         */
        val pin: String? = null,
        val set_at: String? = null,
        /**
         * False when the SERVER has no secretbox key, so no PIN can be stored viewably.
         * Distinguishes "your PIN predates the feature" (rotating fixes it) from "this
         * deployment can't store PINs readably" (rotating cannot).
         */
        val storage_configured: Boolean = true,
    )

    @Serializable
    private data class RotateResponse(
        val pin: String,
        /** False when the server has no secretbox key, so this PIN won't be re-fetchable. */
        val viewable: Boolean = true,
    )

    /**
     * Fetch the current PIN. Owner-only server-side: the id comes from the auth token, so
     * there is no parameter that could be pointed at someone else.
     */
    suspend fun state(): PinState = api.requestAs("GET", "reachability/contact-pin")

    /**
     * Mint a NEW PIN, replacing any existing one.
     *
     * This is a REVOCATION, not a way to recover a forgotten PIN — [state] already returns the
     * current one. It invalidates the old PIN immediately for everyone who had it, and clears
     * the server's failed-attempt ledger so a sender previously locked out by throttling gets
     * a fresh start against the NEW secret.
     */
    suspend fun rotate(): Pair<String, Boolean> =
        api.requestAs<RotateResponse>("POST", "reachability/contact-pin/rotate")
            .let { it.pin to it.viewable }

    // ---- Reaching someone by username ---------------------------------------------------

    /**
     * A public profile resolved from a handle. Deliberately carries NO phone number: this
     * endpoint is the boundary between Voiid's private and public identity planes, and a
     * stranger who knows @nehal must not be able to reach a number.
     */
    @Serializable
    data class PublicProfile(
        val user_id: String,
        val username: String? = null,
        val full_name: String? = null,
        val photo_url: String? = null,
        val bio: String? = null,
        val is_mutual_contact: Boolean = false,
        /** True when a PIN is needed. False for mutual contacts, who already proved acquaintance. */
        val requires_pin: Boolean = false,
        /** False when they never set a PIN — unreachable by handle, and the UI should say so. */
        val reachable_by_username: Boolean = false,
    )

    @Serializable
    private data class RequestResponse(
        val conversation_id: String,
        val existed: Boolean = false,
        val pending: Boolean = false,
    )

    suspend fun lookup(username: String): PublicProfile =
        api.requestAs("GET", "reachability/by-username?username=$username")

    /**
     * Open a chat by handle. [pin] may be null for a mutual contact. Returns the conversation
     * id and whether the recipient's side is still PENDING, so the caller can show "waiting to
     * be accepted" rather than a normal chat.
     */
    suspend fun requestChat(username: String, pin: String?): Pair<String, Boolean> {
        @Serializable data class Body(val username: String, val pin: String?)
        val body = ApiClient.json.encodeToString(Body.serializer(), Body(username, pin))
        val res: RequestResponse = api.requestAs("POST", "reachability/request", jsonBody = body)
        return res.conversation_id to res.pending
    }

    // ---- Inbound requests ----------------------------------------------------------------

    @Serializable
    data class PendingRequest(
        val conversation_id: String,
        val opened_via: String? = null,
        val sender_id: String,
        val username: String? = null,
        val full_name: String? = null,
        val photo_url: String? = null,
    )

    @Serializable private data class PendingResponse(val requests: List<PendingRequest> = emptyList())

    suspend fun pending(): List<PendingRequest> =
        api.requestAs<PendingResponse>("GET", "reachability/pending").requests

    suspend fun accept(conversationId: String) {
        api.requestAs<Unit>("POST", "reachability/$conversationId/accept")
    }

    /**
     * Decline. The sender is NEVER told — if "declined" were distinguishable from "not opened
     * yet", a request would become a presence oracle telling a stranger whether an account is
     * live and attended.
     */
    suspend fun decline(conversationId: String) {
        api.requestAs<Unit>("POST", "reachability/$conversationId/decline")
    }
}
