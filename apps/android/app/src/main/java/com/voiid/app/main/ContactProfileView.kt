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
import androidx.compose.material.icons.filled.CallMade
import androidx.compose.material.icons.filled.CallReceived
import androidx.compose.material.icons.filled.PhoneMissed
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.ChevronRight
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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.dp
import com.voiid.app.model.DummyData
import com.voiid.app.model.ConversationType
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
import com.voiid.app.ui.theme.VoiidSpacing

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
    // The safety-number screen (anti-MITM verification), reachable from the Encryption card below.
    var showSafetyNumber by remember { mutableStateOf(false) }
    var showAllMedia by remember { mutableStateOf(false) }
    var viewPhoto by remember { mutableStateOf(false) }
    /** "block" | "report" | null — Block and Report have no backend yet (no route, no table),
     *  so they confirm and then say so plainly. A safety button that appears to succeed and
     *  silently does nothing is worse than one that admits it is not built. */
    var confirm by remember { mutableStateOf<String?>(null) }
    var notImplemented by remember { mutableStateOf<String?>(null) }
    var photoUrl by remember { mutableStateOf<String?>(null) }
    // The four most recent calls with this contact, newest first — same source the transcript's
    // call bubbles use, asked a different question. Four because the card is a summary, not a log.
    var recentCalls by remember {
        mutableStateOf<List<com.voiid.app.store.CallHistoryRow>>(emptyList())
    }
    LaunchedEffect(conversation.id) {
        recentCalls = com.voiid.app.store.LocalStore
            .callsForConversation(context, conversation.id)
            .sortedByDescending { it.startedAt }
            .take(4)
    }

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

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
        // A TINTED GROUND, not flat. The cards are translucent — over a single flat colour
        // there is nothing to show through and they render as grey slabs, wasting the effect.
        // A soft wash of the brand colour under the top of the scroll gives them something to
        // sit on. Mirrors iOS.
        Box(
            Modifier
                .fillMaxWidth()
                .height(520.dp)
                .background(
                    // 0.08, not 0.16. That value was tuned for iOS, where a real backdrop
                    // BLUR softens the tint before it reaches the eye. Android has no blur
                    // here, so the same alpha rendered as a flat purple wash behind the
                    // cards. Halved, it does what it is for — giving the translucent edges
                    // something to pick up — without colouring the page.
                    Brush.verticalGradient(
                        listOf(VoiidColor.primary.copy(alpha = 0.08f), Color.Transparent),
                    ),
                ),
        )
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
        ) {
            // Header: a full-bleed portrait with the identity laid over it.
            //
            // WHY NOT A CENTERED AVATAR ON A CARD. That layout — round photo, name under it,
            // buttons under that, all centered on a plain ground — is the 2016 profile, and
            // it wastes the one asset the screen actually has: the person's photo, shown at
            // 104dp while two thirds of the width sits empty. Apple stopped building profiles
            // that way years ago. Mirrors iOS `headerCard`.
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(360.dp)
                    .clickable { haptics.tap(); viewPhoto = true },
            ) {
                val resolvedPhoto = photoUrl
                    ?: UserDirectory.photoUrl(conversation.peerUserId ?: "")
                    ?: conversation.photoURL
                if (!resolvedPhoto.isNullOrEmpty()) {
                    // fillsFrame: the banner is a RECTANGLE. Without it the shared avatar
                    // clipped the photo to a circle in the corner of the 360dp frame.
                    ProfileAvatar(
                        photoUrl = resolvedPhoto,
                        name = conversation.title,
                        size = 360.dp,
                        modifier = Modifier.fillMaxSize(),
                        fillsFrame = true,
                    )
                } else {
                    // NO PHOTO IS A COMMON CASE, not an edge case, so it gets a real design
                    // rather than a grey box: the brand gradient with the person's initial.
                    // Same 360dp shape, so the layout never jumps when a photo loads.
                    Box(
                        Modifier.fillMaxSize().background(
                            Brush.linearGradient(
                                listOf(
                                    VoiidColor.primary.copy(alpha = 0.85f),
                                    VoiidColor.primary.copy(alpha = 0.45f),
                                ),
                            ),
                        ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            conversation.title.trim().take(1).uppercase().ifEmpty { "?" },
                            style = VoiidFont.rounded(96, FontWeight.SemiBold),
                            color = Color.White.copy(alpha = 0.9f),
                        )
                    }
                }

                // A bottom-anchored gradient, not a flat overlay. Flat dimming greys out the
                // whole photo to protect two lines of text; a gradient leaves the face
                // untouched and only darkens where the words actually are.
                Box(
                    Modifier.fillMaxSize().background(
                        Brush.verticalGradient(
                            0.5f to Color.Transparent,
                            0.78f to Color.Black.copy(alpha = 0.15f),
                            1f to Color.Black.copy(alpha = 0.72f),
                        ),
                    ),
                )

                Column(
                    Modifier.align(Alignment.BottomStart).padding(horizontal = 20.dp, vertical = 18.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        conversation.title,
                        // Optical tightening — default spacing reads loose above ~28sp.
                        style = VoiidFont.rounded(32, FontWeight.Bold).copy(letterSpacing = (-0.6).sp),
                        // Fixed white, NOT a theme token: this text sits on a photo, so it
                        // must not follow the light/dark ground it is no longer standing on.
                        color = Color.White,
                        maxLines = 2,
                    )

                    // ONE line of secondary identity. The real name, handle and number were
                    // each on their own line in near-identical styles, so none of them read
                    // as THE way to identify this person. The handle leads (it is what you
                    // share); the number follows, quieter, after a dot.
                    val secondary = savedNumber ?: fullName?.takeIf { it != conversation.title }
                    val handle = username?.let { "@$it" }
                    if (handle != null || secondary != null) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            handle?.let {
                                Text(it, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.White)
                            }
                            if (handle != null && secondary != null) {
                                Box(Modifier.size(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.55f)))
                            }
                            secondary?.let {
                                // A desaturated white reads as "quieter"; grey on a photo
                                // reads as "disabled".
                                Text(it, style = VoiidFont.rounded(15), color = Color.White.copy(alpha = 0.85f))
                            }
                        }
                    }
                }
            }

            Column(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 20.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                // Message / Call / Video, as three equal capsules — NOT one segmented block.
                // A segmented control reads as "pick a mode"; these are three separate things
                // you can do. Message leads on brand fill because it is what this screen is
                // overwhelmingly opened to do.
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    QuickAction(Icons.AutoMirrored.Filled.Message, "Message", filled = true, modifier = Modifier.weight(1f)) { haptics.tap(); onBack() }
                    QuickAction(Icons.Default.Call, "Call", filled = false, modifier = Modifier.weight(1f)) { haptics.tap(); onStartCall(CallKind.VOICE); onBack() }
                    QuickAction(Icons.Default.Videocam, "Video", filled = false, modifier = Modifier.weight(1f)) { haptics.tap(); onStartCall(CallKind.VIDEO); onBack() }
                }

            // About AND status — two distinct fields. This screen only ever read `bio`, so a
            // contact who set a status showed nothing at all here.
            ProfileCard("About") {
                // DE-DUPLICATE. `status_text` and `bio` are separate server fields, but the
                // profile editor writes the same string to both — so a user who set "Testing
                // 2" saw it rendered TWICE with a divider between, which is what the stray
                // bar under the text was. Identical values collapse to one line.
                val statusShown = statusText?.takeIf { it.isNotBlank() }
                val bioShown = bio?.takeIf { it.isNotBlank() && it != statusShown }
                statusShown?.let { st ->
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Default.FormatQuote, null, tint = VoiidColor.primary,
                            modifier = Modifier.size(15.dp).padding(top = 2.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(st, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary)
                    }
                    if (bioShown != null) {
                        HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                    }
                }
                bioShown?.let {
                    Text(it, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
                }
                // Only when BOTH are absent — otherwise a peer with a real status was shown
                // "Hey there! I am using Voiid.", a message they never wrote.
                if (statusShown == null && bioShown == null) {
                    Text("Hey there! I am using Voiid.", style = VoiidFont.rounded(16), color = VoiidColor.textSecondary)
                }
            }

            // Shared media — REAL recent photos from the message store (never DummyData).
            // Videos count too — this filtered to `image/` only, so a chat full of videos
            // reported "no media shared yet".
            // Loaded OFF the composition thread. `remember` already stopped this recomputing
            // on every recomposition, but the FIRST pass still decoded the entire message
            // store inline — which on a chat with real history stalls the frame that opens
            // the screen. Mirrors the iOS fix.
            var sharedMedia by remember(conversation.id) {
                mutableStateOf<List<com.voiid.app.net.ChatEngine.MediaRef>>(emptyList())
            }
            LaunchedEffect(conversation.id) {
                sharedMedia = withContext(Dispatchers.IO) {
                    com.voiid.app.net.ChatEngine.get(context).messages(conversation.id)
                        .mapNotNull { it.media }
                        .filter { it.mime.startsWith("image/") || it.mime.startsWith("video/") }
                        .reversed()
                }
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

            // Calls
            //
            // The transcript already shows call bubbles, but a profile is where you go to answer
            // "how often do we actually talk?" — and scrolling a whole chat to reconstruct that is
            // not an answer. Same data, different question.
            //
            // HIDDEN ENTIRELY when there are none: an empty "Calls" card on a contact you have only
            // ever texted is an affordance to nothing. Mirrors iOS `callHistoryCard`.
            if (recentCalls.isNotEmpty()) {
                ProfileCard(title = "Calls") {
                    recentCalls.forEachIndexed { index, entry ->
                        if (index > 0) {
                            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                        }
                        CallHistoryRowView(entry)
                    }
                }
            }

            // Encryption
            //
            // A claim of end-to-end encryption the user cannot verify is a claim they have to take
            // on faith. This row turns it into something checkable — and it sits ABOVE mute and
            // block because it is the more consequential fact about the conversation.
            //
            // 1:1 only: a safety number compares two identity keys, and a group has no single pair.
            if (conversation.type != ConversationType.GROUP) {
                ProfileCard(title = "Encryption") {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { haptics.tap(); showSafetyNumber = true }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                    ) {
                        Icon(
                            Icons.Default.Lock,
                            contentDescription = null,
                            tint = VoiidColor.success,
                            modifier = Modifier.size(24.dp),
                        )
                        Column(Modifier.weight(1f)) {
                            Text(
                                "End-to-end encrypted",
                                color = VoiidColor.textPrimary,
                                fontSize = 16.sp,
                            )
                            Text(
                                "Tap to verify with a safety number",
                                color = VoiidColor.textSecondary,
                                fontSize = 12.sp,
                            )
                        }
                        Icon(
                            Icons.Default.ChevronRight,
                            contentDescription = null,
                            tint = VoiidColor.placeholder,
                            modifier = Modifier.size(16.dp),
                        )
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
    }

    // BACK FLOATS OVER THE PORTRAIT. The old header carried VoiidCircleBack above the
    // avatar; with the photo now running full-bleed under the status bar there is no bar to
    // put it in, so it sits on the image — on a dark scrim disc, because a tinted chevron on
    // an arbitrary photo is the one control that must always be findable and would have been
    // the hardest thing to see.
    Box(
        Modifier
            .statusBarsPadding()
            .padding(start = 8.dp, top = 4.dp)
            .size(38.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.32f))
            .clickable { haptics.tap(); onBack() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Default.ChevronLeft, "Back",
            tint = Color.White,
            modifier = Modifier.size(24.dp),
        )
    }

    if (showAllMedia) {
        SharedMediaSheet(conversationId = conversation.id, onDismiss = { showAllMedia = false })
    }
    if (viewPhoto) {
        ProfilePhotoViewer(title = conversation.title, onClose = { viewPhoto = false })
    }
    // Safety number, opened from the Encryption card. Full-screen: the digits are read aloud in
    // 5-groups and need the whole width.
    if (showSafetyNumber) {
        SafetyNumberScreen(
            peerUserId = conversation.peerUserId.orEmpty(),
            peerName = fullName ?: conversation.title,
            onClose = { showSafetyNumber = false },
        )
    }
}

@Composable
private fun QuickAction(
    icon: ImageVector,
    label: String,
    filled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = modifier
            .height(62.dp)
            .clip(RoundedCornerShape(18.dp))
            // The PRIMARY action stays solid — a translucent fill on the one button you are
            // most likely to press would make it recede exactly where it should lead.
            .background(if (filled) VoiidColor.primary else VoiidColor.primary.copy(alpha = 0.10f))
            .softClickable(onClick = onClick),
    ) {
        Icon(
            icon, null,
            tint = if (filled) VoiidColor.textOnPrimary else VoiidColor.primary,
            modifier = Modifier.size(17.dp),
        )
        Spacer(Modifier.height(5.dp))
        Text(
            label,
            style = VoiidFont.rounded(12, FontWeight.Medium),
            color = if (filled) VoiidColor.textOnPrimary else VoiidColor.primary,
        )
    }
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
            Modifier.fillMaxWidth().glassCard().padding(16.dp),
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

/**
 * One call in the profile's Calls card.
 *
 * SAME ARROW LANGUAGE as the transcript's call bubble, so the two surfaces teach one vocabulary
 * rather than each inventing its own: down-left for incoming, up-right for outgoing, and a distinct
 * missed-call glyph in the error colour when an incoming call went unanswered.
 *
 * Mirrors iOS `callRow` / `callTitle`.
 */
@Composable
private fun CallHistoryRowView(entry: com.voiid.app.store.CallHistoryRow) {
    val incoming = entry.direction == "incoming"
    val missed = incoming && entry.outcome != "answered"

    Row(
        Modifier.fillMaxWidth().padding(vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Icon(
            when {
                missed -> Icons.Default.PhoneMissed
                incoming -> Icons.Default.CallReceived
                else -> Icons.Default.CallMade
            },
            contentDescription = null,
            tint = if (missed) VoiidColor.error else VoiidColor.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(
                callTitleFor(entry),
                style = VoiidFont.rounded(15),
                color = if (missed) VoiidColor.error else VoiidColor.textPrimary,
            )
            Text(
                // call_history stores SECONDS; the formatter wants millis.
                android.text.format.DateFormat.format("d MMM yyyy", entry.startedAt * 1000L).toString(),
                style = VoiidFont.rounded(11),
                color = VoiidColor.textSecondary,
            )
        }
        Icon(
            if (entry.kind == "video") Icons.Default.Videocam else Icons.Default.Call,
            contentDescription = null,
            tint = VoiidColor.placeholder,
            modifier = Modifier.size(14.dp),
        )
    }
}

/**
 * "Incoming · 2:14" / "Missed" / "Call declined".
 *
 * The DURATION is what makes an answered call informative — "Incoming" alone says nothing about
 * whether you spoke for ten seconds or an hour. Hours are only shown when there are hours, so the
 * common case stays short.
 */
private fun callTitleFor(entry: com.voiid.app.store.CallHistoryRow): String {
    val incoming = entry.direction == "incoming"
    return when (entry.outcome) {
        "answered" -> {
            val ended = entry.endedAt ?: return if (incoming) "Incoming" else "Outgoing"
            val secs = (ended - entry.startedAt).coerceAtLeast(0)
            val mins = secs / 60
            val duration = if (mins >= 60) {
                String.format("%d:%02d:%02d", mins / 60, mins % 60, secs % 60)
            } else {
                String.format("%d:%02d", mins, secs % 60)
            }
            (if (incoming) "Incoming · " else "Outgoing · ") + duration
        }
        "declined" -> if (incoming) "Declined" else "Call declined"
        "failed" -> "Call failed"
        else -> if (incoming) "Missed" else "No answer"
    }
}

/**
 * A translucent card, matching iOS `glassCard`.
 *
 * COMPOSE HAS NO `.regularMaterial`. iOS gets a real backdrop blur from the system; Android
 * has no equivalent that works inside a scrolling column without a RenderEffect pass that
 * costs more than it is worth on mid-tier hardware. So this approximates it the way the rest
 * of the OS does: a semi-transparent surface over the tinted ground, which reads as
 * translucent because the gradient behind it genuinely shows through.
 *
 * THE HAIRLINE IS WHAT MAKES IT READ AS GLASS. Without a lit top edge a translucent rectangle
 * just looks like a washed-out fill; the white-to-transparent stroke is the specular highlight
 * that says "this has a surface". The shadow is deliberately soft — enough to lift the card
 * off the ground, not enough to look like a dropped box.
 */
@Composable
private fun Modifier.glassCard(cornerRadius: androidx.compose.ui.unit.Dp = 20.dp): Modifier {
    val shape = RoundedCornerShape(cornerRadius)
    return this
        // 4dp, not 10. Android's elevation shadow is far heavier than the iOS equivalent at
        // the same nominal value — 10dp drew a dark halo around every card and made the page
        // read as a stack of floating boxes rather than one surface.
        .shadow(
            elevation = 4.dp,
            shape = shape,
            ambientColor = Color.Black.copy(alpha = 0.06f),
            spotColor = Color.Black.copy(alpha = 0.10f),
        )
        .clip(shape)
        // 0.94, not 0.82. At 0.82 the brand-tinted ground bled through hard enough to tint
        // the card body itself, so text sat on a faintly purple slab and the card looked
        // dirty rather than translucent. Glass should be felt at the EDGES, not read as a
        // colour cast across the content.
        .background(VoiidColor.surfaceCard.copy(alpha = 0.94f))
        // The hairline is what says "this has a surface" — but it must be a LIGHT-ON-EDGE
        // highlight, not a white outline. White at 0.28 on a near-white card in light mode is
        // a hard visible line; keyed off the divider token it reads as a lit edge in both
        // themes and disappears where it should.
        .border(
            1.dp,
            Brush.verticalGradient(
                listOf(
                    VoiidColor.divider.copy(alpha = 0.55f),
                    VoiidColor.divider.copy(alpha = 0.12f),
                ),
            ),
            shape,
        )
}
