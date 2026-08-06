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

    private val appContext = context.applicationContext
    private val api = ApiClient(TokenStore.get(context))
    private val prefs = SecurePrefs.open(context, "voiid_e2e")

    var identity: Identity? = null; private set
    // In-memory device id, falling back to the persisted one from a prior bootstrap —
    // so a send before bootstrap() finishes THIS session still carries our device_id.
    private var _deviceId: String? = null
    val deviceId: String? get() = _deviceId ?: prefs.getString("device_id", null)
    @Volatile private var bootstrapped = false

    /**
     * Called by [SessionTeardown] before the next account signs in on this device. Without
     * this, `bootstrapped` stays true and the next account's [bootstrap] returns immediately,
     * silently reusing the PREVIOUS account's identity — mirrors iOS
     * `E2EManager.resetForSignOut()`. Wipes the identity pickle, pickle key, device id and
     * prekey-id counters so the next bootstrap generates a fresh Identity from scratch.
     */
    fun resetForSignOut() {
        bootstrapped = false
        identity = null
        _deviceId = null
        prefs.edit().clear().apply()
    }

    /** Ensure this device has a published e2e-core identity. Idempotent per session. */
    suspend fun bootstrap() {
        if (bootstrapped) return
        try {
            val id = loadOrCreateIdentity()
            identity = id
            android.util.Log.i("VOIID", "bootstrap: identity ready")
            val devId = withTransportRetry { register(id) }
            _deviceId = devId
            android.util.Log.i("VOIID", "bootstrap: registered device=$devId")
            withTransportRetry { ensurePrekeys(id, devId) }
            android.util.Log.i("VOIID", "bootstrap: prekeys ensured")
            // MLS group messaging: create-or-restore this device's GroupMember and publish
            // its KeyPackages. Never throws (swallowed + logged inside) so a group-crypto
            // hiccup can't block 1:1 readiness.
            GroupEngine.get(appContext).bootstrap()
            android.util.Log.i("VOIID", "bootstrap: MLS ready")
            bootstrapped = true
        } catch (e: Exception) {
            android.util.Log.e("VOIID", "bootstrap FAILED", e)
            throw e
        }
    }

    /**
     * Persist this device's FCM push token and (if we're already registered) push it
     * to the backend on the SAME device row so the server can send wake notifications.
     * Called from [VoiidMessagingService.onNewToken] and safe to call before bootstrap —
     * the token is cached and [register] will attach it once the identity exists.
     */
    suspend fun registerPushToken(token: String) {
        val prev = prefs.getString("fcm_token", null)
        // Whether the token CURRENTLY CACHED was ever successfully accepted by the server.
        //
        // THE BUG THIS FIXES: the cache used to be written before the upload was attempted,
        // and the early-return compared against it. So a register that failed — offline,
        // 500, token expired mid-flight — cached the new token anyway, and every subsequent
        // call took `prev == token` and returned without ever retrying. The device was
        // ring-deaf until the token happened to change again, which for FCM can be months.
        //
        // So the skip now requires BOTH: same token AND a confirmed upload.
        val uploaded = prefs.getBoolean("fcm_token_uploaded", false)
        if (prev == token && uploaded) return

        val id = identity ?: run {
            // Not bootstrapped yet — register() will attach it. Cache the token so that
            // register() has it, but do NOT claim it was uploaded.
            prefs.edit().putString("fcm_token", token).putBoolean("fcm_token_uploaded", false).apply()
            return
        }

        // Cache the token BEFORE the call so register() reads the new value, and record the
        // upload result AFTER — the flag is what makes a failure retryable.
        prefs.edit().putString("fcm_token", token).putBoolean("fcm_token_uploaded", false).apply()
        runCatching { register(id) }
            .onSuccess { prefs.edit().putBoolean("fcm_token_uploaded", true).apply() }
            .onFailure { android.util.Log.e("VOIID", "registerPushToken failed", it) }
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
        val available = runCatching { availableCount(devId) }.getOrElse {
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

    /** Re-persist the current identity. MUST be called after acceptSession, which
     *  consumes a one-time prekey from the Account — without saving, that consumed
     *  state is lost on restart and the first inbound message becomes undecryptable. */
    fun persistIdentity() {
        identity?.let { persist(it) }
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
        val platform: String, val registration_id: Int, val identity_public_key: String,
        // Push routing: attached to the SAME device row (upsert keys on
        // (user_id, registration_id)) so the backend can send the wake push here.
        val push_token: String? = null, val push_provider: String? = null)
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
        // Include the cached FCM token (if any) so registration/refresh also attaches
        // (or updates) this device's push endpoint on the server in one call.
        val fcm = prefs.getString("fcm_token", null)
        val regBody = ApiClient.json.encodeToString(
            RegisterBody.serializer(),
            RegisterBody("android", registrationId(), identityKey,
                push_token = fcm, push_provider = fcm?.let { "fcm" }))
        val dev: DeviceResp = api.requestAs("POST", "devices/register", jsonBody = regBody)
        prefs.edit().putString("device_id", dev.device_id).apply()
        return dev.device_id
    }

    /** Our remaining unconsumed one-time prekeys on the server — scoped to THIS
     *  device (per-device, so a 2nd device doesn't see the 1st's keys and skip upload). */
    private suspend fun availableCount(devId: String): Int {
        val res: CountResp = api.requestAs("GET", "prekeys/count?device_id=$devId")
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
