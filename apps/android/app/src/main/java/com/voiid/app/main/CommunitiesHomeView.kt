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
    var error by remember { mutableStateOf<String?>(null) }
    var tab by remember { mutableStateOf(CommunityTab.HOME) }
    var showHostInbox by remember { mutableStateOf(false) }
    val myUserId = remember { com.voiid.app.net.TokenStore.get(context).userId }
    val amHost = state.owner_id != null && state.owner_id == myUserId

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("← Back", style = VoiidFont.rounded(15, FontWeight.Medium),
                color = VoiidColor.primary, modifier = Modifier.softClickable(onClick = onBack))
            Spacer(Modifier.weight(1f))
            if (amHost) {
                Text("Host inbox", style = VoiidFont.rounded(14, FontWeight.Medium),
                    color = VoiidColor.primary,
                    modifier = Modifier.softClickable { haptics.tap(); showHostInbox = true })
            }
        }

        // Header
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Text(state.name ?: "@${state.handle}",
                style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text("${state.member_count} member${if (state.member_count == 1) "" else "s"} · ${state.join_policy}",
                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            Spacer(Modifier.height(10.dp))

            when {
                state.isBanned -> Text("You can't join this community.",
                    style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                state.isMember -> {}
                state.isPending -> Text("Your request is waiting for approval.",
                    style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                else -> Text(
                    if (state.join_policy == "approval") "Request to join" else "Join",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textOnPrimary,
                    modifier = Modifier.fillMaxWidth().clip(CircleShape).background(VoiidColor.primary)
                        .softClickable {
                            if (busy) return@softClickable
                            haptics.tap(); busy = true
                            scope.launch {
                                runCatching { service.join(state.id, null) }
                                    .onSuccess {
                                        state = state.copy(membership_state = it.state)
                                        scope.launch { /* roster reloads per-tab */ }
                                    }
                                    .onFailure { error = it.message ?: "Couldn't join." }
                                busy = false
                            }
                        }
                        .padding(vertical = 12.dp),
                )
            }
            error?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
        }

        // Tabs
        val tabs = CommunityTab.entries
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            tabs.forEach { t ->
                val selected = tab == t
                Box(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (selected) VoiidColor.primary else VoiidColor.fieldFill)
                        .softClickable(scale = 0.94f) { haptics.selection(); tab = t }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                ) {
                    Text(t.name.lowercase().replaceFirstChar { it.uppercase() },
                         style = VoiidFont.rounded(13, FontWeight.SemiBold),
                         color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary)
                }
            }
        }

        when (tab) {
            CommunityTab.HOME -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
                state.description?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
                    Spacer(Modifier.height(16.dp))
                }
                if (state.isMember && !amHost) {
                    MessageHostButton(
                        communityId = state.id,
                        onOpenConversation = onOpenConversation,
                    )
                    Spacer(Modifier.height(16.dp))
                }
                Text(
                    "Channel messages inside a community are end-to-end encrypted. The community "
                        + "itself — its name, members and invites — is not, so it can be searched and joined.",
                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                )
                Spacer(Modifier.height(20.dp))
            }
            CommunityTab.SPACES -> CommunitySpacesSection(
                communityId = state.id,
                enabled = state.isMember,
            )
            CommunityTab.EVENTS -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
                if (!state.isMember) {
                    Text("Join to see events.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                } else {
                    CommunityTournamentsSection(communityId = state.id)
                    Spacer(Modifier.height(20.dp))
                    CommunityEventsSection(communityId = state.id)
                }
            }
            CommunityTab.MEMBERS -> CommunityMembersSection(
                communityId = state.id,
                enabled = state.isMember,
                amHost = amHost,
                onOpenConversation = onOpenConversation,
            )
            CommunityTab.ABOUT -> AboutBody(state)
        }
    }

    if (showHostInbox) {
        CommunityHostInboxView(onOpenConversation = onOpenConversation, onClose = { showHostInbox = false })
    }
}

private enum class CommunityTab { HOME, SPACES, EVENTS, MEMBERS, ABOUT }

