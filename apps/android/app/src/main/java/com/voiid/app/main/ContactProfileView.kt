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
import androidx.compose.foundation.border
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.fillMaxHeight
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
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Header.
            //
            // THE PAGE HAS ONE SUBJECT and the header is it. It was a 112dp avatar with 10dp
            // gaps to a 24sp name — the same rhythm as every card below, so the person the
            // page is ABOUT carried no more weight than a "Mute notifications" toggle.
            // Mirrors the iOS header exactly.
            Column(
                Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                ProfileAvatar(
                    photoUrl = photoUrl ?: UserDirectory.photoUrl(conversation.peerUserId ?: ""),
                    name = conversation.title,
                    size = 104.dp,
                    modifier = Modifier
                        .clip(CircleShape)
                        // A 1px ring at 8% — defines the edge against a light photo, invisible
                        // against a dark one. Heavier would read as a frame.
                        .border(1.dp, VoiidColor.textPrimary.copy(alpha = 0.08f), CircleShape)
                        .clickable { haptics.tap(); viewPhoto = true },
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    conversation.title,
                    style = VoiidFont.rounded(28, FontWeight.Bold)
                        // Optical tightening: at 28sp default tracking looks loose.
                        .copy(letterSpacing = (-0.4).sp),
                    color = VoiidColor.textPrimary,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    maxLines = 2,
                )

                // ONE line of secondary identity, not three stacked at equal weight. The real
                // name, handle and number were each on their own line in near-identical
                // styles, so none of them read as the way to identify this person. The handle
                // leads (it is what you share); the number follows, quieter, after a dot.
                val secondary = savedNumber ?: fullName?.takeIf { it != conversation.title }
                val handle = username?.let { "@$it" }
                if (handle != null || secondary != null) {
                    Spacer(Modifier.height(5.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        handle?.let {
                            Text(it, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.primary)
                        }
                        if (handle != null && secondary != null) {
                            Box(Modifier.size(3.dp).clip(CircleShape).background(VoiidColor.textSecondary.copy(alpha = 0.4f)))
                        }
                        secondary?.let {
                            Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                        }
                    }
                }

                Spacer(Modifier.height(24.dp))
                // ONE SEGMENTED CONTROL, not three floating tinted rectangles with captions
                // underneath — those read as three unrelated buttons that happen to sit in a
                // row. A single surface with hairline separators reads as one control with
                // three choices, and moving the label inside kills 20dp of vertical noise.
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(58.dp)
                        .clip(RoundedCornerShape(VoiidRadius.lg))
                        .background(VoiidColor.surfaceCard),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    QuickAction(Icons.AutoMirrored.Filled.Message, "Message", Modifier.weight(1f)) { haptics.tap(); onBack() }
                    ActionSeparator()
                    QuickAction(Icons.Default.Call, "Call", Modifier.weight(1f)) { haptics.tap(); onStartCall(CallKind.VOICE); onBack() }
                    ActionSeparator()
                    QuickAction(Icons.Default.Videocam, "Video", Modifier.weight(1f)) { haptics.tap(); onStartCall(CallKind.VIDEO); onBack() }
                }
            }

            // About AND status — two distinct fields. This screen only ever read `bio`, so a
            // contact who set a status showed nothing at all here.
            ProfileCard("About") {
                statusText?.let { st ->
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Default.FormatQuote, null, tint = VoiidColor.primary,
                            modifier = Modifier.size(15.dp).padding(top = 2.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(st, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary)
                    }
                    if (!bio.isNullOrBlank()) {
                        HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                    }
                }
                bio?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
                }
                // Only when BOTH are absent — otherwise a peer with a real status was shown
                // "Hey there! I am using Voiid.", a message they never wrote.
                if (statusText.isNullOrBlank() && bio.isNullOrBlank()) {
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
            ProfileCard(
                title = "Media",
                accessory = if (recentPhotos.isEmpty()) null else ({
                    Text(
                        "See all", style = VoiidFont.rounded(13, FontWeight.Medium),
                        color = VoiidColor.primary,
                        modifier = Modifier.clickable { haptics.tap(); showAllMedia = true },
                    )
                }),
            ) {
                if (recentPhotos.isEmpty()) {
                    // GHOST TILES, not a floating icon in a void. A centred disc and two lines
                    // in an otherwise blank card reads as a HOLE in the layout; showing the
                    // SHAPE the content will take makes the card look designed-but-empty and
                    // says at a glance what would appear here. Matches iOS `mediaEmptyState`.
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(Icons.Default.Image, Icons.Default.Videocam, Icons.Default.PhotoLibrary)
                            .forEach { ghost ->
                                Box(
                                    Modifier
                                        .size(76.dp)
                                        .dashedBorder(VoiidColor.divider, VoiidRadius.md),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        ghost, null,
                                        tint = VoiidColor.placeholder.copy(alpha = 0.5f),
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }
                    }
                    Text(
                        "Photos, videos and files you share with ${conversation.title} appear here.",
                        style = VoiidFont.rounded(12),
                        color = VoiidColor.textSecondary,
                    )
                } else {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        recentPhotos.forEach { ref ->
                            Box(Modifier.size(76.dp).clip(RoundedCornerShape(VoiidRadius.md))) { SharedMediaThumb(ref) }
                        }
                    }
                }
            }

            // Settings
            // One toggle, no trailing dividers. Two HorizontalDividers were left behind when
            // the rows between them (search-in-chat, wallpaper — both unimplemented) were
            // removed, so the card drew separators separating nothing.
            ProfileCard {
                ToggleRow(Icons.Default.NotificationsOff, "Mute notifications", muted) { muted = it; haptics.selection() }
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
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier.fillMaxHeight().softClickable(onClick = onClick),
    ) {
        Spacer(Modifier.weight(1f))
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(17.dp))
        Text(label, style = VoiidFont.rounded(11, FontWeight.Medium), color = VoiidColor.primary)
        Spacer(Modifier.weight(1f))
    }
}

