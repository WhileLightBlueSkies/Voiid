package com.voiid.app.main

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Notifications
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.material.icons.filled.Security
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PhoneMissed
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.model.ConversationType
import com.voiid.app.model.DummyData
import com.voiid.app.model.VConversation
import com.voiid.app.net.BlockService
import com.voiid.app.net.ContactDirectory
import com.voiid.app.net.ProfileService
import com.voiid.app.net.ReportTarget
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.ProfilePhotoViewer
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    /**
     * Clear this conversation. A CALLBACK rather than a ChatStore reference, for the same
     * reason [onStartCall] is one: the chat already owns the store and the dismissal that has
     * to follow, and duplicating either here would let the two paths drift.
     */
    onClearChat: () -> Unit = {},
    /** "Online" / "Last seen …" from the chat's live source, or null when unknown or hidden
     *  by the privacy switch. Passed in so the profile and the chat header can never disagree. */
    presence: Pair<String, Boolean>? = null,
) {
    BackHandler { onBack() }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // Blocking (043). Collected so the row flips between Block and Unblock the moment the
    // mutation lands, without this screen keeping its own copy of the state.
    //
    // Answers only whether WE blocked THEM. There is deliberately no route for the reverse
    // — a blocked person being able to detect the block defeats blocking silently.
    val blockedUsers by BlockService.blocked.collectAsState()
    val isBlocked = conversation.peerUserId?.let { peer -> blockedUsers.any { it.id == peer } } == true
    val haptics = LocalVoiidHaptics.current
    var muted by remember { mutableStateOf(false) }
    // The safety-number screen (anti-MITM verification), reachable from the Encryption card below.
    var showSafetyNumber by remember { mutableStateOf(false) }
    var showAllMedia by remember { mutableStateOf(false) }
    var viewPhoto by remember { mutableStateOf(false) }
    /** "clear" | "block" | "report" | null.
     *
     *  Block is LIVE now (043_user_blocks + /blocks, enforced server-side across messages,
     *  calls, profile, presence, conversation creation, group invites, stories and typing).
     *  Report is live too: the confirmation establishes intent and ReportSheet collects
     *  the reason. That sheet was written, correct, and reachable from nowhere. */
    var confirm by remember { mutableStateOf<String?>(null) }
    var notImplemented by remember { mutableStateOf<String?>(null) }
    /** Set when a block/unblock fails, so the row's state and the message stay honest. */
    var blockFailure by remember { mutableStateOf<String?>(null) }
    /** Report flow: the confirmation establishes intent, the sheet collects the reason. */
    var showReportSheet by remember { mutableStateOf(false) }
    var photoUrl by remember { mutableStateOf<String?>(null) }
    // Every call with this contact, newest first — same source the transcript's call bubbles
    // use, asked a different question. The card shows three; See all shows the rest.
    var showAllCalls by remember { mutableStateOf(false) }
    var recentCalls by remember {
        mutableStateOf<List<com.voiid.app.store.CallHistoryRow>>(emptyList())
    }
    LaunchedEffect(conversation.id) {
        recentCalls = com.voiid.app.store.LocalStore
            .callsForConversation(context, conversation.id)
            .sortedByDescending { it.startedAt }
            .take(40)
    }

    // Real profile: full name + @username from the backend; the phone number from
    // the on-device contact match (the API never returns a phone — privacy).
    var fullName by remember { mutableStateOf<String?>(null) }
    var username by remember { mutableStateOf<String?>(null) }
    var bio by remember { mutableStateOf<String?>(null) }
    /** The one-line status — a field DISTINCT from `bio` that the server has always returned
     *  and this screen never read, which is why a contact's status never appeared. */
    var statusText by remember { mutableStateOf<String?>(null) }
    /**
     * Whether the profile fetch is still in flight.
     *
     * iOS has had a three-state model here (loading / loaded / failed) with a skeleton;
     * Android had NOTHING, so while the request was in flight it rendered the empty-state
     * fallback — "Hey there! I am using Voiid." — words this person never wrote, which were
     * then replaced by their real status a moment later. A placeholder that lies and then
     * corrects itself is worse than one that admits it is still loading.
     */
    var profileLoading by remember(conversation.peerUserId) { mutableStateOf(true) }
    val savedNumber = remember(conversation.peerUserId) {
        conversation.peerUserId?.let { ContactDirectory.get(context, it).number }
    }
    LaunchedEffect(conversation.peerUserId) {
        val peer = conversation.peerUserId
        if (peer == null) { profileLoading = false; return@LaunchedEffect }
        runCatching { ProfileService(context).fetchUser(peer) }.getOrNull()?.let { u ->
            fullName = u.full_name?.takeIf { it.isNotBlank() }
            username = u.username?.takeIf { it.isNotBlank() }
            bio = u.bio?.takeIf { it.isNotBlank() }
            photoUrl = u.photo_url?.takeIf { it.isNotBlank() }
            statusText = u.status_text?.takeIf { it.isNotBlank() }
        }
        profileLoading = false
    }

    confirm?.let { which ->
        // THREE cases now, not a boolean. `clear` is the one that actually does something —
        // block and report still have no backend, and say so rather than appearing to work.
        val title = when (which) {
            "clear" -> "Clear this chat?"
            "block" -> if (isBlocked) "Unblock ${conversation.title}?"
                       else "Block ${conversation.title}?"
            else -> "Report ${conversation.title}?"
        }
        // The block copy states that blocking is SYMMETRIC. The old line — "They won't be
        // able to message or call you" — described a one-way mute, which is not what the
        // server does; a user who believed it would read their own failed sends as a bug.
        val body = when (which) {
            "clear" -> "Every message in this conversation is deleted from this device. " +
                "This cannot be undone."
            "block" -> if (isBlocked)
                "You’ll both be able to message and call each other again."
            else
                "Neither of you will be able to message or call the other. They won’t be " +
                "told. Your messages and any groups you share stay where they are."
            else -> "The last few messages from this chat are sent to Voiid for review."
        }
        val action = when (which) {
            "clear" -> "Clear chat"
            "block" -> if (isBlocked) "Unblock" else "Block"
            else -> "Report"
        }
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { confirm = null },
            title = title,
            body = body,
            confirmLabel = action,
            onConfirm = {
                val chosen = which
                confirm = null
                when (chosen) {
                    // The only one wired to anything. Clearing dismisses the profile too:
                    // the chat behind it is now empty, and staying here would leave the
                    // user two screens deep in a conversation that no longer has content.
                    "clear" -> { onClearChat(); onBack() }
                    // Block / unblock, whichever the current state calls for. The
                    // service rolls its own optimistic change back on failure, so the
                    // row returns to its previous label by itself; this only has to
                    // say what happened. A silent failure is the dangerous case —
                    // someone believing they are protected when they are not.
                    "block" -> {
                        val peer = conversation.peerUserId
                        if (peer == null) {
                            blockFailure = "This conversation has no contact to block."
                        } else {
                            val wasBlocked = isBlocked
                            scope.launch {
                                val ok = if (wasBlocked) {
                                    BlockService.unblock(context, peer)
                                } else {
                                    BlockService.block(
                                        context, peer,
                                        displayName = conversation.title,
                                        username = username,
                                        photoUrl = photoUrl,
                                    )
                                }
                                if (!ok) {
                                    blockFailure = if (wasBlocked)
                                        "Check your connection and try again. " +
                                        "${conversation.title} is still blocked."
                                    else
                                        "Check your connection and try again. " +
                                        "${conversation.title} has not been blocked."
                                }
                            }
                        }
                    }
                    // Report opens the SHEET rather than submitting here. The
                    // confirmation only establishes intent; the reason and the
                    // reporter's own words are chosen in ReportSheet, which has
                    // existed and been reachable from nowhere until now.
                    else -> showReportSheet = true
                }
            },
            confirmDestructive = true,
        )
    }
    notImplemented?.let { msg ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { notImplemented = null },
            title = "Not available yet",
            body = msg,
            confirmLabel = "OK",
            onConfirm = { notImplemented = null },
            cancelLabel = null,
        )
    }

    // Report. Hosted here rather than inside the danger card so it survives the card
    // scrolling out of view, and dismissed by the sheet's own onDone.
    if (showReportSheet) {
        val peer = conversation.peerUserId
        if (peer == null) {
            // A group has no single person to report. Nothing here can be a valid target,
            // so say so rather than opening a sheet that cannot submit.
            showReportSheet = false
            notImplemented = "There's no individual contact to report in a group."
        } else {
            androidx.compose.ui.window.Dialog(
                onDismissRequest = { showReportSheet = false },
                properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                    ReportSheet(
                        target = ReportTarget.Person(peer),
                        onDone = { showReportSheet = false },
                    )
                }
            }
        }
    }

    blockFailure?.let { msg ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { blockFailure = null },
            title = if (isBlocked) "Couldn’t unblock" else "Couldn’t block",
            body = msg,
            confirmLabel = "OK",
            onConfirm = { blockFailure = null },
            cancelLabel = null,
        )
    }

    // Shared media — real, from the message store, loaded off the composition thread.
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
    val firstName = conversation.title.split(" ").firstOrNull().orEmpty().ifBlank { conversation.title }
    var showMore by remember { mutableStateOf(false) }

    // THE VOIID UI REFERENCE (ContactScreen), section for section and in its order: identity,
    // four tiles, contact details, encryption, about, media, block/report, footer — on a flat
    // ground, with two floating circles for chrome. Mirrors iOS ContactProfileView.
    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(horizontal = VoiidSpacing.md)
                .padding(bottom = VoiidSpacing.xl),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // ── Identity ──
            val resolvedPhoto = photoUrl
                ?: UserDirectory.photoUrl(conversation.peerUserId ?: "")
                ?: conversation.photoURL
            Column(
                // Clears the floating header, as in the reference.
                Modifier.fillMaxWidth().padding(top = 52.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                ProfileAvatar(
                    photoUrl = resolvedPhoto, name = conversation.title, size = 88.dp,
                    modifier = Modifier.clip(CircleShape)
                        .border(2.dp, VoiidColor.accent.copy(alpha = 0.6f), CircleShape)
                        .softClickable { if (!resolvedPhoto.isNullOrBlank()) viewPhoto = true },
                )
                Text(conversation.title, style = VoiidFont.rounded(22, FontWeight.Bold),
                    color = VoiidColor.textPrimary, maxLines = 1,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                // Same live source and privacy switch as the chat header; left out when unknown.
                presence?.let { (text, online) ->
                    Text(text, style = VoiidFont.rounded(14),
                        color = if (online) VoiidColor.success else VoiidColor.textSecondary)
                }
                Row(
                    Modifier.clip(RoundedCornerShape(999.dp))
                        .background(VoiidColor.accent.copy(alpha = 0.10f))
                        .border(1.dp, VoiidColor.accent.copy(alpha = 0.45f), RoundedCornerShape(999.dp))
                        .padding(horizontal = 14.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.Default.Lock, null, tint = VoiidColor.accentInk, modifier = Modifier.size(12.dp))
                    Text("End-to-end Encrypted", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.accentInk)
                }
            }

            // ── Four equal tiles; mute is the fourth ──
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ContactTile(Icons.AutoMirrored.Filled.Message, "Message", modifier = Modifier.weight(1f)) { onBack() }
                ContactTile(Icons.Default.Call, "Voice call", modifier = Modifier.weight(1f)) { onStartCall(CallKind.VOICE); onBack() }
                ContactTile(Icons.Default.Videocam, "Video call", modifier = Modifier.weight(1f)) { onStartCall(CallKind.VIDEO); onBack() }
                MuteTile(conversation.id, modifier = Modifier.weight(1f))
            }

            // ── Contact details: title inside, rows edge to edge, inset rule between ──
            // The number is the one from YOUR address book; the server never discloses it.
            if (!savedNumber.isNullOrBlank() || !username.isNullOrBlank()) {
                Column(Modifier.fillMaxWidth().glassCard().padding(bottom = VoiidSpacing.sm)) {
                    Text("Contact details", style = VoiidFont.rounded(16, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                        modifier = Modifier.padding(start = VoiidSpacing.md, end = VoiidSpacing.md,
                            top = VoiidSpacing.md, bottom = VoiidSpacing.sm))
                    savedNumber?.takeIf { it.isNotBlank() }?.let { phone ->
                        ContactDetailRow(Icons.Default.Phone, "Phone number", phone)
                        if (!username.isNullOrBlank()) {
                            HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 60.dp))
                        }
                    }
                    username?.takeIf { it.isNotBlank() }?.let { handle ->
                        ContactDetailRow(Icons.Default.AlternateEmail, "Username", "@$handle")
                    }
                }
            }

            // ── Encryption: opens the safety number, so the claim can be checked ──
            if (conversation.type != ConversationType.GROUP) {
                Row(
                    Modifier.fillMaxWidth().glassCard().softClickable { showSafetyNumber = true }
                        .padding(start = VoiidSpacing.md, end = VoiidSpacing.md, top = VoiidSpacing.sm, bottom = VoiidSpacing.sm),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                ) {
                    Box(
                        Modifier.size(44.dp).clip(CircleShape)
                            .background(VoiidColor.accent.copy(alpha = 0.10f))
                            .border(1.dp, VoiidColor.accent.copy(alpha = 0.5f), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Default.Security, null, tint = VoiidColor.accentInk, modifier = Modifier.size(20.dp))
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("End-to-end Encrypted", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = VoiidColor.accentInk)
                        Text(
                            "Messages, calls and media are secured with end-to-end encryption. " +
                                "Only you and $firstName can read or listen to them.",
                            style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary,
                        )
                    }
                    Icon(Icons.Default.ChevronRight, null,
                        tint = VoiidColor.textSecondary.copy(alpha = 0.7f), modifier = Modifier.size(18.dp))
                }
            }

            // ── About: title and the words; absent when the person wrote nothing ──
            val statusShown = statusText?.takeIf { it.isNotBlank() }
            val bioShown = bio?.takeIf { it.isNotBlank() && it != statusShown }
            if (profileLoading || statusShown != null || bioShown != null) {
                Column(
                    Modifier.fillMaxWidth().glassCard().padding(VoiidSpacing.md),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text("About", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    if (profileLoading && statusShown == null && bioShown == null) {
                        ProfileAboutSkeleton()
                    }
                    statusShown?.let { Text(it, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) }
                    bioShown?.let { Text(it, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) }
                }
            }

            // ── Media: header is the way in, then equal squares ending in "+N" ──
            if (sharedMedia.isNotEmpty()) {
                Column(
                    Modifier.fillMaxWidth().glassCard().padding(VoiidSpacing.md),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    Row(Modifier.fillMaxWidth().softClickable { showAllMedia = true },
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("Media", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                        Spacer(Modifier.weight(1f))
                        Text("${sharedMedia.size}", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                        Icon(Icons.Default.ChevronRight, null,
                            tint = VoiidColor.textSecondary.copy(alpha = 0.7f), modifier = Modifier.size(18.dp))
                    }
                    val overflow = sharedMedia.size - 4
                    val shown = sharedMedia.take(if (overflow > 1) 4 else 5)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        shown.forEach { ref ->
                            Box(Modifier.weight(1f).aspectRatio(1f).clip(RoundedCornerShape(12.dp))) { SharedMediaThumb(ref) }
                        }
                        if (overflow > 1) {
                            Box(
                                Modifier.weight(1f).aspectRatio(1f).clip(RoundedCornerShape(12.dp))
                                    .background(VoiidColor.fieldFill)
                                    .softClickable { showAllMedia = true }
                                    .semantics { contentDescription = "See all ${sharedMedia.size} items" },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text("+$overflow", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                                    color = VoiidColor.textPrimary, maxLines = 1)
                            }
                        } else {
                            repeat(5 - shown.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }

            // ── Calls: below Media, as on iOS. Hidden when you have only ever texted. ──
            // The Voiid Ui design: a header saying how you talk, the three latest calls, Call back
            // on a missed one, See all for the rest. Mirrors iOS ContactProfileView.
            if (recentCalls.isNotEmpty()) {
                Column(Modifier.fillMaxWidth().glassCard().padding(bottom = VoiidSpacing.xs)) {
                    Row(
                        Modifier.fillMaxWidth().padding(start = VoiidSpacing.md, end = VoiidSpacing.md,
                            top = VoiidSpacing.md, bottom = VoiidSpacing.sm),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("Calls", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                            Text(callSummary(recentCalls), style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
                        }
                        if (recentCalls.size > 3) {
                            Row(
                                Modifier.softClickable { showAllCalls = true }.padding(4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("See all", style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.accentInk)
                                Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.accentInk, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    recentCalls.take(3).forEachIndexed { index, entry ->
                        if (index > 0) HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 64.dp))
                        CallHistoryRowView(entry) { kind -> onStartCall(kind); onBack() }
                    }
                }
            }

            // ── Block / Report: two rows edge to edge. Clear chat lives in the More menu. ──
            Column(Modifier.fillMaxWidth().glassCard()) {
                DangerRow(
                    if (isBlocked) Icons.Default.Block else Icons.Default.Block,
                    if (isBlocked) "Unblock $firstName" else "Block $firstName",
                    if (isBlocked) VoiidColor.accentInk else VoiidColor.error,
                ) { haptics.rigid(); confirm = "block" }
                HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 56.dp))
                DangerRow(Icons.Default.Report, "Report $firstName", VoiidColor.error) { haptics.rigid(); confirm = "report" }
            }

            // ── Footer. The reference claims both phones run the latest version, which this
            // app cannot know about the other phone, so it states what IS true. ──
            Row(
                Modifier.fillMaxWidth().padding(top = VoiidSpacing.sm),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                Box(Modifier.size(34.dp).clip(CircleShape).background(VoiidColor.surfaceCard),
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(13.dp))
                }
                Text("Messages and calls with $firstName are end-to-end encrypted.\nYour conversations are protected.",
                    style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
            }
        }

        // ── Floating chrome: Back and More ──
        Row(
            Modifier.fillMaxWidth().statusBarsPadding()
                .padding(horizontal = VoiidSpacing.md).padding(top = VoiidSpacing.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircleChrome(Icons.Default.ChevronLeft, "Back") { onBack() }
            Spacer(Modifier.weight(1f))
            Box {
                CircleChrome(Icons.Default.MoreHoriz, "More") { showMore = true }
                androidx.compose.material3.DropdownMenu(expanded = showMore, onDismissRequest = { showMore = false }) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("Verify safety number") },
                        leadingIcon = { Icon(Icons.Default.Security, null) },
                        onClick = { showMore = false; showSafetyNumber = true },
                    )
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("Clear chat", color = VoiidColor.error) },
                        leadingIcon = { Icon(Icons.Default.Delete, null, tint = VoiidColor.error) },
                        onClick = { showMore = false; confirm = "clear" },
                    )
                }
            }
        }
    }

    if (showAllCalls) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showAllCalls = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp).clip(RoundedCornerShape(20.dp))
                    .background(VoiidColor.background).padding(vertical = 12.dp),
            ) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Calls with ${conversation.title.split(" ").firstOrNull().orEmpty()}",
                        style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                        modifier = Modifier.weight(1f))
                    Text("Done", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.accentInk,
                        modifier = Modifier.softClickable { showAllCalls = false }.padding(8.dp))
                }
                Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState())) {
                    recentCalls.forEachIndexed { index, entry ->
                        if (index > 0) HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 64.dp))
                        CallHistoryRowView(entry) { kind -> showAllCalls = false; onStartCall(kind); onBack() }
                    }
                }
            }
        }
    }
    if (showAllMedia) {
        SharedMediaSheet(conversationId = conversation.id, onDismiss = { showAllMedia = false })
    }
    if (viewPhoto) {
        val viewerPhoto = photoUrl
            ?: UserDirectory.photoUrl(conversation.peerUserId ?: "")
            ?: conversation.photoURL
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { viewPhoto = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth().padding(24.dp)) {
                val diameter = minOf(maxWidth, 320.dp)
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    ProfileAvatar(photoUrl = viewerPhoto, name = conversation.title, size = diameter)
                    Text(conversation.title, style = VoiidFont.rounded(20, FontWeight.SemiBold),
                        color = Color.White, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    androidx.compose.material3.TextButton(onClick = { viewPhoto = false },
                        modifier = Modifier.height(48.dp)) {
                        Text("Close", color = Color.White, style = VoiidFont.rounded(16, FontWeight.Medium))
                    }
                }
            }
        }
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
private fun CircleChrome(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(38.dp).clip(CircleShape).background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, CircleShape)
            .softClickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun DangerRow(icon: ImageVector, title: String, tint: Color, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().softClickable(onClick = onClick)
            .padding(horizontal = VoiidSpacing.md, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        Text(title, style = VoiidFont.rounded(15, FontWeight.Medium), color = tint, maxLines = 1)
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
 * THE TITLE SITS INSIDE THE CARD, as in the Voiid Ui reference and on iOS: "Contact details",
 * "About", "Calls" each head their own surface, so a section reads as one object rather than
 * a caption floating over a box.
 */
@Composable
fun ProfileCard(
    title: String? = null,
    accessory: (@Composable () -> Unit)? = null,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().glassCard().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (title != null || accessory != null) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                title?.let {
                    Text(it, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                }
                Spacer(Modifier.weight(1f))
                accessory?.invoke()
            }
        }
        content()
    }
}

