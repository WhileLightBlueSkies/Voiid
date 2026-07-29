package com.voiid.app.net

import android.content.Context
import java.security.SecureRandom
import android.util.Base64

/**
 * ENCRYPTED PROFILE PHOTOS — key custody and distribution (see 021_profile_keys.sql).
 * Mirrors iOS `ProfileKeyStore.swift`.
 *
 * Avatars were the one media surface stored in the CLEAR: `uploadProfilePhoto` PUT a raw JPEG
 * to R2, so anyone with bucket access — including us — could open every user's face. Chat
 * photos, videos, voice notes and Moments have always been encrypted on-device.
 *
 * WHY AVATARS NEED THEIR OWN MECHANISM. A chat photo has ONE known audience, so a fresh
 * per-attachment key rides the ratchet with the message. An avatar has no fixed audience — it
 * is shown to anyone who might contact you, including someone who found your @username and has
 * never had a session with you. There is no single message to attach a key to. The key is
 * therefore per-USER and long-lived, wrapped once per recipient DEVICE (Signal's model).
 *
 * ⚠️ BLOCKED ON UNIFFI REGENERATION. `generateProfileKey` and `encryptMediaWithKey` exist in
 * packages/e2e-core (with tests) but are not yet in the generated Kotlin bindings, so
 * [rotateKey] uses a marked stand-in. Everything else — storage, fan-out, fetch, rotation
 * bookkeeping — is complete.
 *
 * Stored in [SecurePrefs] (encrypted at rest), on its OWN file so wiping profile keys can
 * never touch ratchet material.
 */
object ProfileKeyStore {

    private const val FILE = "voiid_profile_keys"
    private const val KEY_SELF = "self"
    private const val KEY_SELF_VERSION = "self_version"

    private fun prefs(context: Context) = SecurePrefs.open(context.applicationContext, FILE)

    // ---- My own key --------------------------------------------------------------------

    /**
     * My profile key and its version, or null if never minted.
     *
     * Version starts at 1 — the server's `profile_key_version` defaults to 0, so 0 is
     * unambiguously "this user has never published a key".
     */
    fun myKey(context: Context): Pair<String, Int>? {
        val p = prefs(context)
        val key = p.getString(KEY_SELF, null) ?: return null
        return key to maxOf(1, p.getInt(KEY_SELF_VERSION, 1))
    }

    /**
     * Mint a NEW profile key and bump the version.
     *
     * The caller MUST then re-encrypt the avatar and re-wrap to every contact: a rotation that
     * is not fanned out leaves every existing contact unable to decrypt, which looks exactly
     * like a broken avatar rather than a security action.
     */
    fun rotateKey(context: Context): Pair<String, Int> {
        // ⚠️ UNIFFI: `generateProfileKey()` is exported from e2e-core but not yet in the
        // generated bindings. Swap in once regenerated, and delete the stand-in below.
        // val key = uniffi.voiid.generateProfileKey()
        val key = temporaryLocalKey()
        val p = prefs(context)
        val next = p.getInt(KEY_SELF_VERSION, 0) + 1
        p.edit().putString(KEY_SELF, key).putInt(KEY_SELF_VERSION, next).apply()
        return key to next
    }

    /**
     * Stand-in until the bindings land. A correctly-shaped base64 32-byte key from the
     * platform CSPRNG, so the surrounding plumbing can be exercised end to end. It is
     * cryptographically sound — it is simply not the same code path the Rust core uses, and
     * must be deleted the moment `generateProfileKey()` is available.
     */
    private fun temporaryLocalKey(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    // ---- Other people's keys -----------------------------------------------------------

    /** In-memory mirror so an avatar paints on the first frame without hitting prefs per view. */
    private val peerKeys = HashMap<String, Pair<String, Int>>()

    fun keyFor(context: Context, userId: String): String? {
        peerKeys[userId]?.let { return it.first }
        val p = prefs(context)
        val key = p.getString("peer.$userId", null) ?: return null
        val version = p.getInt("peer_version.$userId", 0)
        peerKeys[userId] = key to version
        return key
    }

    /**
     * The version we hold for a peer, compared against `profile_key_version` on their profile.
     * If theirs is higher our copy is stale and must be re-fetched — without this a rotation is
     * only detectable by a failed decrypt, which is indistinguishable from a corrupt download.
     */
    fun versionFor(context: Context, userId: String): Int =
        peerKeys[userId]?.second ?: prefs(context).getInt("peer_version.$userId", 0)

    fun store(context: Context, userId: String, key: String, version: Int) {
        peerKeys[userId] = key to version
        prefs(context).edit()
            .putString("peer.$userId", key)
            .putInt("peer_version.$userId", version)
            .apply()
    }

    /**
     * Sign-out wipe. These are OTHER PEOPLE's secrets held on this device; leaving them behind
     * would let the next account on this phone decrypt the previous one's contacts.
     */
    fun clear(context: Context) {
        peerKeys.clear()
        runCatching { prefs(context).edit().clear().apply() }
    }
}
