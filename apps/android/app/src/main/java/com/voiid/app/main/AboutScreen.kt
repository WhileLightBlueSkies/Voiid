package com.voiid.app.main

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.BuildConfig
import com.voiid.app.net.ApiConfig
import com.voiid.app.net.ConfigService
import com.voiid.app.net.E2EManager
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Settings -> About. Port of iOS `AboutView.swift`.
 *
 * Every value here is read live, never a literal — the exact bug this screen's iOS
 * counterpart calls out (`OnboardingFlow.swift` hardcoding "v1.0.0 (15)"). No Legal
 * section: Voiid has no privacy-policy, terms, or help URL anywhere in the repo (not in
 * Info.plist/manifest, not in /config, not in docs/) — a row that opens nothing, or a
 * plausible-looking invented URL, would be the exact failure this screen exists to avoid.
 * No "Send Logs": there is no log sink in the app to send.
 */
@Composable
fun AboutScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current

    val appVersion = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"
    val server = runCatching { java.net.URI(ApiConfig.baseUrl).host }.getOrNull() ?: "—"
    val apiVersion = ConfigService.apiVersion
    val userId = TokenStore.get(context).userId ?: "—"
    val deviceId = E2EManager.get(context).deviceId ?: "—"

    val diagnosticsText = """
        Voiid diagnostics
        Version: $appVersion
        Server: $server
        API version: $apiVersion
        User ID: $userId
        Device ID: $deviceId
    """.trimIndent()

    BackupScaffold(title = "About", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        AboutSection(header = "App") {
            AboutRow("Version", appVersion)
        }

        Spacer(Modifier.height(20.dp))

        AboutSection(header = "Connection") {
            AboutRow("Server", server)
            AboutRow("API version", apiVersion)
        }

        Spacer(Modifier.height(20.dp))

        AboutSection(
            header = "Identifiers",
            footer = "Support may ask for these if something goes wrong. They identify " +
                "your account and this device — nothing else.",
        ) {
            AboutRow("User ID", userId, truncateMiddle = true)
            AboutRow("Device ID", deviceId, truncateMiddle = true)
        }

        Spacer(Modifier.height(20.dp))

        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
        ) {
            Row(
                Modifier.fillMaxWidth()
                    .softClickable {
                        haptics.tap()
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, "Voiid diagnostics")
                            putExtra(Intent.EXTRA_TEXT, diagnosticsText)
                        }
                        context.startActivity(Intent.createChooser(send, "Share Diagnostics"))
                    }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Default.Share, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
                Text("Share Diagnostics", style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "Includes only the values shown above. No messages, contacts or keys.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )
    }
}

@Composable
private fun AboutSection(header: String, footer: String? = null, content: @Composable () -> Unit) {
    Text(header, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
    Spacer(Modifier.height(8.dp))
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
        content = { content() },
    )
    if (footer != null) {
        Spacer(Modifier.height(8.dp))
        Text(footer, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun AboutRow(title: String, value: String, truncateMiddle: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        Text(
            if (truncateMiddle) middleTruncate(value) else value,
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            maxLines = 1,
        )
    }
}

/** Truncates the middle of a long opaque id so both ends — what someone reads aloud to
 *  support — stay visible, mirroring iOS's `.truncationMode(.middle)`. */
private fun middleTruncate(text: String, keep: Int = 10): String {
    if (text.length <= keep * 2 + 1) return text
    return "${text.take(keep)}…${text.takeLast(keep)}"
}
