package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Wallpaper
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.DummyData
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** 1:1 contact profile (WhatsApp-style) — port of iOS `ContactProfileView.swift`. */
@Composable
fun ContactProfileView(conversation: VConversation, onBack: () -> Unit) {
    BackHandler { onBack() }
    val haptics = LocalVoiidHaptics.current
    var muted by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        // Native-style back
        Box(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.CenterStart) {
            Icon(Icons.Default.ChevronLeft, "Back", tint = VoiidColor.primary,
                modifier = Modifier.size(28.dp).clickable { haptics.tap(); onBack() })
        }

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // Header
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                VoiidAvatar(size = 110.dp, modifier = Modifier.clip(CircleShape))
                Spacer(Modifier.height(8.dp))
                Text(conversation.title, style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
                Text("+91 91234 56789", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    QuickAction(Icons.AutoMirrored.Filled.Message, "Message") { haptics.tap(); onBack() }
                    QuickAction(Icons.Default.Call, "Call") { haptics.tap() }
                    QuickAction(Icons.Default.Videocam, "Video") { haptics.tap() }
                }
            }

            // About
            ProfileCard {
                Text("About", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textSecondary)
                Text("Hey there! I am using Voiid.", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
            }

            // Shared media
            ProfileCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Media, links & docs", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Text("See all", style = VoiidFont.rounded(13), color = VoiidColor.primary, modifier = Modifier.clickable { haptics.tap() })
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DummyData.sharedMedia.take(6).forEach { _ ->
                        Box(
                            Modifier.size(72.dp).clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.accent.copy(alpha = 0.35f)),
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Default.Image, null, tint = VoiidColor.primary) }
                    }
                }
            }

            // Settings
            ProfileCard {
                ToggleRow(Icons.Default.NotificationsOff, "Mute notifications", muted) { muted = it; haptics.selection() }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                ProfileRow(Icons.Default.Search, "Search in chat", tint = VoiidColor.textPrimary) { haptics.tap() }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                ProfileRow(Icons.Default.Wallpaper, "Wallpaper", tint = VoiidColor.textPrimary) { haptics.tap() }
            }

            // Danger
            ProfileCard {
                ProfileRow(Icons.Default.Block, "Block ${conversation.title}", tint = VoiidColor.error) { haptics.rigid() }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                ProfileRow(Icons.Default.Report, "Report ${conversation.title}", tint = VoiidColor.error) { haptics.rigid() }
            }
        }
    }
}

@Composable
private fun QuickAction(icon: ImageVector, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier.softClickable(onClick = onClick)) {
        Box(
            Modifier.width(56.dp).height(48.dp).clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.accent.copy(alpha = 0.4f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp)) }
        Text(label, style = VoiidFont.rounded(11, FontWeight.Medium), color = VoiidColor.textSecondary)
    }
}

@Composable
fun ProfileCard(content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        content = content,
    )
}

@Composable
fun ProfileRow(icon: ImageVector, text: String, tint: Color, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
        Text(text, style = VoiidFont.rounded(16), color = tint)
    }
}

@Composable
fun ToggleRow(icon: ImageVector, text: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Icon(icon, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(22.dp))
        Text(text, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        Switch(
            checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White, checkedTrackColor = VoiidColor.primary,
                uncheckedTrackColor = VoiidColor.fieldFill, uncheckedBorderColor = VoiidColor.fieldBorder,
            ),
        )
    }
}
