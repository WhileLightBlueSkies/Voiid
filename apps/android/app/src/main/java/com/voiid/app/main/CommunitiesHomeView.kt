package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.rememberVoiidPullRefresh
import com.voiid.app.ui.components.voiidPullRefresh
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch
import com.voiid.app.ui.theme.VoiidSpacing
import com.voiid.app.ui.components.pressableClickable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.border

/**
 * The Communities tab. Replaces the "coming soon" placeholder. Port of iOS
 * `CommunitiesHomeView.swift`.
 *
 * ── WHAT IS AND IS NOT ENCRYPTED ─────────────────────────────────────────────────
 * A community's CHANNELS are ordinary MLS group conversations and stay end-to-end
 * encrypted. The container — name, handle, roster, search, invites — is server-readable,
 * as declared in the header of 030_communities.sql. This screen shows only the container,
 * so nothing on it is encrypted and the copy does not imply otherwise.
 *
 * ── JOINING IS NOT A MESSAGING RIGHT ─────────────────────────────────────────────
 * Membership grants access to channels and exactly one private line — to the OWNER, and
 * only the owner. Reaching any other member still takes one of the three paths in
 * 020_reachability.sql. There is deliberately no "message" affordance on any row here.
 */
@Composable
fun CommunitiesHomeView(
    /** Handed a conversation id from the host inbox — the caller owns navigation. */
    onOpenConversation: (String) -> Unit = {},
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { CommunityService(context) }

    var mine by remember { mutableStateOf<List<CommunityService.CommunityCard>>(emptyList()) }
    var results by remember { mutableStateOf<List<CommunityService.CommunityCard>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var open by remember { mutableStateOf<CommunityService.CommunityCard?>(null) }
    var showCreate by remember { mutableStateOf(false) }

    // Searching REPLACES the list rather than filtering `mine`: discovery is a different
    // source with its own endpoint, not a filter over what you already belong to.
    val searching = query.trim().length >= 2

    suspend fun loadMine() {
        loading = true; error = null
        runCatching { svc.mine() }
            .onSuccess { mine = it }
            .onFailure { error = it.message ?: "Couldn't load your communities." }
        loading = false
    }

    val pull = com.voiid.app.ui.components.rememberVoiidPullRefresh { scope.launch { loadMine() } }
    LaunchedEffect(Unit) { loadMine() }
    LaunchedEffect(query) {
        // Failures are silent here on purpose: an error banner over a live-typing field
        // flickers on every keystroke, and "no results" reads the same to the user.
        results = if (searching) runCatching { svc.search(query) }.getOrDefault(emptyList())
                  else emptyList()
    }

    open?.let { card ->
        CommunityDetailView(
            card = card,
            service = svc,
            onBack = { open = null; scope.launch { loadMine() } },
            onOpenConversation = onOpenConversation,
        )
        return
    }

    // WIRED. This used to fire a tap haptic and nothing else. Now it opens the five-step
    // create flow; the SERVER's card comes back (id + handle are the server's to confirm).
    if (showCreate) {
        CommunityCreateFlow(
            service = svc,
            onCreate = { card ->
                showCreate = false
                scope.launch { loadMine() }
                open = card
            },
            onCancel = { showCreate = false },
        )
        return
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).voiidPullRefresh(pull, VoiidColor.primary)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Communities", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.fieldFill)
                    .softClickable { haptics.tap(); showCreate = true },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Add, "Create a community", tint = VoiidColor.primary) }
        }

        BasicTextField(
            value = query, onValueChange = { query = it },
            singleLine = true,
            textStyle = TextStyle(color = VoiidColor.textPrimary),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.fieldFill)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            decorationBox = { inner ->
                if (query.isEmpty()) {
                    Text("Find a community", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                }
                inner()
            },
        )
        Spacer(Modifier.height(12.dp))

        val shown = if (searching) results else mine
        when {
            // Error beats empty: rendering "you're in none" for a failed request is a lie
            // the user cannot act on.
            error != null && mine.isEmpty() && !searching ->
                Message(error!!, action = "Try again") { scope.launch { loadMine() } }
            shown.isEmpty() && !loading && searching ->
                Message("No communities match that.")
            shown.isEmpty() && !loading ->
                Message("You're not in any communities yet. Search above, or open an invite link.")
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
                items(shown, key = { it.id }) { card ->
                    CommunityRow(card) { haptics.tap(); open = card }
                    Spacer(Modifier.height(10.dp))
                }
            }
        }
    }
}

