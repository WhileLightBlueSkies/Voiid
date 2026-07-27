package com.voiid.app.net

import android.content.Context
import android.util.Base64

/**
 * Background-safe store for INBOUND live-Map keys (Feature B), keyed by shareId.
 *
 * Why this exists: a contact's `map_key` control message arrives over the durable E2EE path
 * and is decrypted in [ChatEngine.sync] — which runs in the FCM BACKGROUND process too, where
 * [MapPresenceEngine] has never been constructed/subscribed. Previously the key was only
 * captured by the engine's in-memory `inbound` map, so a key that arrived while the app was
 * backgrounded (the normal case for ambient map presence) was dropped and never recovered,
 * and every later fix from that contact was discarded for lack of a key — the "I only see my
 * own dot, never the people sharing with me" bug.
 *
 * Capturing the key HERE, in EncryptedSharedPreferences, at decrypt time makes it survive the
 * background process. [MapPresenceEngine.onFix] reads it as a fallback when its in-memory map
 * has no entry. This mirrors iOS, which captures the map key into the Keychain (NSE-safe) at
 * decrypt time regardless of whether the Map UI is alive.
 */
internal object MapInboundKeyStore {
    private const val NAME = "voiid_map_inbound_keys"

    data class Entry(val fromUserId: String, val key: ByteArray, val expiresAt: Long)

    /** Persist a contact's inbound map key. [keyB64] is the base64 32-byte shareKey. */
    fun put(ctx: Context, shareId: String, fromUserId: String, keyB64: String, expiresAt: Long) {
        SecurePrefs.open(ctx, NAME).edit()
            .putString(shareId, "$fromUserId|$keyB64|$expiresAt")
            .apply()
    }

    /** Drop a key on an explicit `map_off` so a resurrected stale frame can't be decrypted. */
    /** Drop every inbound map key — sign-out only. See SessionTeardown. */
    fun clear(ctx: Context) {
        SecurePrefs.open(ctx, NAME).edit().clear().apply()
    }

    fun remove(ctx: Context, shareId: String) {
        SecurePrefs.open(ctx, NAME).edit().remove(shareId).apply()
    }

    /** The stored key for a share, or null. Expired entries are dropped and return null. */
    fun get(ctx: Context, shareId: String): Entry? {
        val raw = SecurePrefs.open(ctx, NAME).getString(shareId, null) ?: return null
        val parts = raw.split("|")
        if (parts.size != 3) return null
        val exp = parts[2].toLongOrNull() ?: return null
        if (exp in 1 until System.currentTimeMillis()) { remove(ctx, shareId); return null }
        val key = runCatching { Base64.decode(parts[1], Base64.NO_WRAP) }.getOrNull() ?: return null
        if (key.size != 32) return null
        return Entry(parts[0], key, exp)
    }
}
