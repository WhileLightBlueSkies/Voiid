package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.PrivacySettings
import com.voiid.app.model.MapVisibility
import com.voiid.app.net.MapPresenceEngine
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Settings -> Privacy. Port of iOS `PrivacySettingsView.swift`.
 *
 * Three toggles backed by [PrivacySettings] (plain SharedPreferences), each with a real
 * consumer elsewhere in the app — see that file's doc for the exact call sites. Plus Map
 * Ghost Mode / kill switch, backed by the real [MapPresenceEngine] singleton (a hard local
 * gate on the location provider, not a display filter).
 *
 * Deliberately absent, mirroring iOS: no blocking, last-seen visibility, profile-photo
 * visibility, disappearing messages, screenshot blocking, app lock, or "who can add me to
 * groups" — none of those has a schema, a route or a line of client code in this project.
 */
@Composable
fun PrivacySettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current

    var sendReceipts by remember { mutableStateOf(PrivacySettings.sendReadReceipts(context)) }
    var sendTyping by remember { mutableStateOf(PrivacySettings.sendTypingIndicators(context)) }
    var showOnline by remember { mutableStateOf(PrivacySettings.showOnlineStatus(context)) }
    val mapVisibility by MapPresenceEngine.visibility.collectAsState()
    val haptics = LocalVoiidHaptics.current

    BackupScaffold(title = "Privacy", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        PrivacySection(
            header = "Message receipts",
            footer = "When these are off, this device stops sending read receipts and " +
                "typing indicators. It doesn't stop them arriving from other people — Voiid " +
                "has no setting for that — so you'll still see when someone is typing or has " +
                "read your message.",
        ) {
            PrivacyToggleRow("Send read receipts", sendReceipts) {
                sendReceipts = it; PrivacySettings.setSendReadReceipts(context, it)
            }
            PrivacyToggleRow("Send typing indicators", sendTyping) {
                sendTyping = it; PrivacySettings.setSendTypingIndicators(context, it)
            }
        }

        Spacer(Modifier.height(20.dp))

        PrivacySection(
            header = "Online status",
            footer = "Hides the online and last-seen line at the top of a chat. This changes " +
                "only what you see on this device — Voiid has no way to hide your own online " +
                "status from other people.",
        ) {
            PrivacyToggleRow("Show when contacts are online", showOnline) {
                showOnline = it; PrivacySettings.setShowOnlineStatus(context, it)
            }
        }

        Spacer(Modifier.height(20.dp))

        PrivacySection(
            header = "Map location",
            footer = "Ghost Mode hides you from everyone on the Map and stops your location " +
                "being taken at all — it's a hard switch, not a filter. You're hidden by " +
                "default and only ever visible to people you pick by name on the Map tab.",
        ) {
            PrivacyToggleRow("Ghost Mode", mapVisibility == MapVisibility.GHOST) { ghost ->
                haptics.tap()
                if (ghost) MapPresenceEngine.goGhost(0L) else MapPresenceEngine.goVisible()
            }
            Row(
                Modifier.fillMaxWidth()
                    .softClickable { haptics.tap(); MapPresenceEngine.killSwitch() }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Text("Stop all location sharing", style = VoiidFont.rounded(15), color = VoiidColor.error)
            }
        }
    }
}

@Composable
private fun PrivacySection(header: String, footer: String, content: @Composable () -> Unit) {
    Text(header, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
    Spacer(Modifier.height(8.dp))
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
        content = { content() },
    )
    Spacer(Modifier.height(8.dp))
    Text(footer, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
}

@Composable
private fun PrivacyToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        VoiidToggle(checked = checked, onCheckedChange = onChange)
    }
}
