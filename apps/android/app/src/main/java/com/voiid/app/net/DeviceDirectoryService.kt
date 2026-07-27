package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable

/**
 * The device directory for the SIGNED-IN account: list this user's active devices and
 * revoke one. Port of iOS `DeviceDirectoryService.swift` — backs
 * [com.voiid.app.main.LinkedDevicesScreen] and nothing else.
 *
 * SECURITY NOTE (backend, not here): `DELETE /devices/:device_id` is NOT scoped to the
 * caller (routes/devices.ts) — any authenticated user who learns another user's device id
 * can revoke it. Mitigation on this client is to never render or expose a raw device id;
 * [LinkedDevice.id] exists only as list identity and as the revoke call's argument.
 */
class DeviceDirectoryService(context: Context) {
    private val appContext = context.applicationContext
    private val api = ApiClient(TokenStore.get(appContext))

    data class LinkedDevice(
        val id: String,
        val name: String,
        val platform: String,
        val lastSeenMillis: Long?,
    ) {
        /** Voiid's Android and iOS clients are both phones; anything else is the web companion. */
        val isPhone: Boolean get() = platform.lowercase() in setOf("ios", "android")
    }

    @Serializable private data class DeviceDTO(
        val id: String,
        val platform: String? = null,
        val device_name: String? = null,
        val last_seen_at: String? = null,
    )
    @Serializable private data class DevicesResponse(val devices: List<DeviceDTO> = emptyList())

    /** Active (non-revoked) devices on this account, most recently seen first (server order). */
    suspend fun devices(): List<LinkedDevice> {
        val userId = TokenStore.get(appContext).userId ?: throw ApiError.NotAuthenticated
        val encoded = java.net.URLEncoder.encode(userId, "UTF-8")
        val env: DevicesResponse = api.requestAs("GET", "devices/$encoded")
        return env.devices.map { dto ->
            val platform = dto.platform ?: ""
            val trimmed = dto.device_name?.trim()
            val name = if (!trimmed.isNullOrEmpty()) trimmed else fallbackName(platform)
            LinkedDevice(id = dto.id, name = name, platform = platform, lastSeenMillis = parseIso(dto.last_seen_at))
        }
    }

    /** Revoke a device: it stops receiving new messages immediately and its one-time
     *  prekeys are dropped. Never call with this device's own id — see the class doc. */
    suspend fun revoke(deviceId: String) {
        val encoded = java.net.URLEncoder.encode(deviceId, "UTF-8")
        api.request("DELETE", "devices/$encoded")
    }

    /** Used only when the server has no `device_name` for a row — deliberately generic. */
    private fun fallbackName(platform: String): String = when (platform.lowercase()) {
        "ios" -> "iPhone"
        "android" -> "Android phone"
        "web" -> "Web"
        else -> "Unknown device"
    }

    /** Postgres timestamps arrive as ISO-8601, with or without fractional seconds depending
     *  on how the column was written. A date we cannot parse becomes null — "no last-active
     *  line" rather than a wrong one. */
    private fun parseIso(raw: String?): Long? {
        if (raw == null) return null
        return runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
    }
}
