package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.animation.animateColorAsState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidMotion
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * The Spaces, Members and About tabs of a community. Port of iOS `CommunityTabs.swift`.
 *
 * ── ONE DELIBERATE DIVERGENCE FROM iOS, AND WHY ──────────────────────────────────
 * The iOS Spaces and Members tabs DECORATE each real server row with fake fields cycled out
 * of `CommunitySpace.samples` / `CommunityDirectoryMember.samples`: a member count, a
 * "Design Critique" purpose, an unread badge, a display name and an online dot — none of
 * which any route serves. Every community therefore shows the same invented 48.2K members
 * and the same nine invented people over whatever ids came back.
 *
 * THAT IS NOT PORTED. Where a field has no endpoint, this screen omits it. A Space shows its
 * name and whether it is announcement-only, because those are real; it does not show a
 * member count, because there is no such number. A roster row shows the id-derived avatar,
 * the role and the join date, because those are real; it does not show a display name or an
 * online dot.
 *
 * The result is a quieter screen than the iOS one — and an honest one. When the channels
 * endpoint grows `purpose`/`member_count` and the roster resolves names through
 * UserDirectory, the fields appear here with no fake to tear out first.
 */
enum class CommunityTab(val label: String) {
    HOME("Home"), SPACES("Spaces"), EVENTS("Events"), MEMBERS("Members"), ABOUT("About")
}