@Composable
private fun CommunityRow(card: CommunityService.CommunityCard, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard).softClickable(onClick = onClick).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.size(52.dp).clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.fieldFill),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Outlined.Groups, null, tint = VoiidColor.primary) }

        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(card.name ?: "@${card.handle}",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                if (card.isMember) {
                    Text("joined", style = VoiidFont.rounded(10, FontWeight.SemiBold),
                        color = VoiidColor.primary,
                        modifier = Modifier.clip(CircleShape)
                            .background(VoiidColor.accent.copy(alpha = 0.35f))
                            .padding(horizontal = 6.dp, vertical = 2.dp))
                } else if (card.isPending) {
                    Text("requested", style = VoiidFont.rounded(10), color = VoiidColor.textSecondary)
                }
            }
            card.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary, maxLines = 2)
            }
            Text("${card.member_count} member${if (card.member_count == 1) "" else "s"}",
                style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
        }
    }
}

@Composable
private fun Message(text: String, action: String? = null, onAction: () -> Unit = {}) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(text, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
        if (action != null) {
            Spacer(Modifier.height(12.dp))
            Text(action, style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = VoiidColor.primary, modifier = Modifier.softClickable(onClick = onAction))
        }
    }
}

/**
 * One community — a tabbed shell mirroring iOS `CommunityDetailView`: Home, Spaces, Events,
 * Members, About, plus the host bar (members get one private line to the owner) and, for the
 * host, the inbox of threads opened with them.
 */
