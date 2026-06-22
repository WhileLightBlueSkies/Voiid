package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable

/**
 * Server-driven version negotiation + feature flags. On launch the app hits the
 * UNVERSIONED /config endpoint to learn the API version, server-toggled feature
 * flags, and whether THIS build must force-update. Mirrors iOS ConfigService.
 */
object ConfigService {
    @Volatile var featureFlags: Map<String, Boolean> = emptyMap(); private set

    @Serializable private data class StoreUrl(val ios: String? = null, val android: String? = null)
    @Serializable private data class ConfigDTO(
        val api_version: String = "v1",
        val force_update: Boolean = false,
        val feature_flags: Map<String, Boolean> = emptyMap(),
        val store_url: StoreUrl? = null,
    )

    /** Fetch remote config. Failures are ignored (fall back to built-in defaults). */
    suspend fun fetch(context: Context) {
        val tokens = TokenStore.get(context)
        val raw = runCatching { ApiClient(tokens).request("GET", "config", auth = false, versioned = false) }
            .getOrNull() ?: return
        val cfg = runCatching { ApiClient.json.decodeFromString<ConfigDTO>(raw) }.getOrNull() ?: return
        featureFlags = cfg.feature_flags
        if (cfg.force_update) UpdateGate.trigger(cfg.store_url?.android)
    }

    fun isEnabled(key: String): Boolean = featureFlags[key] ?: false
}