// ══════════════════════════════════════════════════════════════════════════════════
//  THE TAB BAR
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
fun CommunityTabBar(
    selected: CommunityTab,
    onSelect: (CommunityTab) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    Row(
        modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = VoiidSpacing.md),
        horizontalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        CommunityTab.entries.forEach { tab ->
            val isSelected = tab == selected
            val labelColor by animateColorAsState(
                if (isSelected) VoiidColor.textPrimary else VoiidColor.textSecondary,
                animationSpec = VoiidMotion.easeOut180(), label = "tabLabel",
            )
            val barColor by animateColorAsState(
                if (isSelected) VoiidColor.accent else androidx.compose.ui.graphics.Color.Transparent,
                animationSpec = VoiidMotion.easeOut180(), label = "tabBar",
            )
            Column(
                Modifier.pressableClickable { haptics.selection(); onSelect(tab) },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    tab.label,
                    style = VoiidFont.rounded(
                        14.5f, if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    color = labelColor,
                )
                // Always 2dp tall, transparent when unselected — so selecting a tab never
                // changes the row's height.
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(2.dp)
                        .clip(RoundedCornerShape(VoiidRadius.pill))
                        .background(barColor)
                )
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  SPACES
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
fun CommunitySpacesTab(
    communityId: String,
    isAdmin: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val svc = remember { CommunityService(context) }

    var channels by remember { mutableStateOf<List<CommunityService.Channel>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(communityId) {
        loading = true
        runCatching { svc.channels(communityId) }
            .onSuccess { channels = it; error = null }
            .onFailure { error = it.message ?: "Couldn't load Spaces." }
        loading = false
    }

    // Announcement Spaces first, then by position. Both facts are real columns.
    val ordered = remember(channels) {
        channels.sortedWith(
            compareByDescending<CommunityService.Channel> { it.isAnnouncement }
                .thenBy { it.position ?: 0 }
        )
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
        if (isAdmin) CreateSpaceRow { haptics.tap() }

        when {
            loading && channels.isEmpty() -> CenteredSpinner()
            error != null && channels.isEmpty() ->
                Emptyish(CommunityIcon.WARNING, error!!, "Pull down to try again.")
            channels.isEmpty() -> Emptyish(
                CommunityIcon.SPACES, "No Spaces yet",
                if (isAdmin) "Create one to give people somewhere to talk."
                else "The host hasn't made any yet.",
            )
            else -> ordered.forEach { SpaceCard(it, isAdmin) }
        }
    }
}

@Composable
private fun CreateSpaceRow(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            // The ONLY card with a tinted border — it is an action, not a listing.
            .border(1.dp, VoiidColor.accent.copy(alpha = 0.4f), RoundedCornerShape(VoiidRadius.md))
            .pressableClickable(onClick = onClick)
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(32.dp).clip(RoundedCornerShape(9.dp)).background(VoiidColor.accent),
            contentAlignment = Alignment.Center,
        ) {
            CommunityGlyph(CommunityIcon.PLUS, size = 15.dp, tint = VoiidColor.textOnAccent)
        }
        Text("Create a Space", style = VoiidFont.rounded(14.5f, FontWeight.SemiBold),
            color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        Pill("Admin", fill = VoiidColor.accentTint, textColor = VoiidColor.accentInk)
    }
}

@Composable
private fun SpaceCard(channel: CommunityService.Channel, isAdmin: Boolean) {
    val haptics = LocalVoiidHaptics.current
    var menuOpen by remember { mutableStateOf(false) }

    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            Modifier.size(42.dp).clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.accentTint),
            contentAlignment = Alignment.Center,
        ) {
            CommunityGlyph(
                if (channel.isAnnouncement) CommunityIcon.MEGAPHONE else CommunityIcon.SPACES,
                size = 16.dp, tint = VoiidColor.accentInk,
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(channel.name ?: "Space", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary)
                if (channel.isAnnouncement) {
                    CommunityGlyph(CommunityIcon.PIN_FILL, size = 9.dp,
                        tint = VoiidColor.textSecondary, rotate = 45f)
                    // Only a RESTRICTED Space is labelled. "Everyone" is the default and
                    // saying so on every other card would be noise.
                    Text("Admins only", style = VoiidFont.rounded(9.5f, FontWeight.SemiBold),
                        color = VoiidColor.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(VoiidRadius.pill))
                            .background(VoiidColor.surfaceRaised)
                            .padding(horizontal = 6.dp, vertical = 2.dp))
                }
                Spacer(Modifier.weight(1f))
                if (isAdmin) {
                    Box {
                        Box(
                            Modifier
                                .size(width = 26.dp, height = 22.dp)
                                .pressableClickable { menuOpen = true }
                                .semantics {
                                    contentDescription = "Manage ${channel.name ?: "Space"}"
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            CommunityGlyph(CommunityIcon.ELLIPSIS, size = 13.dp,
                                tint = VoiidColor.textSecondary)
                        }
                        CommunityMenu(menuOpen, { menuOpen = false }) {
                            CommunityMenuItem("Edit Space", CommunityIcon.PENCIL) {
                                menuOpen = false; haptics.tap()
                            }
                            CommunityMenuItem(
                                if (channel.isAnnouncement) "Allow everyone to post"
                                else "Restrict to admins",
                                CommunityIcon.LOCK,
                            ) { menuOpen = false; haptics.tap() }
                            CommunityMenuDivider()
                            CommunityMenuItem("Archive Space", CommunityIcon.ARCHIVE,
                                destructive = true) { menuOpen = false; haptics.tap() }
                        }
                    }
                }
            }
            // NO purpose line, NO member count, NO unread badge, NO "last activity" —
            // the channels route serves none of them. See the file header.
            Text(
                if (channel.isAnnouncement) "Only admins can post here."
                else "Everyone in this community can post here.",
                style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary,
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  MEMBERS
// ══════════════════════════════════════════════════════════════════════════════════

/** The roster filter. "New" is admin-only, matching iOS. */
enum class MemberFilter(val label: String) { ALL("All"), ADMINS("Admins") }

@Composable
fun CommunityMembersTab(
    communityId: String,
    isAdmin: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { CommunityService(context) }

    var members by remember { mutableStateOf<List<CommunityService.Member>>(emptyList()) }
    var pending by remember { mutableStateOf<List<CommunityService.Member>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var queueError by remember { mutableStateOf<String?>(null) }
    var deciding by remember { mutableStateOf<Set<String>>(emptySet()) }
    var filter by remember { mutableStateOf(MemberFilter.ALL) }
    var query by remember { mutableStateOf("") }

    suspend fun load() {
        loading = true
        runCatching { svc.members(communityId) }
            .onSuccess { members = it; error = null }
            .onFailure { error = it.message ?: "Couldn't load members." }
        if (isAdmin) {
            // A failure here is SWALLOWED rather than blanking the roster: the pending list
            // is an extra, and losing it must not cost the host the members they can see.
            pending = runCatching { svc.members(communityId, state = "pending") }.getOrDefault(emptyList())
        }
        loading = false
    }

    LaunchedEffect(communityId) { load() }

    // Filtering is over what the ROSTER ACTUALLY SERVES — the user id and the role. There is
    // no name or online state to match on, so the search field matches the id.
    val visible = remember(members, filter, query) {
        members
            .filter { if (filter == MemberFilter.ADMINS) it.isAdmin else true }
            .filter { query.isBlank() || it.user_id.contains(query.trim(), ignoreCase = true) }
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
        MemberSearchField(query) { query = it }

        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            MemberFilter.entries.forEach { option ->
                FilterChip(option.label, filter == option) {
                    haptics.selection(); filter = option
                }
            }
        }

        if (isAdmin && pending.isNotEmpty()) {
            Row(
                Modifier.padding(top = VoiidSpacing.xs),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Requests", style = VoiidFont.rounded(12.5f, FontWeight.SemiBold),
                    color = VoiidColor.textSecondary)
                Text(pending.size.toString(), style = VoiidFont.rounded(11, FontWeight.Bold),
                    color = VoiidColor.accentInk)
            }
            pending.forEach { member ->
                MemberRow(
                    member = member, isAdmin = true, pendingRequest = true,
                    busy = deciding.contains(member.user_id),
                    onDecide = { approve ->
                        if (deciding.contains(member.user_id)) return@MemberRow
                        scope.launch {
                            deciding = deciding + member.user_id
                            runCatching {
                                if (approve) svc.approveMember(communityId, member.user_id)
                                else svc.removeMember(communityId, member.user_id)
                            }.onSuccess {
                                queueError = null; haptics.success()
                                load()   // full reload; the roster is the server's to state
                            }.onFailure {
                                haptics.error()
                                // The row STAYS — a request that vanishes without the write
                                // landing is a decision the host thinks they made.
                                queueError = it.message
                                    ?: if (approve) "Couldn't approve that request."
                                       else "Couldn't decline that request."
                            }
                            deciding = deciding - member.user_id
                        }
                    },
                )
            }
            queueError?.let {
                Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error)
            }
        }

        when {
            loading && members.isEmpty() -> CenteredSpinner()
            error != null && members.isEmpty() ->
                Emptyish(CommunityIcon.WARNING, error!!, "Pull down to try again.")
            visible.isEmpty() -> Box(
                Modifier.fillMaxWidth().padding(vertical = 40.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("No members match.", style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary)
            }
            else -> Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                visible.forEach { MemberRow(it, isAdmin, pendingRequest = false, busy = false) }
            }
        }
    }
}

@Composable
private fun MemberSearchField(query: String, onChange: (String) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(42.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.pill))
            .padding(horizontal = VoiidSpacing.md),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommunityGlyph(CommunityIcon.SEARCH, size = 13.dp, tint = VoiidColor.textSecondary)
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (query.isEmpty()) {
                Text("Search members", style = VoiidFont.rounded(14),
                    color = VoiidColor.placeholder)
            }
            BasicTextField(
                value = query, onValueChange = onChange,
                textStyle = VoiidFont.rounded(14).copy(color = VoiidColor.textPrimary),
                cursorBrush = SolidColor(VoiidColor.accent),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun FilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val fill by animateColorAsState(
        if (selected) VoiidColor.accent else VoiidColor.surfaceCard,
        animationSpec = VoiidMotion.easeOut180(), label = "chipFill",
    )
    val textColor by animateColorAsState(
        if (selected) VoiidColor.textOnAccent else VoiidColor.textPrimary,
        animationSpec = VoiidMotion.easeOut180(), label = "chipText",
    )
    Box(
        Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(fill)
            .then(
                if (selected) Modifier
                else Modifier.border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.pill))
            )
            .pressableClickable(onClick = onClick)
            .padding(horizontal = 14.dp)
            .semantics { if (selected) contentDescription = "$label, selected" },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = textColor)
    }
}

