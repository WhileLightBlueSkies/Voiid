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
    }

    private val api = ApiClient(TokenStore.get(context))
    private val prefs = SecurePrefs.open(context, "voiid_e2e")

    var identity: Identity? = null; private set
    var deviceId: String? = null; private set
    @Volatile private var bootstrapped = false

    /** Ensure this device has a published e2e-core identity. Idempotent per session. */
    suspend fun bootstrap() {
        if (bootstrapped) return
        val id = loadOrCreateIdentity()
        identity = id
        val bundle = id.publishBundle(100u)
        persist(id)
        publish(bundle)
        bootstrapped = true
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

    private suspend fun publish(bundle: PublicBundle) {
        val regBody = ApiClient.json.encodeToString(
            RegisterBody.serializer(),
            RegisterBody("android", registrationId(), bundle.identityKey))
        val dev: DeviceResp = api.requestAs("POST", "devices/register", jsonBody = regBody)
        deviceId = dev.device_id
        prefs.edit().putString("device_id", dev.device_id).apply()

        val otks = bundle.oneTimeKeys.mapIndexed { i, k -> Otk(i, k) }
        val pkBody = ApiClient.json.encodeToString(
            PrekeysBody.serializer(), PrekeysBody(dev.device_id, otks))
        api.request("POST", "prekeys/upload", jsonBody = pkBody)
    }
}
