package com.voiid.app.net

import java.net.URI

/**
 * Accept ONLY Voiid's companion QR payload — `voiid://link?token=<32 url-safe chars>` — and
 * never follow an arbitrary scanned URL. Twin of iOS `LinkBrowserCode.swift`, same rules.
 */
object LinkBrowserCode {
    private val TOKEN = Regex("^[A-Za-z0-9_-]{32}$")

    fun token(raw: String): String? {
        if (raw.toByteArray().size >= 256) return null
        val uri = runCatching { URI(raw) }.getOrNull() ?: return null
        if (uri.scheme != "voiid" || uri.host != "link") return null
        if (uri.rawUserInfo != null || uri.port != -1 || uri.rawFragment != null) return null
        if (!uri.rawPath.isNullOrEmpty()) return null
        val items = uri.rawQuery?.split("&") ?: return null
        if (items.size != 1) return null
        val (name, value) = items[0].split("=", limit = 2).takeIf { it.size == 2 } ?: return null
        if (name != "token" || !TOKEN.matches(value)) return null
        return value
    }
}