@Composable
private fun MemberRow(
    member: CommunityService.Member,
    isAdmin: Boolean,
    pendingRequest: Boolean,
    busy: Boolean,
    onDecide: ((Boolean) -> Unit)? = null,
) {
    val haptics = LocalVoiidHaptics.current
    var menuOpen by remember { mutableStateOf(false) }
    val roleLabel = when {
        member.isOwner -> "Owner"
        member.isAdmin -> "Admin"
        else -> "Member"
    }

    Row(
        Modifier
            .fillMaxWidth()
            .height(62.dp)
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.md))
            .padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Keyed off the user id, because that is what the roster actually returns. NO online
        // dot: nothing in the schema records presence for a community member.
        CommunityAvatar(name = member.user_id, size = 40.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // The id, shortened. A display name would need UserDirectory to resolve it;
                // until it does, showing the id is honest where a fake name is not.
                Text(
                    member.user_id.take(8),
                    style = VoiidFont.rounded(14.5f, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (member.isAdmin) {
                    Pill(roleLabel, fill = VoiidColor.accent,
                        textColor = VoiidColor.textOnAccent, fontSize = 9.5f,
                        hPad = 6.dp, vPad = 2.dp)
                }
            }
            val joined = CommunityFeedDate.joinedMonth(member.joined_at)
            Text(
                if (joined.isEmpty()) "Joined —" else "Joined $joined",
                style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }

        when {
            pendingRequest && isAdmin -> Row(
                Modifier.alpha(if (busy) 0.5f else 1f),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                RequestAction("Decline", VoiidColor.textSecondary, !busy) { onDecide?.invoke(false) }
                RequestAction("Approve", VoiidColor.accentInk, !busy) { onDecide?.invoke(true) }
            }
            pendingRequest -> Pill("Waiting", fill = VoiidColor.accentTint,
                textColor = VoiidColor.accentInk)
            isAdmin -> Box {
                Box(
                    Modifier
                        .size(30.dp)
                        .pressableClickable { menuOpen = true }
                        .semantics { contentDescription = "Manage member" },
                    contentAlignment = Alignment.Center,
                ) {
                    CommunityGlyph(CommunityIcon.ELLIPSIS, size = 14.dp,
                        tint = VoiidColor.textSecondary)
                }
                CommunityMenu(menuOpen, { menuOpen = false }) {
                    // NO "Message" item. Joining a community is not a messaging right —
                    // reaching another member still takes one of the reachability paths.
                    CommunityMenuItem(
                        if (member.isAdmin) "Remove admin" else "Make admin",
                        CommunityIcon.ADMINS,
                    ) { menuOpen = false; haptics.tap() }
                    CommunityMenuDivider()
                    CommunityMenuItem("Remove from community", CommunityIcon.MINUS_CIRCLE,
                        destructive = true) { menuOpen = false; haptics.tap() }
                }
            }
        }
    }
}