/** The hairline between segments of the quick-action control. */
@Composable
private fun ActionSeparator() {
    Box(Modifier.width(1.dp).height(26.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
}

/**
 * A dashed placeholder outline, for empty-state ghost tiles.
 *
 * Compose has no dashed `border`, so this draws the stroke directly. Same 1.5dp / 5-4 dash as
 * the iOS `strokeBorder(style:)` so the two empty states are visually identical.
 */
private fun Modifier.dashedBorder(color: Color, radius: androidx.compose.ui.unit.Dp) = drawBehind {
    val stroke = androidx.compose.ui.graphics.drawscope.Stroke(
        width = 1.5.dp.toPx(),
        pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(
            floatArrayOf(5.dp.toPx(), 4.dp.toPx()), 0f,
        ),
    )
    drawRoundRect(
        color = color,
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius.toPx()),
        style = stroke,
    )
}

/**
 * A grouped surface, optionally titled.
 *
 * The TITLE SITS OUTSIDE the card, in caps at 12sp — the platform grouped-list idiom on both
 * OSes. It used to be inside at 15sp semibold, which made every card open with a line of text
 * the same weight as its content; six of those stacked gave the page no hierarchy at all.
 */
@Composable
fun ProfileCard(
    title: String? = null,
    accessory: (@Composable () -> Unit)? = null,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title != null || accessory != null) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                title?.let {
                    Text(
                        it.uppercase(),
                        // Caps need positive tracking to stay legible.
                        style = VoiidFont.rounded(12, FontWeight.SemiBold).copy(letterSpacing = 0.6.sp),
                        color = VoiidColor.textSecondary,
                    )
                }
                Spacer(Modifier.weight(1f))
                accessory?.invoke()
            }
        }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            content = content,
        )
    }
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
