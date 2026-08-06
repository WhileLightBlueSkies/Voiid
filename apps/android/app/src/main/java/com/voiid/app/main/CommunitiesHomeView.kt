package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
fun CommunitiesHomeView() {
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

    LaunchedEffect(Unit) { loadMine() }
    LaunchedEffect(query) {
        // Failures are silent here on purpose: an error banner over a live-typing field
        // flickers on every keystroke, and "no results" reads the same to the user.
        results = if (searching) runCatching { svc.search(query) }.getOrDefault(emptyList())
                  else emptyList()
    }

    open?.let { card ->
        CommunityDetailView(card = card, service = svc, onBack = { open = null; scope.launch { loadMine() } })
        return
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Communities", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.fieldFill)
                    .softClickable { haptics.tap() },
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
 * One community. Deliberately has NO tappable member list: membership grants a private line
 * to the owner and to nobody else (030 enforces this by absence — community_host_threads has
 * nowhere to put a second member), so a roster you could tap into would imply a reachability
 * this product does not give you.
 */
@Composable
private fun CommunityDetailView(
    card: CommunityService.CommunityCard,
    service: CommunityService,
    onBack: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf(card) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().padding(16.dp)) {
        Text("← Back", style = VoiidFont.rounded(15, FontWeight.Medium),
            color = VoiidColor.primary, modifier = Modifier.softClickable(onClick = onBack))
        Spacer(Modifier.height(16.dp))
        Text(state.name ?: "@${state.handle}",
            style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
        Text("${state.member_count} member${if (state.member_count == 1) "" else "s"} · ${state.join_policy}",
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        state.description?.takeIf { it.isNotBlank() }?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
        }
        Spacer(Modifier.height(20.dp))

        when {
            state.isBanned -> Text("You can't join this community.",
                style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            state.isMember -> Text("You're a member.",
                style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            // "requested" rather than "joined": an approval-gated community leaves you
            // pending, and saying otherwise is a lie the next screen would expose.
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
                                .onFailure { error = it.message ?: "Couldn't join." }
                            busy = false
                        }
                    }
                    .padding(vertical = 12.dp),
            )
        }
        error?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }

        Spacer(Modifier.weight(1f))
        // Stated rather than buried: users deserve to know which half of a feature is encrypted.
        Text(
            "Channel messages inside a community are end-to-end encrypted. The community "
                + "itself — its name, members and invites — is not, so it can be searched and joined.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )
    }
}