@Composable
private fun RequestAction(title: String, tint: androidx.compose.ui.graphics.Color,
                          enabled: Boolean, onClick: () -> Unit) {
    Text(
        title,
        style = VoiidFont.rounded(12, FontWeight.SemiBold), color = tint,
        modifier = Modifier
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.fieldFill)
            .pressableClickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 9.dp, vertical = 5.dp),
    )
}

// ══════════════════════════════════════════════════════════════════════════════════
//  ABOUT
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
fun CommunityAboutTab(
    card: CommunityService.CommunityCard,
    isAdmin: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { CommunityService(context) }

    var links by remember { mutableStateOf<List<CommunityService.AboutLink>>(emptyList()) }
    var linksLoading by remember { mutableStateOf(true) }
    var linksError by remember { mutableStateOf<String?>(null) }
    var rules by remember { mutableStateOf<List<CommunityService.Rule>>(emptyList()) }
    var rulesLoading by remember { mutableStateOf(true) }
    var writeError by remember { mutableStateOf<String?>(null) }
    var deleteBusy by remember { mutableStateOf<Set<String>>(emptySet()) }
    var pendingDelete by remember { mutableStateOf<CommunityService.AboutLink?>(null) }

    LaunchedEffect(card.id) {
        linksLoading = true
        runCatching { svc.links(card.id) }
            .onSuccess { links = it; linksError = null }
            .onFailure { linksError = it.message ?: "Couldn't load links." }
        linksLoading = false
    }
    LaunchedEffect(card.id) {
        rulesLoading = true
        // A rules failure is silent: the section simply does not draw. Unlike the feed, an
        // absent rules list makes no false claim about the community.
        rules = runCatching { svc.rules(card.id) }.getOrDefault(emptyList())
        rulesLoading = false
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(VoiidSpacing.lg)) {
        // ── About ────────────────────────────────────────────────────────────────
        AboutSection("About") {
            card.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = VoiidFont.rounded(14),
                    color = VoiidColor.textPrimary.copy(alpha = 0.9f))
            }
            Row(
                Modifier.padding(top = VoiidSpacing.sm),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.lg),
            ) {
                AboutStat(card.member_count.toString(), "Members")
                AboutStat("@${card.handle}", "Handle")
                AboutStat(JoinPolicyOption.shortLabel(card.join_policy), "Joining")
            }
        }

        // ── Details ──────────────────────────────────────────────────────────────
        AboutSection("Details") {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.surfaceCard)
                    .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.md))
                    .padding(VoiidSpacing.md),
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                DetailRow("Handle", "@${card.handle}")
                DetailRow("Joining", JoinPolicyOption.shortLabel(card.join_policy))
                DetailRow("In search", if (card.discoverable) "Yes" else "No")
                DetailRow("Members", card.member_count.toString())
                if (card.suspended) DetailRow("Status", "Suspended")
            }
        }

        // ── Rules ────────────────────────────────────────────────────────────────
        // Drawn ONLY when the community actually has rules. iOS falls back to four sample
        // rules here ("Be useful, not loud"…), which every community displays as its own.
        // That is not ported: a community with no rules shows no rules.
        if (rules.isNotEmpty()) {
            AboutSection("Rules") {
                Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    rules.forEachIndexed { index, rule -> RuleCard(index + 1, rule) }
                }
            }
        }

        // ── Links ────────────────────────────────────────────────────────────────
        if (linksLoading || linksError != null || links.isNotEmpty() || isAdmin) {
            AboutSection("Links") {
                when {
                    linksLoading && links.isEmpty() -> CenteredSpinner()
                    linksError != null && links.isEmpty() ->
                        Emptyish(CommunityIcon.WARNING, linksError!!, "Pull down to try again.")
                    links.isEmpty() -> Text(
                        "No links yet. Add a website, an email address, or anything else " +
                            "people should be pointed at.",
                        style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary,
                    )
                    else -> LinkList(
                        links = links, isAdmin = isAdmin, deleteBusy = deleteBusy,
                        onRemove = { pendingDelete = it },
                    )
                }
                writeError?.let {
                    Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error)
                }
            }
        }

        // ── The encryption note, always last ─────────────────────────────────────
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.accentTint.copy(alpha = 0.5f))
                .padding(VoiidSpacing.md),
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            verticalAlignment = Alignment.Top,
        ) {
            CommunityGlyph(CommunityIcon.LOCK, size = 12.dp, tint = VoiidColor.accentInk)
            Text(
                "Messages inside a Space are end-to-end encrypted. The community itself — " +
                    "its name, members and invites — is not, so it can be searched and joined.",
                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            )
        }
    }

    pendingDelete?.let { link ->
        VoiidConfirmDialog(
            title = "Remove this link?",
            message = "“${link.title}” is removed from About. This cannot be undone.",
            confirmLabel = "Remove",
            destructive = true,
            onCancel = { pendingDelete = null },
            onConfirm = {
                pendingDelete = null
                if (!deleteBusy.contains(link.id)) scope.launch {
                    deleteBusy = deleteBusy + link.id
                    val index = links.indexOfFirst { it.id == link.id }
                    links = links.filterNot { it.id == link.id }
                    runCatching { svc.deleteLink(card.id, link.id) }
                        .onSuccess { haptics.success() }
                        .onFailure {
                            haptics.error()
                            val at = index.coerceIn(0, links.size)
                            links = links.toMutableList().apply { add(at, link) }
                            writeError = it.message ?: "Couldn't remove that link."
                        }
                    deleteBusy = deleteBusy - link.id
                }
            },
        )
    }
}