/**
 * One of the four contact tiles. One appearance for the three buttons and the mute tile, so
 * they cannot drift apart. Mirrors iOS `ContactProfileView.tileLabel`.
 */
@Composable
private fun ContactTileBody(icon: ImageVector, label: String, active: Boolean, modifier: Modifier) {
    val shape = RoundedCornerShape(VoiidRadius.lg)
    Column(
        modifier
            .clip(shape)
            .background(if (active) VoiidColor.accent else VoiidColor.surfaceCard)
            .border(1.dp, if (active) VoiidColor.accent else VoiidColor.divider, shape)
            .padding(vertical = 11.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Icon(icon, null, tint = if (active) VoiidColor.textOnAccent else VoiidColor.accentInk,
            modifier = Modifier.size(19.dp))
        Text(label, style = VoiidFont.rounded(11.5f, FontWeight.Medium),
            color = if (active) VoiidColor.textOnAccent else VoiidColor.textPrimary, maxLines = 1)
    }
}

@Composable
private fun ContactTile(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    ContactTileBody(icon, label, active = false,
        modifier = modifier.softClickable(onClick = onClick).semantics { contentDescription = label })
}

/**
 * Mute as the fourth tile, with real durations (MuteStore). A choice, not a toggle: a switch
 * silently picks the most extreme mute. Unmute leads when already muted, because that is what
 * someone opening it almost always wants. Replaces the old Notifications row.
 */
@Composable
private fun MuteTile(conversationId: String, modifier: Modifier = Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val haptics = com.voiid.app.ui.components.LocalVoiidHaptics.current
    var muted by remember(conversationId) { mutableStateOf(com.voiid.app.net.MuteStore.isMuted(context, conversationId)) }
    var until by remember(conversationId) { mutableStateOf(com.voiid.app.net.MuteStore.mutedUntil(context, conversationId)) }
    var choosing by remember { mutableStateOf(false) }
    // Says WHEN it lifts; "Muted" alone leaves the user guessing.
    val label = when {
        !muted -> "Mute"
        until == null -> "Muted"
        else -> {
            val hours = maxOf(1L, ((until!! - System.currentTimeMillis()) + 3_599_999L) / 3_600_000L)
            if (hours < 24) "Muted · ${hours}h" else "Muted · ${(hours + 23) / 24}d"
        }
    }
    // A DROPDOWN anchored to the tile, matching iOS.
    Box(modifier) {
        ContactTileBody(
            if (muted) Icons.Default.NotificationsOff else Icons.Default.Notifications, label, active = muted,
            modifier = Modifier.fillMaxWidth().softClickable { choosing = true }
                .semantics { contentDescription = if (muted) label else "Mute. Choose how long to mute" },
        )
        androidx.compose.material3.DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }) {
            if (muted) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("Unmute", color = VoiidColor.error) },
                    trailingIcon = { Icon(Icons.Default.Notifications, null, tint = VoiidColor.error) },
                    onClick = {
                        com.voiid.app.net.MuteStore.unmute(context, conversationId); muted = false; until = null; choosing = false
                    },
                )
                HorizontalDivider(color = VoiidColor.divider)
            }
            Text("Mute for", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            com.voiid.app.net.MuteStore.Duration.entries.forEach { d ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(d.title) },
                    onClick = {
                        com.voiid.app.net.MuteStore.mute(context, conversationId, d)
                        muted = true; until = com.voiid.app.net.MuteStore.mutedUntil(context, conversationId); choosing = false
                        haptics.selection()
                    },
                )
            }
        }
    }
}

