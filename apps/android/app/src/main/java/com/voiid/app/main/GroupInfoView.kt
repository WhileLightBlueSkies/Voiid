package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.PersonAddAlt
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.DummyData
import com.voiid.app.model.MemberRole
import com.voiid.app.model.VConversation
import com.voiid.app.model.VMember
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** Group info (WhatsApp-style) — port of iOS `GroupInfoView.swift`. */
@Composable
fun GroupInfoView(conversation: VConversation, onBack: () -> Unit) {
    BackHandler { onBack() }
    val haptics = LocalVoiidHaptics.current
    var muted by remember { mutableStateOf(false) }
    val members = remember { mutableStateListOf<VMember>().apply { addAll(DummyData.groupMembers) } }
    var memberAction by remember { mutableStateOf<VMember?>(null) }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.CenterStart) {
            Icon(Icons.Default.ChevronLeft, "Back", tint = VoiidColor.primary,
                modifier = Modifier.size(28.dp).clickable { haptics.tap(); onBack() })
        }

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // Header: photo (+ camera badge), editable name, "Group · N members"
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(contentAlignment = Alignment.BottomEnd) {
                    Box(Modifier.size(110.dp).clip(CircleShape).background(VoiidColor.fieldFill), contentAlignment = Alignment.Center) {
                        VoiidWordmark(fontSize = 26, alpha = 0.25f)
                    }
                    Box(
                        Modifier.size(32.dp).clip(CircleShape).background(VoiidColor.accent).border(2.dp, VoiidColor.background, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Default.PhotoCamera, null, tint = VoiidColor.primary, modifier = Modifier.size(13.dp)) }
                }
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(conversation.title, style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
                    Icon(Icons.Default.Edit, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(14.dp))
                }
                Text("Group · ${members.size} members", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
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
                        Box(Modifier.size(72.dp).clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.accent.copy(alpha = 0.35f)),
                            contentAlignment = Alignment.Center) { Icon(Icons.Default.Image, null, tint = VoiidColor.primary) }
                    }
                }
            }

            // Members
            ProfileCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("${members.size} members", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Icon(Icons.Default.Search, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(20.dp))
                }
                ProfileRow(Icons.Default.PersonAddAlt, "Add members", tint = VoiidColor.primary) { haptics.tap() }
                ProfileRow(Icons.Default.Link, "Invite via link", tint = VoiidColor.primary) { haptics.tap() }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                members.forEach { m ->
                    MemberRow(m) { if (!m.isYou) { haptics.tap(); memberAction = m } }
                }
            }

            // Mute + exit
            ProfileCard {
                ToggleRow(Icons.Default.Block, "Mute notifications", muted) { muted = it; haptics.selection() }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                ProfileRow(Icons.Default.Logout, "Exit group", tint = VoiidColor.error) { haptics.rigid(); onBack() }
                ProfileRow(Icons.Default.Block, "Report group", tint = VoiidColor.error) { haptics.rigid() }
            }
        }
    }

    memberAction?.let { m ->
        AlertDialog(
            onDismissRequest = { memberAction = null },
            containerColor = VoiidColor.surfaceCard,
            title = { Text(m.name, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = null,
            confirmButton = {
                TextButton(onClick = { memberAction = null }) {
                    Text(if (m.role == MemberRole.ADMIN) "Dismiss as admin" else "Make group admin", color = VoiidColor.primary)
                }
            },
            dismissButton = {
                TextButton(onClick = { members.removeAll { it.id == m.id }; memberAction = null }) {
                    Text("Remove from group", color = VoiidColor.error)
                }
            },
        )
    }
}

@Composable
private fun MemberRow(m: VMember, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        VoiidAvatar(size = 42.dp, modifier = Modifier.clip(CircleShape))
        Column(Modifier.weight(1f)) {
            Text(if (m.isYou) "You" else m.name, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
            m.statusText?.let { Text(it, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary) }
        }
        if (m.role == MemberRole.ADMIN) {
            Text(
                "admin", style = VoiidFont.rounded(11, FontWeight.Medium), color = VoiidColor.primary,
                modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(VoiidColor.accent.copy(alpha = 0.4f)).padding(horizontal = 8.dp, vertical = 3.dp),
            )
        }
    }
}