@Composable
private fun AboutSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = VoiidFont.rounded(17, FontWeight.Bold), color = VoiidColor.textPrimary)
        content()
    }
}

@Composable
private fun AboutStat(value: String, label: String) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(value, style = VoiidFont.rounded(16, FontWeight.Bold),
            color = VoiidColor.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(label, style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Spacer(Modifier.weight(1f).widthIn(min = VoiidSpacing.md))
        Text(value, style = VoiidFont.rounded(13, FontWeight.SemiBold),
            color = VoiidColor.textPrimary)
    }
}

@Composable
private fun RuleCard(number: Int, rule: CommunityService.Rule) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.md))
            .padding(10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            // Numbered by LIST POSITION, so reordering is a list operation and never a
            // renumbering chore.
            Modifier.size(24.dp).clip(CircleShape).background(VoiidColor.accentTint),
            contentAlignment = Alignment.Center,
        ) {
            Text(number.toString(), style = VoiidFont.rounded(12.5f, FontWeight.Bold),
                color = VoiidColor.accentInk)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(rule.text, style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.textPrimary)
            if (rule.explanation.isNotEmpty()) {
                Text(rule.explanation, style = VoiidFont.rounded(12.5f),
                    color = VoiidColor.textSecondary)
            }
        }
    }
}

