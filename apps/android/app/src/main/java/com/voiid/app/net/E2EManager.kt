package com.voiid.app.net

import android.content.Context
import android.util.Base64
import kotlinx.serialization.Serializable
import uniffi.voiid.Identity
import uniffi.voiid.PublicBundle
import java.security.SecureRandom

/**
 * Owns the device's e2e-core Identity (root of all E2EE). On login it restores or
 * creates the Identity, registers the device (identity public key), and publishes
 * one-time prekeys so peers can start sessions with us. Mirrors iOS E2EManager.
 *
 * Identity pickle + 32-byte pickle key live in EncryptedSharedPreferences only.
 */
class E2EManager private constructor(context: Context) {

    companion object {
        @Volatile private var instance: E2EManager? = null
        fun get(context: Context): E2EManager =
            instance ?: synchronized(this) {
                instance ?: E2EManager(context.applicationContext).also { instance = it }
            }

        private const val TARGET_PREKEYS = 100   // refill toward this many available
        private const val LOW_WATERMARK = 20     // replenish once we drop below this
        // Start ids above the legacy 0..99 range a pre-replenishment build used,
        // so upgrades never collide with already-stored key ids.
        private const val PREKEY_ID_BASE = 100
    }

    private val api = ApiClient(TokenStore.get(context))
    private val prefs = SecurePrefs.open(context, "voiid_e2e")

    var identity: Identity? = null; private set
    var deviceId: String? = null; private set
    @Volatile private var bootstrapped = false

    /** Ensure this device has a published e2e-core identity. Idempotent per session. */
    suspend fun bootstrap() {
        if (bootstrapped) return
        try {
            val id = loadOrCreateIdentity()
            identity = id
            android.util.Log.i("VOIID", "bootstrap: identity ready")
            val devId = withTransportRetry { register(id) }
            deviceId = devId
            android.util.Log.i("VOIID", "bootstrap: registered device=$devId")
            withTransportRetry { ensurePrekeys(id, devId) }
            android.util.Log.i("VOIID", "bootstrap: prekeys ensured")
            bootstrapped = true
        } catch (e: Exception) {
            android.util.Log.e("VOIID", "bootstrap FAILED", e)
            throw e
        }
    }

    /** Retry a network step a few times on transport errors (timeouts / flaky net)
     *  instead of permanently failing bootstrap on the first hiccup. */
    private suspend fun <T> withTransportRetry(op: suspend () -> T): T {
        var last: Exception? = null
        repeat(3) { attempt ->
            try { return op() } catch (e: ApiError.Transport) {
                last = e
                android.util.Log.w("VOIID", "transport error (attempt ${attempt + 1}/3): ${e.message}")
                kotlinx.coroutines.delay((attempt + 1) * 1500L)
            }
        }
        throw last ?: ApiError.Http(0, "network")
    }

    /**
     * Top up our published one-time prekeys when the server says we're running
     * low. Each inbound session a peer starts with us consumes one one-time key;
     * if they all get consumed and we never replenish, NEW peers can't message us
     * ("peer has no available prekeys"). Safe to call repeatedly (e.g. on resume).
     */
    suspend fun ensurePrekeys(id: Identity? = identity, devId: String? = deviceId) {
        if (id == null || devId == null) return
        val available = runCatching { availableCount() }.getOrElse {
            android.util.Log.e("VOIID", "availableCount failed", it); 0
        }
        android.util.Log.i("VOIID", "ensurePrekeys: available=$available")
        if (available >= LOW_WATERMARK) return
        val max = runCatching { id.maxOneTimeKeys().toInt() }.getOrDefault(TARGET_PREKEYS)
        val target = minOf(TARGET_PREKEYS, max)
        val need = (target - available).coerceIn(0, max)
        if (need <= 0) return
        // Generate `need` NEW one-time keys (returns only the new ones), persist the
        // identity BEFORE upload so a crash can't lose the private halves, then upload.
        val bundle = id.replenishPrekeys(need.toUInt())
        persist(id)
        android.util.Log.i("VOIID", "ensurePrekeys: uploading ${bundle.oneTimeKeys.size} keys (need=$need max=$max)")
        uploadPrekeys(devId, bundle.oneTimeKeys)
    }

    private fun loadOrCreateIdentity(): Identity {
        val key = pickleKey()
        prefs.getString("identity_pickle", null)?.let { pickle ->
            runCatching { return Identity.restore(pickle, key) }  // fall through if corrupt
        }
        val id = Identity.create()
        persist(id, key)
        return id
    }

    private fun persist(id: Identity, key: ByteArray = pickleKey()) {
        prefs.edit().putString("identity_pickle", id.toPickle(key)).apply()
    }

    private fun pickleKey(): ByteArray {
        prefs.getString("pickle_key", null)?.let { return Base64.decode(it, Base64.NO_WRAP) }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString("pickle_key", Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
        return bytes
    }

    private fun registrationId(): Int {
        val existing = prefs.getInt("registration_id", 0)
        if (existing != 0) return existing
        val n = SecureRandom().nextInt(0x7FFFFFFE) + 1
        prefs.edit().putInt("registration_id", n).apply()
        return n
    }

    @Serializable private data class RegisterBody(
        val platform: String, val registration_id: Int, val identity_public_key: String)
    @Serializable private data class DeviceResp(val device_id: String)
    @Serializable private data class Otk(val key_id: Int, val public_key: String)
    @Serializable private data class PrekeysBody(val device_id: String, val one_time_prekeys: List<Otk>)
    @Serializable private data class CountResp(val available: Int = 0)

    /** Register (or refresh) this device server-side; returns the device id. */
    private suspend fun register(id: Identity): String {
        // publishBundle(0) yields the long-term identity key without generating
        // any one-time keys (those are managed separately by [ensurePrekeys]).
        val identityKey = id.publishBundle(0u).identityKey
        persist(id)
        val regBody = ApiClient.json.encodeToString(
            RegisterBody.serializer(),
            RegisterBody("android", registrationId(), identityKey))
        val dev: DeviceResp = api.requestAs("POST", "devices/register", jsonBody = regBody)
        prefs.edit().putString("device_id", dev.device_id).apply()
        return dev.device_id
    }

    /** Our remaining unconsumed one-time prekeys on the server. */
    private suspend fun availableCount(): Int {
        val res: CountResp = api.requestAs("GET", "prekeys/count")
        return res.available
    }

    /** Upload public one-time prekeys with MONOTONIC key ids (the server keys on
     *  (device_id, key_id) with do-nothing-on-conflict, so ids must never repeat
     *  across uploads or the replenished keys would be silently dropped). */
    private suspend fun uploadPrekeys(devId: String, keys: List<String>) {
        if (keys.isEmpty()) return
        var nextId = prefs.getInt("prekey_next_id", PREKEY_ID_BASE)
        val otks = keys.map { Otk(nextId++, it) }
        prefs.edit().putInt("prekey_next_id", nextId).apply()
        val pkBody = ApiClient.json.encodeToString(
            PrekeysBody.serializer(), PrekeysBody(devId, otks))
        api.request("POST", "prekeys/upload", jsonBody = pkBody)
    }
}
