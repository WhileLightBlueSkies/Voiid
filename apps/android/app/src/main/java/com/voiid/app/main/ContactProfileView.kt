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
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.PhotoLibrary
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.DummyData
import com.voiid.app.model.VConversation
import com.voiid.app.net.ContactDirectory
import com.voiid.app.net.ProfileService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.ProfilePhotoViewer
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** 1:1 contact profile (WhatsApp-style) — port of iOS `ContactProfileView.swift`. */
@Composable
fun ContactProfileView(
    conversation: VConversation,
    onBack: () -> Unit,
    /**
     * Call / Video ask the CHAT to place the call rather than doing it here. ChatDetailView
     * already owns peer resolution and the group-call lock; duplicating that would let the two
     * paths drift. These buttons used to be empty `haptics.tap()` closures — decoration.
     */
    onStartCall: (CallKind) -> Unit = {},
) {
    BackHandler { onBack() }
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var muted by remember { mutableStateOf(false) }
    var showAllMedia by remember { mutableStateOf(false) }
    var viewPhoto by remember { mutableStateOf(false) }
    /** "block" | "report" | null — Block and Report have no backend yet (no route, no table),
     *  so they confirm and then say so plainly. A safety button that appears to succeed and
     *  silently does nothing is worse than one that admits it is not built. */
    var confirm by remember { mutableStateOf<String?>(null) }
    var notImplemented by remember { mutableStateOf<String?>(null) }
    var photoUrl by remember { mutableStateOf<String?>(null) }

    // Real profile: full name + @username from the backend; the phone number from
    // the on-device contact match (the API never returns a phone — privacy).
    var fullName by remember { mutableStateOf<String?>(null) }
    var username by remember { mutableStateOf<String?>(null) }
    var bio by remember { mutableStateOf<String?>(null) }
    /** The one-line status — a field DISTINCT from `bio` that the server has always returned
     *  and this screen never read, which is why a contact's status never appeared. */
    var statusText by remember { mutableStateOf<String?>(null) }
    val savedNumber = remember(conversation.peerUserId) {
        conversation.peerUserId?.let { ContactDirectory.get(context, it).number }
    }
    LaunchedEffect(conversation.peerUserId) {
        val peer = conversation.peerUserId ?: return@LaunchedEffect
        runCatching { ProfileService(context).fetchUser(peer) }.getOrNull()?.let { u ->
            fullName = u.full_name?.takeIf { it.isNotBlank() }
            username = u.username?.takeIf { it.isNotBlank() }
            bio = u.bio?.takeIf { it.isNotBlank() }
            photoUrl = u.photo_url?.takeIf { it.isNotBlank() }
            statusText = u.status_text?.takeIf { it.isNotBlank() }
        }
    }

    confirm?.let { which ->
        val isBlock = which == "block"
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirm = null },
            containerColor = VoiidColor.surfaceCard,
            title = {
                Text(
                    if (isBlock) "Block ${conversation.title}?" else "Report ${conversation.title}?",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                )
            },
            text = {
                Text(
                    if (isBlock) "They won’t be able to message or call you."
                    else "The last few messages from this chat are sent to Voiid for review.",
                    style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirm = null
                    notImplemented = if (isBlock) "Blocking isn’t available yet." else "Reporting isn’t available yet."
                }) { Text(if (isBlock) "Block" else "Report", color = VoiidColor.error) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirm = null }) {
                    Text("Cancel", color = VoiidColor.textSecondary)
                }
            },
        )
    }
    notImplemented?.let { msg ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { notImplemented = null },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Not available yet", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = { Text(msg, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { notImplemented = null }) {
                    Text("OK", color = VoiidColor.primary)
                }
            },
        )
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        // Native iOS-26 circular back button
        VoiidCircleBack(onBack = onBack)

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // Header
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                // The REAL photo. This was `VoiidAvatar` — the wordmark placeholder — so a
                // contact's own profile never showed their face.
                ProfileAvatar(
                    photoUrl = photoUrl ?: UserDirectory.photoUrl(conversation.peerUserId ?: ""),
                    name = conversation.title,
                    size = 112.dp,
                    modifier = Modifier.clip(CircleShape).clickable { haptics.tap(); viewPhoto = true },
                )
                Spacer(Modifier.height(10.dp))
                Text(conversation.title, style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
                // Real name, @username and phone number — same secondary style, one per line.
                // Each is shown only when known; the contact name above is the saved/display name.
                fullName?.takeIf { it != conversation.title }?.let {
                    Text(it, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                }
                username?.let {
                    Text("@$it", style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.primary)
                }
                savedNumber?.let {
                    Text(it, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                }
                Spacer(Modifier.height(8.dp))
                Spacer(Modifier.height(8.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    QuickAction(Icons.AutoMirrored.Filled.Message, "Message", Modifier.weight(1f)) { haptics.tap(); onBack() }
                    QuickAction(Icons.Default.Call, "Call", Modifier.weight(1f)) { haptics.tap(); onStartCall(CallKind.VOICE); onBack() }
                    QuickAction(Icons.Default.Videocam, "Video", Modifier.weight(1f)) { haptics.tap(); onStartCall(CallKind.VIDEO); onBack() }
                }
            }

            // About
            // About AND status — two distinct fields. This screen only ever read `bio`, so a
            // contact who set a status showed nothing at all here.
            ProfileCard {
                statusText?.let { st ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.FormatQuote, null, tint = VoiidColor.primary, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(st, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
                    }
                    if (!bio.isNullOrBlank()) {
                        Spacer(Modifier.height(10.dp))
                        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.4f)))
                        Spacer(Modifier.height(10.dp))
                    }
                }
                bio?.takeIf { it.isNotBlank() }?.let {
                    Text("About", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textSecondary)
                    Text(it, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
                }
                // Only when BOTH are absent — otherwise a peer with a real status was shown
                // "Hey there! I am using Voiid.", a message they never wrote.
                if (statusText.isNullOrBlank() && bio.isNullOrBlank()) {
                    Text("About", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textSecondary)
                    Text("Hey there! I am using Voiid.", style = VoiidFont.rounded(16), color = VoiidColor.textSecondary)
                }
            }

            // Shared media — REAL recent photos from the message store (never DummyData).
            // Videos count too — this filtered to `image/` only, so a chat full of videos
            // reported "no media shared yet".
            val sharedMedia = remember(conversation.id) {
                com.voiid.app.net.ChatEngine.get(context).messages(conversation.id)
                    .mapNotNull { it.media }
                    .filter { it.mime.startsWith("image/") || it.mime.startsWith("video/") }
                    .reversed()
            }
            val recentPhotos = sharedMedia.take(8)
            ProfileCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Media", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    if (sharedMedia.isNotEmpty()) {
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier.clip(RoundedCornerShape(999.dp)).background(VoiidColor.fieldFill)
                                .padding(horizontal = 7.dp, vertical = 2.dp),
                        ) {
                            Text("${sharedMedia.size}", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (recentPhotos.isNotEmpty()) {
                        Text("See all", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.primary, modifier = Modifier.clickable { haptics.tap(); showAllMedia = true })
                    }
                }
                if (recentPhotos.isEmpty()) {
                    // A DESIGNED empty state, not a bare grey sentence. This card is empty for
                    // most contacts most of the time, so it is the state users actually see —
                    // treating it as an afterthought made the whole screen look unfinished.
                    Column(
                        Modifier.fillMaxWidth().padding(vertical = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(
                            Modifier.size(52.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.08f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Default.PhotoLibrary, null, tint = VoiidColor.primary.copy(alpha = 0.65f), modifier = Modifier.size(21.dp))
                        }
                        Text("No media yet", style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                        Text(
                            "Photos and videos you share with ${conversation.title} appear here.",
                            style = VoiidFont.rounded(12),
                            color = VoiidColor.textSecondary,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    }
                } else {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        recentPhotos.forEach { ref ->
                            Box(Modifier.size(72.dp).clip(RoundedCornerShape(VoiidRadius.md))) { SharedMediaThumb(ref) }
                        }
                    }
                }
            }

            // Settings
            ProfileCard {
                ToggleRow(Icons.Default.NotificationsOff, "Mute notifications", muted) { muted = it; haptics.selection() }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))

                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))

            }

            // Danger
            ProfileCard {
                ProfileRow(Icons.Default.Block, "Block ${conversation.title}", tint = VoiidColor.error) { haptics.rigid(); confirm = "block" }
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                ProfileRow(Icons.Default.Report, "Report ${conversation.title}", tint = VoiidColor.error) { haptics.rigid(); confirm = "report" }
            }
        }
    }

    if (showAllMedia) {
        SharedMediaSheet(conversationId = conversation.id, onDismiss = { showAllMedia = false })
    }
    if (viewPhoto) {
        ProfilePhotoViewer(title = conversation.title, onClose = { viewPhoto = false })
    }
}

@Composable
private fun QuickAction(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier.softClickable(onClick = onClick),
    ) {
        Box(
            // Equal-width, brand-tinted — matches iOS `quickAction`. The old fixed 56dp on a
            // pink accent wash left ragged gaps and used a colour that no longer exists.
            Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(19.dp)) }
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
        VoiidToggle(checked = checked, onCheckedChange = onChange)
    }
}