@Composable
private fun LinkList(
    links: List<CommunityService.AboutLink>,
    isAdmin: Boolean,
    deleteBusy: Set<String>,
    onRemove: (CommunityService.AboutLink) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
    ) {
        links.forEachIndexed { index, link ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(54.dp)
                    .pressableClickable(enabled = !deleteBusy.contains(link.id)) { haptics.tap() }
                    .padding(horizontal = 14.dp)
                    .alpha(if (deleteBusy.contains(link.id)) 0.45f else 1f),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                    CommunityGlyph(CommunityIcon.LINK, size = 14.dp, tint = VoiidColor.accentInk)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(link.title, style = VoiidFont.rounded(13.5f, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                    // `value` is FREE TEXT, not necessarily a URL — a contact address and a
                    // "Room 4, Tuesdays" both live here — so it is never linkified.
                    Text(link.subtitle, style = VoiidFont.rounded(12),
                        color = VoiidColor.textSecondary, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                }
                if (isAdmin) {
                    Box(
                        Modifier
                            .size(width = 30.dp, height = 44.dp)
                            .pressableClickable { haptics.tap(); onRemove(link) }
                            .semantics { contentDescription = "Remove ${link.title}" },
                        contentAlignment = Alignment.Center,
                    ) {
                        CommunityGlyph(CommunityIcon.MINUS_CIRCLE, size = 15.dp,
                            tint = VoiidColor.error)
                    }
                } else {
                    CommunityGlyph(CommunityIcon.ARROW_UP_RIGHT, size = 11.dp,
                        tint = VoiidColor.textSecondary)
                }
            }
            // Between rows only, inset 32dp from the leading edge.
            if (index < links.size - 1) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .padding(start = VoiidSpacing.xl)
                        .height(1.dp)
                        .background(VoiidColor.divider)
                )
            }
        }
    }
}
