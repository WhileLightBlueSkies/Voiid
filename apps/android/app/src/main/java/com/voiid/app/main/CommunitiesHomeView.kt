package com.voiid.app.main

import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.graphics.asImageBitmap
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
    var searchError by remember { mutableStateOf<String?>(null) }
    var searchingNow by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var open by remember { mutableStateOf<CommunityService.CommunityCard?>(null) }
    var showCreate by remember { mutableStateOf(false) }
    var discovering by remember { mutableStateOf(false) }

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
    LaunchedEffect(query, open, discovering, mine.isEmpty(), loading, error) {
        if (open != null || (!discovering && !searching && (mine.isNotEmpty() || loading || error != null))) return@LaunchedEffect
        searchingNow = true; searchError = null
        try {
            kotlinx.coroutines.delay(250)
            results = svc.search(query.trim())
        }
        catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { searchError = e.message ?: "Couldn’t search communities." }
        finally { searchingNow = false }
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
            if (discovering) {
                androidx.compose.material3.TextButton(onClick = { discovering = false; query = "" }) { Text("Back") }
            }
            Text(if (discovering) "Discover" else "Communities", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.fieldFill)
                    .softClickable { haptics.tap(); showCreate = true },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Add, "Create a community", tint = VoiidColor.primary) }
        }

        if (!discovering) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 12.dp)
                .clip(RoundedCornerShape(16.dp)).background(VoiidColor.surfaceCard)
                .softClickable { haptics.tap(); query = ""; discovering = true }
                .semantics { contentDescription = "Discover communities. Browse public communities" }
                .padding(16.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.Groups, null, tint = VoiidColor.primary, modifier = Modifier.size(28.dp))
                Column(Modifier.weight(1f)) {
                    Text("Discover communities", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Text("Browse public communities", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                }
                Text("›", color = VoiidColor.textSecondary, style = VoiidFont.rounded(24))
            }
        }
        androidx.activity.compose.BackHandler(enabled = discovering) { discovering = false; query = "" }

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

        val recommended = !discovering && !searching && mine.isEmpty() && !loading && error == null
        val browsing = discovering || searching || recommended
        val shown = if (browsing) results else mine
        val listError = if (browsing) searchError else error
        val listLoading = if (browsing) searchingNow else loading
        when {
            listError != null && shown.isEmpty() ->
                Message(listError, action = "Try again") {
                    if (browsing) scope.launch {
                        searchingNow = true; searchError = null
                        try { results = svc.search(query.trim()) }
                        catch (e: kotlinx.coroutines.CancellationException) { throw e }
                        catch (e: Exception) { searchError = e.message ?: "Couldn’t search communities." }
                        finally { searchingNow = false }
                    } else scope.launch { loadMine() }
                }
            listLoading && shown.isEmpty() -> Message("Finding communities…")
            shown.isEmpty() && browsing -> Message(if (searching) "No communities match that." else "Nothing to discover yet.")
            shown.isEmpty() -> Message("You’re not in any communities yet. Tap Discover communities above, scan a QR code, or open an invite link.")
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
                if (recommended) item { Text("Recommended communities", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textSecondary); Spacer(Modifier.height(12.dp)) }
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
                    style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (card.official == true) Pill("Official", fill = VoiidColor.accentTint, textColor = VoiidColor.accentInk)
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
internal fun CommunityDetailView(
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
    var notificationMode by remember(card.id) { mutableStateOf<String?>(null) }
    var savingNotifications by remember { mutableStateOf(false) }
    LaunchedEffect(card.id, state.isMember) {
        if (state.isMember) notificationMode = runCatching { service.notificationPreference(card.id) }.getOrNull()
    }
    var showSettings by remember { mutableStateOf(false) }
    var showAdmin by remember { mutableStateOf(false) }
    var showInvite by remember { mutableStateOf(false) }
    var showReport by remember { mutableStateOf(false) }
    val myUserId = remember { com.voiid.app.net.TokenStore.get(context).userId }
    /** The card carries `owner_id`, so this needs no extra request. */
    val amHost = state.owner_id != null && state.owner_id == myUserId

    val amManager = amHost || state.isManager

    suspend fun reload() {
        runCatching { service.resolve(com.voiid.app.net.CommunityLink(state.handle, null)) }
            .onSuccess { state = it }
            .onFailure { actionError = it.message ?: "Couldn’t refresh this community." }
    }

    val lifecycle = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(card.id) {
        com.voiid.app.net.DeepLinkRouter.communityMembershipChanges.collect { changed -> if (changed == card.id) reload() }
    }
    LaunchedEffect(card.id, lifecycle) {
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) {
                reload()
                com.voiid.app.net.GroupEngine.get(context).syncGroupEvents()
                kotlinx.coroutines.delay(10000)
            }
        }
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
                if (state.official == true) Pill("Official", fill = VoiidColor.accentTint, textColor = VoiidColor.accentInk)
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

                if (amManager) {
                    OutlinePill("Inbox", CommunityIcon.INBOX, Modifier.weight(1f)) {
                        haptics.tap(); showHostInbox = true
                    }
                } else if (state.canInvite) {
                    OutlinePill("Invite", CommunityIcon.PERSON_ADD, Modifier.weight(1f)) {
                        haptics.tap(); showInvite = true
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
                        if (state.isMember) {
                            for (mode in listOf("all", "important", "none")) {
                                CommunityMenuItem("Notifications: " + mode.replaceFirstChar { it.uppercase() }, if (notificationMode == mode) CommunityIcon.CHECK else CommunityIcon.MEGAPHONE) {
                                    if (!savingNotifications) {
                                        savingNotifications = true
                                        menuOpen = false
                                        scope.launch {
                                            try { service.setNotificationPreference(state.id, mode); notificationMode = mode }
                                            catch (e: Exception) { actionError = "Couldn't save notification settings. Please try again." }
                                            finally { savingNotifications = false }
                                        }
                                    }
                                }
                            }
                            CommunityMenuDivider()
                        }
                        if (amManager) {
                            CommunityMenuItem("Admin panel", CommunityIcon.GEAR) {
                                menuOpen = false; haptics.tap(); showAdmin = true
                            }
                            CommunityMenuDivider()
                        }
                        if (state.canInvite || state.discoverable) CommunityMenuItem("Invite / QR code", CommunityIcon.SHARE) {
                            menuOpen = false; haptics.tap(); showInvite = true
                        }
                        CommunityMenuItem("Report", CommunityIcon.WARNING) {
                            menuOpen = false; haptics.tap(); showReport = true
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
            CommunityTabBar(selected = tab, isManager = amManager, onSelect = { tab = it })
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
                        CommunityHomeTab(communityId = state.id, isAdmin = amManager, canPost = state.posting_policy != "managers" || amManager)
                    }
                    CommunityTab.SPACES ->
                        CommunitySpacesTab(communityId = state.id, isAdmin = amManager, onOpen = onOpenConversation)
                    CommunityTab.EVENTS -> Column(
                        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                    ) {
                        CommunityEventsSection(communityId = state.id, isOwner = amHost, isManager = amManager)
                        // Tournaments hidden until an explicit post-launch enablement.
                    }
                    CommunityTab.MEMBERS ->
                        CommunityMembersTab(communityId = state.id, isAdmin = amManager, isOwner = amHost)
                    CommunityTab.ABOUT ->
                        CommunityAboutTab(card = state, isAdmin = amManager)
                }
            }
        } else {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                CommunityAboutTab(card = state, isAdmin = false)
            }
        }

        Spacer(Modifier.height(96.dp))
    }

    if (showInvite) CommunityInviteSheet(state, service) { showInvite = false }
    if (showReport) ReportSheet(com.voiid.app.net.ReportTarget.Community(state.id)) { showReport = false }
    if (showAdmin) CommunityControlPanel(state,amHost,onDismiss={showAdmin=false},onSettings={showAdmin=false;showSettings=true})
    if (showSettings) {
        CommunitySettingsScreen(
            card = state,
            onSaved = { state = it },
            onClose = { showSettings = false },
        )
    }

    if (showHostInbox) {
        CommunityRequestInbox(
            communityId = state.id,
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


@Composable
private fun CommunityInviteSheet(card: CommunityService.CommunityCard, service: CommunityService, onClose: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var url by remember(card.id) { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var invites by remember { mutableStateOf<List<CommunityService.Invite>>(emptyList()) }
    suspend fun create() {
        if (busy) return
        busy = true; error = null
        try {
            val token = if (card.canInvite) service.createInvite(card.id, 100, 168).token else null
            url = com.voiid.app.net.CommunityLink.format(card.handle, token)
            if (card.isManager) invites = service.invites(card.id)
        } catch (e: Exception) { error = e.message ?: "Couldn’t create an invite." }
        finally { busy = false }
    }
    LaunchedEffect(card.id) { create() }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onClose,
        title = { Text(card.name) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val image = remember(url) {
                    url?.let { value -> runCatching {
                        val matrix = com.google.zxing.qrcode.QRCodeWriter().encode(value, com.google.zxing.BarcodeFormat.QR_CODE, 600, 600)
                        android.graphics.Bitmap.createBitmap(600, 600, android.graphics.Bitmap.Config.ARGB_8888).apply {
                            for (y in 0 until 600) for (x in 0 until 600) setPixel(x, y, if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
                        }
                    }.getOrNull() }
                }
                if (image != null) androidx.compose.foundation.Image(image.asImageBitmap(), "Community invite QR", Modifier.fillMaxWidth())
                Text("Scanning opens a preview. Joining never grants an admin role.")
                if (card.canInvite) Text("Links expire in 7 days or after 100 joins.")
                if (error != null) Text(error!!, color = VoiidColor.error)
                if (url != null) androidx.compose.material3.TextButton(onClick = {
                    context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"; putExtra(android.content.Intent.EXTRA_TEXT, url)
                    }, "Share community"))
                }) { Text("Share invite") }
                if (card.canInvite) androidx.compose.material3.TextButton(enabled = !busy, onClick = { scope.launch { create() } }) { Text("Create a new link") }
                invites.forEach { invite ->
                    androidx.compose.material3.TextButton(enabled = !busy, onClick = { scope.launch {
                        busy = true
                        try {
                            service.revokeInvite(card.id, invite.token)
                            invites = invites.filterNot { it.token == invite.token }
                            if (url?.contains(invite.token) == true) url = null
                        } catch (e: Exception) { error = e.message }
                        finally { busy = false }
                    } }) { Text("Revoke link · " + (invite.expires_at?.take(10) ?: "No expiry")) }
                }
            }
        },
        confirmButton = { androidx.compose.material3.TextButton(onClick = onClose) { Text("Done") } },
    )
}