@Composable
private fun CommunityDetailView(
    card: CommunityService.CommunityCard,
    service: CommunityService,
    onBack: () -> Unit,
    onOpenConversation: (String) -> Unit = {},
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current
    var state by remember { mutableStateOf(card) }
    var busy by remember { mutableStateOf(false) }
    /** A failure from a TAP, kept apart from a failure to LOAD. */
    var actionError by remember { mutableStateOf<String?>(null) }
    var tab by remember { mutableStateOf(CommunityTab.HOME) }
    var showHostInbox by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    val myUserId = remember { com.voiid.app.net.TokenStore.get(context).userId }
    /** The card carries `owner_id`, so this needs no extra request. */
    val amHost = state.owner_id != null && state.owner_id == myUserId

    suspend fun reload() {
        runCatching { service.resolve(com.voiid.app.net.CommunityLink(state.handle, null)) }
            .onSuccess { state = it }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .verticalScroll(rememberScrollState()),
    ) {
        // ── The hero: a 132dp accent wash the identity mark overlaps ─────────────
        Box(
            Modifier
                .fillMaxWidth()
                .height(132.dp)
                .background(
                    Brush.linearGradient(
                        listOf(
                            VoiidColor.accent.copy(alpha = 0.22f),
                            VoiidColor.accent.copy(alpha = 0.05f),
                            VoiidColor.background,
                        ),
                        start = Offset(Float.POSITIVE_INFINITY, 0f),
                        end = Offset(0f, Float.POSITIVE_INFINITY),
                    )
                )
                .statusBarsPadding(),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier
                        .size(34.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.surfaceCard.copy(alpha = 0.9f))
                        .softClickable(onClick = onBack)
                        .semantics { contentDescription = "Back" },
                    contentAlignment = Alignment.Center,
                ) {
                    CommunityGlyph(CommunityIcon.CHEVRON_RIGHT, size = 15.dp,
                        tint = VoiidColor.textPrimary, rotate = 180f)
                }
            }
        }

        // ── Identity ─────────────────────────────────────────────────────────────
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            // Pulled up over the hero by half its height, and the negative bottom padding
            // cancels the space it vacated so the name sits directly beneath it.
            Box(
                Modifier
                    .offset(y = (-34).dp)
                    .padding(bottom = (-34).dp)
                    .size(68.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.accentTint)
                    .border(4.dp, VoiidColor.background, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    AvatarPalette.initialsFor(state.name.ifEmpty { state.handle }),
                    style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.accentInk,
                )
            }

            Spacer(Modifier.height(VoiidSpacing.sm))

            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(state.name.ifEmpty { "@${state.handle}" },
                    style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
                if (amHost) {
                    Pill("HOST", fill = VoiidColor.accent, textColor = VoiidColor.textOnAccent,
                        fontSize = 9.5f, hPad = 6.dp, vPad = 2.dp)
                }
            }

            Spacer(Modifier.height(VoiidSpacing.sm))

            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CommunityGlyph(CommunityIcon.MEMBERS, size = 11.dp, tint = VoiidColor.textSecondary)
                Text(memberCountText(state.member_count),
                    style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
                Text("·", style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
                CommunityGlyph(JoinPolicyOption.icon(state.join_policy), size = 10.dp,
                    tint = VoiidColor.textSecondary)
                Text(JoinPolicyOption.shortLabel(state.join_policy),
                    style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
            }

            state.description?.takeIf { it.isNotBlank() }?.let {
                Spacer(Modifier.height(VoiidSpacing.sm))
                Text(it, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            }

            Spacer(Modifier.height(VoiidSpacing.sm))
            Text("@${state.handle}", style = VoiidFont.rounded(12.5f),
                color = VoiidColor.placeholder)

            // ── Actions ──────────────────────────────────────────────────────────
            Spacer(Modifier.height(VoiidSpacing.md))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                JoinPill(
                    state = state, busy = busy, modifier = Modifier.weight(1f),
                    onJoin = {
                        if (busy) return@JoinPill
                        haptics.tap(); busy = true
                        scope.launch {
                            runCatching { service.join(state.id, null) }
                                // A full reload, never an optimistic flip: whether a join
                                // landed as active or pending is the server's to say.
                                .onSuccess { reload() }
                                .onFailure { actionError = it.message ?: "Couldn't join." }
                            busy = false
                        }
                    },
                    onCancelRequest = {
                        if (busy) return@JoinPill
                        haptics.tap(); busy = true
                        scope.launch {
                            runCatching { service.leave(state.id) }
                                .onSuccess { reload() }
                                .onFailure {
                                    actionError = it.message ?: "Couldn't cancel that request."
                                }
                            busy = false
                        }
                    },
                )

                if (amHost) {
                    OutlinePill("Inbox", CommunityIcon.INBOX, Modifier.weight(1f)) {
                        haptics.tap(); showHostInbox = true
                    }
                } else if (state.isMember) {
                    OutlinePill("Invite", CommunityIcon.PERSON_ADD, Modifier.weight(1f)) {
                        haptics.tap()
                    }
                }

                Box {
                    Box(
                        Modifier
                            .size(width = 46.dp, height = 40.dp)
                            .clip(RoundedCornerShape(VoiidRadius.pill))
                            .background(VoiidColor.surfaceCard)
                            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.pill))
                            .pressableClickable { menuOpen = true }
                            .semantics { contentDescription = "More community options" },
                        contentAlignment = Alignment.Center,
                    ) {
                        CommunityGlyph(CommunityIcon.ELLIPSIS, size = 13.dp,
                            tint = VoiidColor.textPrimary)
                    }
                    CommunityMenu(menuOpen, { menuOpen = false }) {
                        if (amHost) {
                            CommunityMenuItem("Community settings", CommunityIcon.GEAR) {
                                menuOpen = false; haptics.tap(); showSettings = true
                            }
                            CommunityMenuDivider()
                        }
                        CommunityMenuItem("Share community", CommunityIcon.SHARE) {
                            menuOpen = false; haptics.tap()
                        }
                        CommunityMenuItem("Report", CommunityIcon.WARNING) {
                            menuOpen = false; haptics.tap()
                        }
                        if (state.isMember && !amHost) {
                            CommunityMenuDivider()
                            CommunityMenuItem("Leave community", CommunityIcon.MINUS_CIRCLE,
                                destructive = true) {
                                menuOpen = false
                                haptics.tap()
                                scope.launch {
                                    runCatching { service.leave(state.id) }
                                        .onSuccess { reload() }
                                        .onFailure {
                                            actionError = it.message ?: "Couldn't leave."
                                        }
                                }
                            }
                        }
                    }
                }
            }

            actionError?.let {
                Spacer(Modifier.height(VoiidSpacing.sm))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
        }

        Spacer(Modifier.height(VoiidSpacing.md))
        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider))
        Spacer(Modifier.height(VoiidSpacing.md))

        // ── Tabs ─────────────────────────────────────────────────────────────────
        // A non-member gets About only — there is nothing else they may read.
        if (state.isMember) {
            CommunityTabBar(selected = tab, onSelect = { tab = it })
            Spacer(Modifier.height(VoiidSpacing.md))
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                when (tab) {
                    CommunityTab.HOME -> {
                        if (!amHost) {
                            MessageHostButton(
                                communityId = state.id,
                                onOpenConversation = onOpenConversation,
                            )
                            Spacer(Modifier.height(VoiidSpacing.md))
                        }
                        CommunityHomeTab(communityId = state.id, isAdmin = amHost)
                    }
                    CommunityTab.SPACES ->
                        CommunitySpacesTab(communityId = state.id, isAdmin = amHost)
                    CommunityTab.EVENTS -> Column(
                        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                    ) {
                        CommunityEventsSection(communityId = state.id)
                        CommunityTournamentsSection(communityId = state.id)
                    }
                    CommunityTab.MEMBERS ->
                        CommunityMembersTab(communityId = state.id, isAdmin = amHost)
                    CommunityTab.ABOUT ->
                        CommunityAboutTab(card = state, isAdmin = amHost)
                }
            }
        } else {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                CommunityAboutTab(card = state, isAdmin = false)
            }
        }

        Spacer(Modifier.height(96.dp))
    }

    if (showSettings) {
        CommunitySettingsScreen(
            card = state,
            onSaved = { state = it },
            onClose = { showSettings = false },
        )
    }

    if (showHostInbox) {
        CommunityHostInboxView(
            onOpenConversation = onOpenConversation,
            onClose = { showHostInbox = false },
        )
    }
}