/** Spaces tab — channels list; announcement badges mark host-writes rows. */
@Composable
private fun CommunitySpacesSection(communityId: String, enabled: Boolean) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var channels by remember { mutableStateOf<List<CommunityService.Channel>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    androidx.compose.runtime.LaunchedEffect(communityId, enabled) {
        if (!enabled) return@LaunchedEffect
        runCatching { CommunityService(context).channels(communityId) }
            .onSuccess { channels = it }
            .onFailure { error = "Couldn't load Spaces." }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
        when {
            !enabled -> Text("Join to browse Spaces.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            error != null -> Text(error!!, style = VoiidFont.rounded(14), color = VoiidColor.error)
            channels == null -> Text("Loading…", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            channels!!.isEmpty() -> Text("No Spaces yet.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            else -> channels!!.forEach { c ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(Icons.Outlined.Groups, null, tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
                    Text(c.name ?: "space", style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
                    if (c.isAnnouncement) {
                        Text("announcements", style = VoiidFont.rounded(10, FontWeight.SemiBold),
                            color = VoiidColor.primary,
                            modifier = Modifier.clip(CircleShape)
                                .background(VoiidColor.primary.copy(alpha = 0.1f))
                                .padding(horizontal = 6.dp, vertical = 2.dp))
                    }
                }
            }
        }
    }
}

/** Members tab — active roster with role badges; hosts also see pending requests. */
@Composable
private fun CommunityMembersSection(
    communityId: String,
    enabled: Boolean,
    amHost: Boolean,
    onOpenConversation: (String) -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val store = com.voiid.app.store.UserDirectory
    var members by remember { mutableStateOf<List<CommunityService.Member>?>(null) }
    var pending by remember { mutableStateOf<List<CommunityService.Member>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    androidx.compose.runtime.LaunchedEffect(communityId, enabled) {
        if (!enabled) return@LaunchedEffect
        runCatching { CommunityService(context).members(communityId) }
            .onSuccess { members = it }
            .onFailure { error = "Couldn't load members." }
        if (amHost) {
            pending = runCatching { CommunityService(context).members(communityId, state = "pending") }.getOrDefault(emptyList())
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
        when {
            !enabled -> Text("Join to see members.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            error != null -> Text(error!!, style = VoiidFont.rounded(14), color = VoiidColor.error)
            members == null -> Text("Loading…", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            else -> members!!.forEach { m ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    com.voiid.app.ui.components.VoiidAvatar(size = 36.dp)
                    Column(Modifier.weight(1f)) {
                        Text(store.displayName(m.user_id), style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
                    }
                    if (m.isOwner) RoleBadge("owner", filled = true) else if (m.role == "admin") RoleBadge("admin", filled = false)
                    if (m.user_id == com.voiid.app.net.TokenStore.get(context).userId) {
                        Text("You", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                    }
                }
            }
        }
        if (amHost && pending.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            Text("Pending requests", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
            pending.forEach { m ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    com.voiid.app.ui.components.VoiidAvatar(size = 32.dp)
                    Spacer(Modifier.width(10.dp))
                    Text(store.displayName(m.user_id), style = VoiidFont.rounded(14), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                    Text("requested", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun RoleBadge(label: String, filled: Boolean) {
    Text(
        label,
        style = VoiidFont.rounded(11, FontWeight.SemiBold),
        color = if (filled) VoiidColor.textOnPrimary else VoiidColor.primary,
        modifier = Modifier
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.primary.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

/** About tab — the container facts, stated plainly. */
@Composable
private fun AboutBody(card: CommunityService.CommunityCard) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
        card.description?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            Spacer(Modifier.height(14.dp))
        }
        AboutRow("Handle", "@${card.handle}")
        AboutRow("Category", "Community")
        AboutRow("Joining", card.join_policy.replace('_', ' '))
        AboutRow("In search", if (card.discoverable) "Yes" else "No")
        Spacer(Modifier.height(14.dp))
        Text(
            "Channel messages are end-to-end encrypted. The community container is not.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )
    }
}

@Composable
private fun AboutRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp)) {
        Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(value, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}
