package com.voiid.app.net

import android.net.Uri

/**
 * The community invite link — `https://voiid.app/c/<handle>?i=<token>`.
 *
 * Mirrors iOS `CommunityLink.swift`; the two parsers must agree, because the same printed QR
 * code has to mean the same thing on both phones.
 *
 * WHY A PLAIN SERVER TOKEN AND NOT SIGNAL'S SCHEME
 * -----------------------------------------------
 * Signal's group links carry the group master key and a join password in the URL FRAGMENT,
 * which never leaves the browser and never reaches its server — it can do that because Signal's
 * group STATE is encrypted too (zkgroup). Voiid's community roster is server-visible by design
 * (030_communities.sql: the server gates joins and fans MLS Welcome/Commit out per member), so
 * there is no encrypted group state for a fragment to protect. What we take from Signal is the
 * part that still applies: an unguessable token, revocable, with expiry and a use cap
 * (`community_invites`). A key in a fragment cannot be revoked; a row in a table can.
 *
 * THE LINK IS NOT A MEMBERSHIP CLAIM
 * ----------------------------------
 * Holding this URL proves nothing and reveals nothing on its own. Everything the user is shown
 * comes back from `GET /v1/communities/<handle>` — the server decides what a link-holder may
 * see, and the public card it returns deliberately contains no roster. In particular the client
 * must never infer "you are a member" from the fact that a link opened: whether you are in is
 * `CommunityCard.membership_state`, which only the server can answer. Nothing here is decoded,
 * decrypted or trusted locally.
 *
 * The token is a bearer capability, so it is treated like one: it travels only to the API host
 * over TLS, it is never logged, and it is never rendered back into the UI.
 */
data class CommunityLink(
    val handle: String,
    /** Null for an open community whose link needs no capability (join_policy != 'invite_only'). */
    val inviteToken: String?,
) {
    companion object {
        /** The apex the App Links intent filter is verified against. */
        const val HOST = "voiid.app"
        const val HOST_WWW = "www.$HOST"
        /** First path segment. Kept short because these end up on posters and stickers. */
        const val PATH_SEGMENT = "c"
        /** Query parameter carrying the invite token. */
        const val QUERY_TOKEN = "i"

        /**
         * Same grammar as `communities_handle_format` in 030_communities.sql, restated here on
         * purpose. This is not cosmetic validation: the handle is interpolated into an API path,
         * so anything that is not [a-z0-9_] must be rejected BEFORE a request is built. A crafted
         * link whose "handle" decodes to `../users/me` would otherwise walk the client onto a
         * different endpoint while the user believes they are looking at a community.
         */
        private val HANDLE = Regex("^[a-z][a-z0-9_]{2,19}$")

        /**
         * 32 bytes of CSPRNG output in base64url, per `community_invites.token`. The length
         * bounds mirror the `community_invites_token_len` check (22..64) so a garbage query
         * string is discarded here rather than spent as a failed redemption attempt server-side.
         */
        private val TOKEN = Regex("^[A-Za-z0-9_-]{22,64}$")

        /**
         * Parse an inbound URI, or null if it is not a community link we recognise.
         *
         * HTTPS ONLY, and only our own hosts. An `http://` variant is refused rather than
         * upgraded: the token is a bearer capability and must not be recoverable from a
         * plaintext request that a captive portal or a coffee-shop router can read. There is
         * also deliberately no `voiid://` custom-scheme fallback — any app on the device can
         * claim a custom scheme and would then be handed live invite tokens, which is exactly
         * what App Links / Universal Links exist to prevent.
         */
        fun parse(uri: Uri?): CommunityLink? {
            if (uri == null) return null
            if (!uri.scheme.equals("https", ignoreCase = true)) return null
            val host = uri.host?.lowercase() ?: return null
            if (host != HOST && host != HOST_WWW) return null

            // pathSegments is already percent-decoded, so this compares the real segments and
            // not their encoding; the HANDLE regex below is what makes the decoding safe.
            val segments = uri.pathSegments ?: return null
            if (segments.size != 2 || segments[0] != PATH_SEGMENT) return null
            val handle = segments[1].lowercase()
            if (!HANDLE.matches(handle)) return null

            // A malformed token is dropped, NOT passed through: sending it would burn a
            // redemption attempt and teach the user nothing. The link then behaves as a plain
            // "look at this community" link, and the server refuses the join if one was needed.
            val token = uri.getQueryParameter(QUERY_TOKEN)?.takeIf { TOKEN.matches(it) }
            return CommunityLink(handle, token)
        }

        /** Build a shareable link. The counterpart to [parse]; used by the invite-share UI. */
        fun format(handle: String, inviteToken: String?): String {
            val base = "https://$HOST/$PATH_SEGMENT/$handle"
            return if (inviteToken.isNullOrEmpty()) base
            else base + "?" + QUERY_TOKEN + "=" + Uri.encode(inviteToken)
        }
    }
}