/**
 * A tappable row inside a profile card — Block, Report, and friends.
 *
 * Destructive rows especially: a 44dp row that does not move under the finger reads as
 * disabled. The caller keeps its own heavier haptic on the ACTION alongside the press haptic
 * softClickable fires — one says "I felt that", the other says "this is serious", and they
 * are doing different work. Everywhere else a single press haptic is correct.
 */
@Composable
fun ProfileRow(icon: ImageVector, text: String, tint: Color, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().softClickable(onClick = onClick).padding(vertical = 4.dp),
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

/** Still ringing — not missed yet. call_history stores SECONDS. */
private fun isRingingCall(entry: com.voiid.app.store.CallHistoryRow) =
    com.voiid.app.model.isCallRinging(entry.outcome, entry.startedAt * 1000L, entry.endedAt, entry.connectedAt)

private fun isMissedCall(entry: com.voiid.app.store.CallHistoryRow) =
    entry.direction == "incoming" && entry.outcome != "answered" && !isRingingCall(entry)

/** Talk time in seconds: from when the call connected to when it ended. Stored in SECONDS. */
private fun talkSeconds(entry: com.voiid.app.store.CallHistoryRow): Long {
    if (entry.outcome != "answered") return 0
    val ended = entry.endedAt ?: return 0
    return (ended - (entry.connectedAt ?: entry.startedAt)).coerceAtLeast(0)
}

/** "4 calls · 35 min talked", or just the count when nothing connected. */
private fun callSummary(calls: List<com.voiid.app.store.CallHistoryRow>): String {
    val count = if (calls.size == 1) "1 call" else "${calls.size} calls"
    val minutes = calls.sumOf { talkSeconds(it) } / 60
    return if (minutes > 0) "$count · $minutes min talked" else count
}

/**
 * One call in the profile's Calls card — the Voiid Ui design, mirroring iOS `callRow`.
 *
 * The glyph says what kind, the small badge says which way, the tint says whether it connected;
 * red is never the only signal, because the title says "Missed" too. A missed call carries Call
 * back in place of a duration.
 */
@Composable
private fun CallHistoryRowView(entry: com.voiid.app.store.CallHistoryRow, onCallBack: (CallKind) -> Unit) {
    val missed = isMissedCall(entry)
    val video = entry.kind == "video"
    val tint = if (missed) VoiidColor.error else VoiidColor.accentInk
    Row(
        Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(36.dp)) {
            Box(
                Modifier.size(36.dp).clip(CircleShape)
                    .background(if (missed) VoiidColor.error.copy(alpha = 0.12f) else VoiidColor.accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(if (video) Icons.Default.Videocam else Icons.Default.Call, null, tint = tint, modifier = Modifier.size(16.dp))
            }
            Box(
                Modifier.align(Alignment.BottomEnd).offset(x = 3.dp, y = 3.dp).size(15.dp)
                    .clip(CircleShape).background(VoiidColor.surfaceCard).padding(2.dp)
                    .clip(CircleShape).background(tint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    when {
                        missed -> Icons.Default.Close
                        entry.direction == "incoming" -> Icons.Default.CallReceived
                        else -> Icons.Default.CallMade
                    },
                    null, tint = Color.White, modifier = Modifier.size(8.dp),
                )
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            val medium = if (video) "video" else "voice"
            Text(
                when {
                    missed && entry.outcome == "declined" -> "Declined $medium call"
                    missed -> "Missed $medium call"
                    entry.direction == "incoming" -> "Incoming $medium"
                    else -> "Outgoing $medium"
                },
                style = VoiidFont.rounded(15, FontWeight.Medium),
                color = if (missed) VoiidColor.error else VoiidColor.textPrimary,
            )
            Text(
                // call_history stores SECONDS; the formatter wants millis.
                android.text.format.DateUtils.getRelativeTimeSpanString(
                    entry.startedAt * 1000L, System.currentTimeMillis(),
                    android.text.format.DateUtils.MINUTE_IN_MILLIS,
                ).toString(),
                style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary,
            )
        }
        if (missed) {
            Box(
                Modifier.height(30.dp).clip(RoundedCornerShape(999.dp)).background(VoiidColor.accent)
                    .softClickable { onCallBack(if (video) CallKind.VIDEO else CallKind.VOICE) }
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("Call back", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textOnAccent)
            }
        } else {
            val secs = talkSeconds(entry)
            Text(
                // Ringing, or answered and still going: no finished call to describe yet.
                if (isRingingCall(entry) || (entry.outcome == "answered" && entry.endedAt == null)) "Now"
                else when (entry.outcome) {
                    "answered" -> when {
                        secs < 60 -> "$secs sec"
                        secs < 3600 -> "${secs / 60} min"
                        else -> "${secs / 3600} hr ${(secs / 60) % 60} min"
                    }
                    "busy" -> "Busy"
                    "declined" -> "Declined"
                    "failed" -> "Failed"
                    else -> "No answer"
                },
                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            )
        }
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

/**
 * Two dimmed bars the height of the real About lines.
 *
 * A SKELETON, NOT A SPINNER. The card already occupies this space, so a centred spinner would
 * make the layout jump when text replaces it; bars matched to the real geometry keep it
 * identical. The pulse is what separates "loading" from "broken" — a static grey bar reads as
 * content that failed to render.
 *
 * Mirrors the iOS `PulsePlaceholder` timing exactly (1100ms, reversing) so the two platforms
 * breathe at the same rate.
 */
@Composable
private fun ProfileAboutSkeleton() {
    val pulse = rememberInfiniteTransition(label = "aboutSkeleton")
    val alpha by pulse.animateFloat(
        initialValue = 0.35f,
        targetValue = 0.8f,
        animationSpec = infiniteRepeatable(tween(1100), RepeatMode.Reverse),
        label = "skeletonAlpha",
    )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(14.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(VoiidColor.textPrimary.copy(alpha = 0.08f * alpha * 2f)),
        )
        Box(
            Modifier
                .width(180.dp)
                .height(14.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(VoiidColor.textPrimary.copy(alpha = 0.08f * alpha * 2f)),
        )
    }
}

/**
 * "Notifications" row with a real, persisted mute — twin of iOS's mute menu (MuteStore
 * durations, "Muted until …" subtitle). Replaces a toggle that was never saved and silenced
 * nothing.
 */
@Composable
fun MuteRow(conversationId: String) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val haptics = com.voiid.app.ui.components.LocalVoiidHaptics.current
    var muted by remember(conversationId) { mutableStateOf(com.voiid.app.net.MuteStore.isMuted(context, conversationId)) }
    var until by remember(conversationId) { mutableStateOf(com.voiid.app.net.MuteStore.mutedUntil(context, conversationId)) }
    var choosing by remember { mutableStateOf(false) }
    val subtitle = when {
        !muted -> "On"
        until == null -> "Muted"
        else -> "Muted until " + android.text.format.DateUtils.getRelativeTimeSpanString(
            until!!, System.currentTimeMillis(), android.text.format.DateUtils.MINUTE_IN_MILLIS)
    }
    Row(
        Modifier.fillMaxWidth().softClickable { haptics.tap(); choosing = true }.padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(if (muted) Icons.Default.NotificationsOff else Icons.Default.Notifications, null,
            tint = VoiidColor.textPrimary, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text("Notifications", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
            Text(subtitle, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
    }
    if (choosing) com.voiid.app.ui.components.VoiidDialogCustom(onDismissRequest = { choosing = false }) {
        Text("Notifications", style = VoiidFont.rounded(17, androidx.compose.ui.text.font.FontWeight.SemiBold), color = VoiidColor.textPrimary)
        if (muted) com.voiid.app.ui.components.VoiidDialogAction("Unmute") {
            com.voiid.app.net.MuteStore.unmute(context, conversationId); muted = false; until = null; choosing = false
        }
        com.voiid.app.net.MuteStore.Duration.entries.forEach { d ->
            com.voiid.app.ui.components.VoiidDialogAction("Mute for ${d.title}") {
                com.voiid.app.net.MuteStore.mute(context, conversationId, d)
                muted = true; until = com.voiid.app.net.MuteStore.mutedUntil(context, conversationId); choosing = false
                haptics.selection()
            }
        }
        com.voiid.app.ui.components.VoiidDialogAction("Cancel") { choosing = false }
    }
}


/** One Contact-details row, as in the reference: glyph, label, value; tapping copies the value.
 *  No trailing buttons — Message is the first tile, and the row itself copies. */
@Composable
private fun ContactDetailRow(icon: ImageVector, label: String, value: String) {
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    val haptics = com.voiid.app.ui.components.LocalVoiidHaptics.current
    Row(
        Modifier.fillMaxWidth()
            .softClickable { clipboard.setText(androidx.compose.ui.text.AnnotatedString(value)); haptics.selection() }
            .semantics(mergeDescendants = true) { contentDescription = "$label, $value. Copies to the clipboard" }
            .padding(horizontal = VoiidSpacing.md, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Icon(icon, null, tint = VoiidColor.accentInk, modifier = Modifier.width(26.dp).size(20.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            Text(value, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary, maxLines = 1)
        }
    }
}
