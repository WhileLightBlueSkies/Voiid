package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import com.voiid.app.ui.components.ProfilePhotoViewer
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/** Group info (WhatsApp-style) — port of iOS `GroupInfoView.swift`. Backed by REAL group
 *  membership from the server; add/remove are wired to the MLS [GroupEngine] via ChatStore. */
@Composable
fun GroupInfoView(conversation: VConversation, chat: com.voiid.app.model.ChatStore, onBack: () -> Unit) {
    BackHandler { onBack() }
    val haptics = LocalVoiidHaptics.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var muted by remember { mutableStateOf(false) }
    val members = remember { mutableStateListOf<VMember>() }
    var memberAction by remember { mutableStateOf<VMember?>(null) }
    var showAllMedia by remember { mutableStateOf(false) }
    var viewPhoto by remember { mutableStateOf(false) }
    var showAddMembers by remember { mutableStateOf(false) }

    // Load REAL members from the server (user_id carried in VMember.id so admin ops target it).
    fun reloadMembers() {
        scope.launch {
            runCatching { com.voiid.app.net.ChatService(context).fetchMembers(conversation.id) }.getOrNull()?.let { list ->
                members.clear()
                members.addAll(list.map { VMember(id = it.userId, name = it.name, phone = "", isYou = it.isYou) })
            }
        }
    }
    androidx.compose.runtime.LaunchedEffect(conversation.id) { reloadMembers() }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        VoiidCircleBack(onBack = onBack)

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // Header: photo (+ camera badge), editable name, "Group · N members"
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(contentAlignment = Alignment.BottomEnd) {
                    Box(
                        Modifier.size(110.dp).clip(CircleShape).background(VoiidColor.fieldFill)
                            .clickable { haptics.tap(); viewPhoto = true },
                        contentAlignment = Alignment.Center,
                    ) {
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
                    Text("See all", style = VoiidFont.rounded(13), color = VoiidColor.primary, modifier = Modifier.clickable { haptics.tap(); showAllMedia = true })
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
                ProfileRow(Icons.Default.PersonAddAlt, "Add members", tint = VoiidColor.primary) { haptics.tap(); showAddMembers = true }
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
                TextButton(onClick = {
                    // Real MLS remove (rekeys the group so the removed member can't read on).
                    chat.removeGroupMember(conversation.id, m.id) { reloadMembers() }
                    members.removeAll { it.id == m.id }
                    memberAction = null
                }) {
                    Text("Remove from group", color = VoiidColor.error)
                }
            },
        )
    }

    if (showAddMembers) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showAddMembers = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            AddGroupMembersScreen(
                existingUserIds = members.map { it.id }.toSet(),
                onClose = { showAddMembers = false },
                onAdd = { userId -> chat.addGroupMember(conversation.id, userId) { reloadMembers() } },
            )
        }
    }

    if (showAllMedia) {
        SharedMediaSheet(onDismiss = { showAllMedia = false })
    }
    if (viewPhoto) {
        ProfilePhotoViewer(title = conversation.title, onClose = { viewPhoto = false })
    }
}

/** Contact picker for adding members to an existing MLS group. Each tap adds that user
 *  (all their devices) via the [GroupEngine] and marks them added. */
@Composable
private fun AddGroupMembersScreen(existingUserIds: Set<String>, onClose: () -> Unit, onAdd: (String) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var loading by remember { mutableStateOf(true) }
    var matches by remember { mutableStateOf<List<com.voiid.app.net.VContact>>(emptyList()) }
    val added = remember { mutableStateListOf<String>() }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.READ_CONTACTS,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) {
            runCatching { com.voiid.app.net.ContactsService(context).discover().matches }.getOrNull()?.let { matches = it }
        }
        loading = false
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Cancel", style = VoiidFont.rounded(16), color = VoiidColor.primary, modifier = Modifier.clickable { onClose() })
            Spacer(Modifier.weight(1f))
            Text("Add members", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Text("Done", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.primary, modifier = Modifier.clickable { onClose() })
        }
        val selectable = matches.filter { it.userId !in existingUserIds }
        LazyColumn(Modifier.fillMaxSize()) {
            items(selectable, key = { it.userId }) { c ->
                val isAdded = added.contains(c.userId)
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = !isAdded) {
                        added.add(c.userId); onAdd(c.userId)
                    }.padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    VoiidAvatar(size = 40.dp, modifier = Modifier.clip(CircleShape))
                    Spacer(Modifier.size(12.dp))
                    Text(c.displayName, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                    Text(if (isAdded) "Added" else "Add",
                        style = VoiidFont.rounded(14, FontWeight.SemiBold),
                        color = if (isAdded) VoiidColor.textSecondary else VoiidColor.primary)
                }
            }
            if (!loading && selectable.isEmpty()) {
                item {
                    Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) {
                        Text("No contacts to add.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                    }
                }
            }
        }
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
