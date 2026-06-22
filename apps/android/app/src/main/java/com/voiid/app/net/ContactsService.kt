package com.voiid.app.net

import android.content.Context
import android.provider.ContactsContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.security.MessageDigest

/**
 * Privacy-preserving contact discovery (Section 2.3 / 4.8). Mirrors iOS.
 *  - The address book is read ON DEVICE only.
 *  - Each phone number is normalized to E.164 and SHA-256 hashed locally.
 *  - Only the hashes are uploaded (/contacts/discover) — raw numbers NEVER leave
 *    the device. Matched users are linked via /contacts/sync (user_ids only).
 *
 * E.164 normalization is best-effort (defaults to +91 for national-format numbers,
 * matching our launch region). Mis-normalized numbers simply won't match.
 */
data class VContact(val userId: String, val displayName: String, val photoURL: String?)
data class InviteContact(val name: String, val number: String)
data class DiscoveryResult(val matches: List<VContact>, val invites: List<InviteContact>)

class ContactsService(context: Context) {
    private val appContext = context.applicationContext
    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)
    private val defaultCountryCode = "+91"

    // Shared (process-wide) cache so NewChat + NewGroup reuse one /contacts/discover
    // result instead of each hitting the network — avoids races / rate-limit / one
    // screen showing empty while the other loaded. (Issue 3.)
    companion object {
        @Volatile private var cached: DiscoveryResult? = null
        @Volatile private var cachedAt: Long = 0
        private const val CACHE_TTL_MS = 120_000L
    }

    /** Read contacts, discover VOIID users, persist links. Requires READ_CONTACTS granted. */
    suspend fun discover(forceRefresh: Boolean = false): DiscoveryResult {
        if (!forceRefresh) {
            val c = cached
            if (c != null && System.currentTimeMillis() - cachedAt < CACHE_TTL_MS) return c
        }
        val device = readDeviceContacts()

        // Normalize + hash locally; keep hash -> (name, number).
        val hashToContact = HashMap<String, Pair<String, String>>()
        for (c in device) {
            for (raw in c.second) {
                val e164 = normalizeE164(raw) ?: continue
                val h = sha256Hex(e164)
                if (!hashToContact.containsKey(h)) hashToContact[h] = Pair(c.first, e164)
            }
        }
        if (hashToContact.isEmpty()) return DiscoveryResult(emptyList(), emptyList())

        // Upload ONLY the hashes (batch <= 2000).
        val matched = ArrayList<DiscoverMatch>()
        for (batch in hashToContact.keys.chunked(2000)) {
            val body = ApiClient.json.encodeToString(DiscoverBody.serializer(), DiscoverBody(batch))
            val env: DiscoverEnvelope = api.requestAs("POST", "contacts/discover", jsonBody = body)
            matched.addAll(env.matches)
        }

        val myId = tokens.userId
        val seenUsers = HashSet<String>()
        val matchedHashes = HashSet<String>()
        val matches = ArrayList<VContact>()
        for (m in matched) {
            if (m.user_id == myId) continue
            matchedHashes.add(m.phone_hash)
            if (!seenUsers.add(m.user_id)) continue
            val saved = hashToContact[m.phone_hash]
            val savedName = saved?.first
            // Remember the saved name + number so the contact profile can show the
            // real number (the backend never returns it — privacy by design).
            ContactDirectory.put(appContext, m.user_id, savedName, saved?.second)
            matches.add(VContact(m.user_id, savedName ?: m.full_name ?: "VOIID user", m.photo_url))
        }

        // Persist resolved links (user_ids only).
        if (matches.isNotEmpty()) {
            val body = ApiClient.json.encodeToString(
                SyncBody.serializer(),
                SyncBody(matches.map { SyncContact(it.userId, it.displayName) }))
            runCatching { api.request("POST", "contacts/sync", jsonBody = body) }
        }

        // The rest are invite candidates.
        val invites = ArrayList<InviteContact>()
        val seenNumbers = HashSet<String>()
        for ((h, info) in hashToContact) {
            if (matchedHashes.contains(h)) continue
            if (!seenNumbers.add(info.second)) continue
            invites.add(InviteContact(info.first, info.second))
        }

        val result = DiscoveryResult(
            matches.sortedBy { it.displayName.lowercase() },
            invites.sortedBy { it.name.lowercase() },
        )
        cached = result; cachedAt = System.currentTimeMillis()
        return result
    }

    private suspend fun readDeviceContacts(): List<Pair<String, List<String>>> = withContext(Dispatchers.IO) {
        val byName = LinkedHashMap<String, MutableList<String>>()
        val cursor = appContext.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            null, null, null,
        )
        cursor?.use {
            val nameIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (it.moveToNext()) {
                val name = if (nameIdx >= 0) it.getString(nameIdx) ?: "" else ""
                val num = if (numIdx >= 0) it.getString(numIdx) ?: "" else ""
                if (num.isBlank()) continue
                val key = name.ifBlank { num }
                byName.getOrPut(key) { mutableListOf() }.add(num)
            }
        }
        byName.map { (k, v) -> Pair(k, v.toList()) }
    }

    fun normalizeE164(raw: String): String? {
        var s = raw.filter { it.isDigit() || it == '+' }
        if (s.startsWith("+")) return if (s.length > 6) s else null
        s = s.trimStart('0')
        if (s.length < 6) return null
        return defaultCountryCode + s
    }

    private fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
            .joinToString("") { "%02x".format(it) }

    @Serializable private data class DiscoverBody(val phone_hashes: List<String>)
    @Serializable private data class DiscoverMatch(
        val user_id: String, val phone_hash: String,
        val full_name: String? = null, val photo_url: String? = null)
    @Serializable private data class DiscoverEnvelope(val matches: List<DiscoverMatch>)
    @Serializable private data class SyncContact(val contact_user_id: String, val saved_name: String? = null)
    @Serializable private data class SyncBody(val contacts: List<SyncContact>)
}