/**
 * The join control. One switch over the caller's membership, mirroring iOS: three of the
 * five states are dimmed labels rather than buttons, because there is nothing to press.
 */
@Composable
private fun JoinPill(
    state: CommunityService.CommunityCard,
    busy: Boolean,
    modifier: Modifier = Modifier,
    onJoin: () -> Unit,
    onCancelRequest: () -> Unit,
) {
    when {
        state.isBanned -> DimmedPill("You can't join", modifier)
        state.suspended -> DimmedPill("Suspended", modifier)
        state.isMember -> DimmedPill("Joined", modifier, icon = CommunityIcon.CHECK)
        state.isPending -> FilledPill(
            "Cancel request", CommunityIcon.CLOSE, filled = false,
            enabled = !busy, modifier = modifier, onClick = onCancelRequest,
        )
        else -> FilledPill(
            if (state.join_policy == "approval") "Request to join" else "Join",
            CommunityIcon.PLUS, filled = true,
            enabled = !busy, modifier = modifier, onClick = onJoin,
        )
    }
}

@Composable
private fun DimmedPill(
    text: String, modifier: Modifier = Modifier, icon: CommunityIcon? = null,
) {
    Row(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.accent)
            .alpha(0.75f),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let { CommunityGlyph(it, size = 13.dp, tint = VoiidColor.textOnAccent) }
        Text(text, style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = VoiidColor.textOnAccent)
    }
}

@Composable
private fun FilledPill(
    text: String, icon: CommunityIcon, filled: Boolean, enabled: Boolean,
    modifier: Modifier = Modifier, onClick: () -> Unit,
) {
    Row(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(if (filled) VoiidColor.accent else VoiidColor.surfaceCard)
            .then(
                if (filled) Modifier
                else Modifier.border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.pill))
            )
            .pressableClickable(enabled = enabled, onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommunityGlyph(icon, size = 13.dp,
            tint = if (filled) VoiidColor.textOnAccent else VoiidColor.textPrimary)
        Text(text, style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = if (filled) VoiidColor.textOnAccent else VoiidColor.textPrimary)
    }
}

@Composable
private fun OutlinePill(
    text: String, icon: CommunityIcon, modifier: Modifier = Modifier, onClick: () -> Unit,
) {
    Row(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.pill))
            .pressableClickable(onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommunityGlyph(icon, size = 13.dp, tint = VoiidColor.textPrimary)
        Text(text, style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = VoiidColor.textPrimary)
    }
}


/** Spaces tab — channels list; announcement badges mark host-writes rows. */
/** Members tab — active roster with role badges; hosts also see pending requests. */
/** About tab — the container facts, stated plainly. */
