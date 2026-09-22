package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Help & support — port of iOS `HelpAndSupportView`, with the same copy verbatim.
 *
 * WHAT THIS SCREEN REFUSES TO DO, and why it matches iOS: there is no "FAQ" that opens a
 * page nobody wrote, and no "Contact us" that opens nothing. Every answer here is about
 * something the app actually does, and the one thing it cannot do — put you in touch with a
 * human — is simply absent rather than faked with a dead link.
 *
 * The support row appears the moment there is an address to point it at: set [SUPPORT_EMAIL]
 * and the section renders itself. iOS keeps its own `supportAddress` nil for exactly this
 * reason, so both platforms currently show the same three sections and no contact row.
 */
private val SUPPORT_EMAIL: String? = null

@Composable
fun HelpAndSupportScreen(
    onBack: () -> Unit,
    onReplayWalkthrough: () -> Unit,
    onLinkedDevices: () -> Unit,
    onBackupRecovery: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val appVersion = "${com.voiid.app.BuildConfig.VERSION_NAME} (${com.voiid.app.BuildConfig.VERSION_CODE})"
    val server = runCatching { java.net.URI(com.voiid.app.net.ApiConfig.baseUrl).host }.getOrNull() ?: "—"
    val apiVersion = com.voiid.app.net.ConfigService.apiVersion
    val userId = com.voiid.app.net.TokenStore.get(context).userId ?: "—"
    val deviceId = com.voiid.app.net.E2EManager.get(context).deviceId ?: "—"

    val diagnosticsText = """
        Voiid diagnostics
        Version: $appVersion
        Server: $server
        API version: $apiVersion
        User ID: $userId
        Device ID: $deviceId
    """.trimIndent()

    BackupScaffold(title = "Help & support", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        HelpSection(
            title = "Learn Voiid",
            body = "Take a short guided tour of the features available in this version.",
            footer = "You can replay the walkthrough whenever you need it.",
            actionLabel = "Replay app walkthrough",
            onAction = onReplayWalkthrough,
        )

        HelpSection(
            title = "Your messages",
            body = "Messages, calls, media and shared locations are end-to-end encrypted. " +
                "Keys are generated on your device and never leave it.",
            footer = "Voiid's servers relay ciphertext. They cannot read a message, hear a " +
                "call, or see a location you share.",
        )

        HelpSection(
            title = "If you lose your phone",
            body = "Your chats can be restored on a new device from an encrypted backup, " +
                "using either your PIN or your 24-word recovery phrase.\n\n" +
                "The recovery phrase is the stronger of the two and the one to keep safe: " +
                "nobody — including Voiid — can recover your backup without one of them.",
            footer = "Set this up before you need it — a backup cannot be created after the " +
                "device is gone.",
            actionLabel = "Open Backup & Recovery",
            onAction = onBackupRecovery,
        )

        HelpSection(
            title = "Linked devices",
            body = "A linked device gets its own keys and can read messages from the moment " +
                "it is linked. It cannot read anything sent before.",
            footer = "Unlink a device from Settings → Devices at any time.",
            actionLabel = "Open Devices",
            onAction = onLinkedDevices,
        )

        SUPPORT_EMAIL?.let { address ->
            HelpSection(
                title = "Still stuck?",
                body = "Email us and we'll get back to you.",
                actionLabel = "Contact support",
                onAction = {},
                actionMailto = address,
            )
        }

        HelpSection(
            title = "Diagnostics",
            body = "Share technical details with support to help troubleshoot issues.",
            footer = "Includes your app version, server and device identifiers. No message content.",
            actionLabel = "Share diagnostics",
            onAction = {
                val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(android.content.Intent.EXTRA_SUBJECT, "Voiid diagnostics")
                    putExtra(android.content.Intent.EXTRA_TEXT, diagnosticsText)
                }
                context.startActivity(android.content.Intent.createChooser(send, "Share diagnostics"))
            },
        )

        Spacer(Modifier.height(16.dp))
    }
}

/**
 * One card: a heading, the answer, an optional footer, and — where the answer names a screen
 * — a button that goes there. The iOS sections are read-only; these carry the jump because
 * the footers already say "Settings → Devices", and a sentence that names a destination
 * should be able to reach it.
 */
@Composable
private fun HelpSection(
    title: String,
    body: String,
    footer: String? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    actionMailto: String? = null,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val haptics = com.voiid.app.ui.components.LocalVoiidHaptics.current

    Column(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            title,
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp),
        )
        Column(
            Modifier.fillMaxWidth()
                .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(body, style = VoiidFont.rounded(14), color = VoiidColor.textPrimary)

            if (actionLabel != null) {
                Text(
                    actionLabel,
                    style = VoiidFont.rounded(14, androidx.compose.ui.text.font.FontWeight.SemiBold),
                    color = VoiidColor.primary,
                    modifier = Modifier.softClickable {
                        haptics.tap()
                        if (actionMailto != null) {
                            val mail = android.content.Intent(android.content.Intent.ACTION_SENDTO)
                                .setData(android.net.Uri.parse("mailto:$actionMailto"))
                            runCatching { context.startActivity(mail) }
                        } else {
                            onAction?.invoke()
                        }
                    },
                )
            }
        }
        if (footer != null) {
            Text(
                footer,
                style = VoiidFont.rounded(12),
                color = VoiidColor.textSecondary,
                modifier = Modifier.padding(start = 4.dp),
            )
        }
    }
}

/**
 * Chats — the appearance and story preferences that used to sit inline on the settings root,
 * port of iOS `ChatSettingsView`.
 *
 * They are the same controls, unchanged: chat list layout and app theme still apply the
 * instant you tap, which is why they are segmented pickers here rather than rows that push
 * further. What moved is only where they live — on the root they made one group a different
 * shape from every other, and put appearance at the same depth as Storage and Notifications,
 * which are doors rather than settings.
 */
@Composable
fun ChatSettingsScreen(onBack: () -> Unit) {
    BackupScaffold(title = "Chats", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        ChatPrefGroup("Appearance") {
            ChatLayoutRow()
            AppearanceRow()
        }

        // Stories: view-receipts opt-in (default OFF). Sending one tells the SERVER you
        // opened someone's story at time T — a fact it otherwise never learns, with no
        // sealed sender to hide it. The opt-out is reciprocal: OFF = you send none AND see
        // none. Written straight to the shared story prefs (see StoryPrefs).
        ChatPrefGroup(
            "Stories",
            footer = "Reciprocal: with this off you send no view receipts and see none either.",
        ) {
            StoryReceiptsRow()
        }

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun ChatPrefGroup(
    title: String,
    footer: String? = null,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            title,
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp),
        )
        Column(
            Modifier.fillMaxWidth()
                .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg)),
            content = content,
        )
        if (footer != null) {
            Text(
                footer,
                style = VoiidFont.rounded(12),
                color = VoiidColor.textSecondary,
                modifier = Modifier.padding(start = 4.dp),
            )
        }
    }
}
