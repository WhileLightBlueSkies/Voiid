package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/**
 * The community Home tab — the feed, the pinned announcement, and (for a host) the admin
 * dashboard. Port of iOS `CommunityHomeTab.swift`.
 *
 * ── TWO KINDS OF ERROR, KEPT APART ───────────────────────────────────────────────
 * A failed READ and a failed WRITE say different things and are never merged:
 *   [postsError] / [announcementError] / [statsError] / [queueError] mean "we couldn't show
 *   you this". A feed that failed to load MUST NOT draw as an empty feed — that tells the
 *   user their community has nothing in it, which is a lie the app has no way to take back.
 *   [writeError] means "your action did not happen". It is dismissible, because it is about
 *   one action that is now over rather than the state of the tab.
 *
 * ── EVERY WRITE IS GUARDED ───────────────────────────────────────────────────────
 * [likeBusy], [deleteBusy], [queueBusy] and [unpinBusy] hold the ids of writes in flight, so
 * a double tap cannot fire two requests against one row.
 *
 * ── THE ADMIN BLOCK IS GATED ON THE ROLE, NOT HIDDEN BEHIND A FLAG ───────────────
 * [isAdmin] decides whether the dashboard is composed at all, so there is no state in which
 * a member has the moderation queue in their tree.
 */
@Composable
fun CommunityHomeTab(
    communityId: String,
    isAdmin: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { CommunityService(context) }
    val myUserId = remember { TokenStore.get(context).userId }

    var posts by remember { mutableStateOf<List<CommunityService.Post>>(emptyList()) }
    var pinned by remember { mutableStateOf<CommunityService.Announcement?>(null) }
    var loading by remember { mutableStateOf(true) }
    var postsError by remember { mutableStateOf<String?>(null) }
    var announcementError by remember { mutableStateOf<String?>(null) }
    var writeError by remember { mutableStateOf<String?>(null) }
    var likeBusy by remember { mutableStateOf<Set<String>>(emptySet()) }
    var deleteBusy by remember { mutableStateOf<Set<String>>(emptySet()) }
    var unpinBusy by remember { mutableStateOf(false) }

    var stats by remember { mutableStateOf<CommunityService.Stats?>(null) }
    var queue by remember { mutableStateOf<List<CommunityService.QueueItem>>(emptyList()) }
    var adminLoading by remember { mutableStateOf(false) }
    var statsError by remember { mutableStateOf<String?>(null) }
    var queueError by remember { mutableStateOf<String?>(null) }
    var queueBusy by remember { mutableStateOf<Set<String>>(emptySet()) }

    var pendingDelete by remember { mutableStateOf<CommunityService.Post?>(null) }

    suspend fun fetchStats() {
        runCatching { svc.stats(communityId) }
            .onSuccess { stats = it; statsError = null }
            // Stale numbers are DISCARDED rather than left on screen looking current.
            .onFailure { stats = null; statsError = it.message ?: "Couldn't load these numbers." }
    }

    suspend fun fetchQueue() {
        runCatching { svc.moderationQueue(communityId) }
            .onSuccess { queue = it; queueError = null }
            .onFailure { queue = emptyList(); queueError = it.message ?: "Couldn't load what needs you." }
    }

    suspend fun load() {
        loading = true
        coroutineScope {
            val p = async {
                runCatching { svc.posts(communityId).posts }
                    .onSuccess { posts = it; postsError = null }
                    .onFailure { postsError = it.message ?: "Couldn't load posts." }
            }
            val a = async {
                runCatching { svc.announcement(communityId) }
                    .onSuccess { pinned = it; announcementError = null }
                    .onFailure { announcementError = it.message ?: "Couldn't load the announcement." }
            }
            val admin = if (isAdmin) async {
                adminLoading = true
                coroutineScope { launch { fetchStats() }; launch { fetchQueue() } }
                adminLoading = false
            } else null
            p.await(); a.await(); admin?.await()
        }
        loading = false
    }

    LaunchedEffect(communityId) { load() }

    /** Author or manager, mirroring the route's own rule. */
    fun canDelete(post: CommunityService.Post): Boolean =
        isAdmin || (myUserId != null && post.author_id != null && myUserId == post.author_id)

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
        // An admin opening Home wants to know what needs them; a member wants the feed.
        if (isAdmin) {
            AdminDashboard(
                stats = stats, queue = queue, adminLoading = adminLoading,
                statsError = statsError, queueError = queueError, queueBusy = queueBusy,
                onResolve = { item, approve ->
                    if (queueBusy.contains(item.id)) return@AdminDashboard
                    val kind = item.resolvedKind ?: return@AdminDashboard
                    scope.launch {
                        queueBusy = queueBusy + item.id
                        val result: Result<Unit> = runCatching {
                            val isJoin = kind == CommunityService.QueueItem.Kind.JOIN_REQUEST
                            if (isJoin) {
                                // A join request with no user id is a malformed row; there is
                                // nothing to approve, so it is dropped rather than guessed at.
                                val userId = item.user_id
                                if (userId != null) {
                                    if (approve) svc.approveMember(communityId, userId)
                                    else svc.removeMember(communityId, userId)
                                }
                            } else if (approve) {
                                // "Keep this post" is a LOCAL dismissal with no route behind
                                // it — the row clears now and comes back on the next refresh
                                // if the report is still open. Deliberately not a call.
                                haptics.tap()
                            } else {
                                val postId = item.post_id
                                if (postId != null) {
                                    svc.deletePost(communityId, postId)
                                    posts = posts.filterNot { it.id == postId }
                                }
                            }
                        }
                        result
                            .onSuccess {
                                queue = queue.filterNot { it.id == item.id }
                                fetchStats()   // refetch, never a local decrement
                                haptics.success()
                            }
                            // The row STAYS on failure. A queue row that vanishes without the
                            // write landing is a moderation action the host thinks they took.
                            .onFailure {
                                haptics.error()
                                queueError = it.message ?: "Couldn't do that. Try again."
                            }
                        queueBusy = queueBusy - item.id
                    }
                },
            )
        }

        AnnouncementSlot(
            pinned = pinned, isAdmin = isAdmin, loading = loading,
            announcementError = announcementError, unpinBusy = unpinBusy,
            onUnpin = {
                val current = pinned ?: return@AnnouncementSlot
                scope.launch {
                    unpinBusy = true
                    pinned = null                                   // optimistic
                    runCatching { svc.unpinAnnouncement(communityId, current.id) }
                        .onSuccess { haptics.success() }
                        .onFailure {
                            haptics.error()
                            pinned = current                        // restore
                            writeError = it.message ?: "Couldn't unpin that announcement."
                        }
                    unpinBusy = false
                }
            },
        )

        ComposeBar(onClick = { haptics.tap() })

        writeError?.let { message ->
            WriteErrorBanner(message = message, onDismiss = { writeError = null })
        }

        Feed(
            posts = posts, loading = loading, postsError = postsError, isAdmin = isAdmin,
            deleteBusy = deleteBusy,
            canDelete = ::canDelete,
            onDelete = { pendingDelete = it },
            onLike = { post ->
                if (likeBusy.contains(post.id)) return@Feed
                scope.launch {
                    likeBusy = likeBusy + post.id
                    val wasLiked = post.isLiked
                    val wasCount = post.likes
                    // Optimistic flip, then OVERWRITE with the server's authoritative count —
                    // two devices liking at once would otherwise drift and never reconcile.
                    posts = posts.map {
                        if (it.id == post.id) it.copy(
                            liked_by_me = !wasLiked,
                            like_count = (if (wasLiked) wasCount - 1 else wasCount + 1).coerceAtLeast(0),
                        ) else it
                    }
                    runCatching {
                        if (wasLiked) svc.unlikePost(communityId, post.id)
                        else svc.likePost(communityId, post.id)
                    }.onSuccess { r ->
                        posts = posts.map {
                            if (it.id == post.id) it.copy(
                                liked_by_me = r.liked ?: !wasLiked, like_count = r.count,
                            ) else it
                        }
                    }.onFailure {
                        posts = posts.map {
                            if (it.id == post.id) it.copy(liked_by_me = wasLiked, like_count = wasCount)
                            else it
                        }
                    }
                    likeBusy = likeBusy - post.id
                }
            },
        )
    }

    pendingDelete?.let { post ->
        VoiidConfirmDialog(
            title = "Delete this post?",
            message = "It is removed from the feed. Community moderators can still see that " +
                "it existed and who removed it.",
            confirmLabel = "Delete",
            destructive = true,
            onCancel = { pendingDelete = null },
            onConfirm = {
                pendingDelete = null
                if (!deleteBusy.contains(post.id)) scope.launch {
                    deleteBusy = deleteBusy + post.id
                    val index = posts.indexOfFirst { it.id == post.id }
                    posts = posts.filterNot { it.id == post.id }    // optimistic
                    runCatching { svc.deletePost(communityId, post.id) }
                        .onSuccess { haptics.success() }
                        .onFailure {
                            haptics.error()
                            // Back where it was, not at the top — the feed is chronological
                            // and a restored post appearing first would misdate itself.
                            val at = index.coerceIn(0, posts.size)
                            posts = posts.toMutableList().apply { add(at, post) }
                            writeError = it.message ?: "Couldn't delete that post."
                        }
                    deleteBusy = deleteBusy - post.id
                }
            },
        )
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  THE COMPOSE BAR
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun ComposeBar(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
            .pressableClickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp)
            .semantics { contentDescription = "Write a post" },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The literal "You" — so the gradient and initial are stable for every user rather
        // than shifting with their display name.
        CommunityAvatar(name = "You", size = 32.dp)
        Text(
            "Share something…",
            style = VoiidFont.rounded(14), color = VoiidColor.placeholder,
        )
        Spacer(Modifier.weight(1f))
        Box(
            Modifier.size(30.dp).clip(CircleShape).background(VoiidColor.accent),
            contentAlignment = Alignment.Center,
        ) {
            CommunityGlyph(CommunityIcon.COMPOSE, size = 13.dp, tint = VoiidColor.textOnAccent)
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  THE WRITE-ERROR BANNER
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun WriteErrorBanner(message: String, onDismiss: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.error.copy(alpha = 0.10f))
            .border(1.dp, VoiidColor.error.copy(alpha = 0.35f), RoundedCornerShape(VoiidRadius.md))
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        verticalAlignment = Alignment.Top,
    ) {
        CommunityGlyph(CommunityIcon.WARNING_FILL, size = 13.dp, tint = VoiidColor.error)
        Text(
            message,
            style = VoiidFont.rounded(12.5f), color = VoiidColor.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Box(
            Modifier
                .size(20.dp)
                .pressableClickable(onClick = onDismiss)
                .semantics { contentDescription = "Dismiss" },
            contentAlignment = Alignment.Center,
        ) {
            CommunityGlyph(CommunityIcon.CLOSE, size = 11.dp, tint = VoiidColor.textSecondary)
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  THE ADMIN DASHBOARD
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun AdminDashboard(
    stats: CommunityService.Stats?,
    queue: List<CommunityService.QueueItem>,
    adminLoading: Boolean,
    statsError: String?,
    queueError: String?,
    queueBusy: Set<String>,
    onResolve: (CommunityService.QueueItem, Boolean) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.sm),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Admin overview", style = VoiidFont.rounded(15, FontWeight.Bold),
                color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Pill("Host", fill = VoiidColor.accent, textColor = VoiidColor.textOnAccent,
                fontSize = 10f, hPad = 7.dp, vPad = 3.dp)
        }

        when {
            stats != null -> {
                // Three cards, two per row. There is deliberately NO "Active today" card:
                // nothing in the schema records a per-user last-seen, so the number is not
                // computable and every way of faking it looks precise and is wrong.
                val cards = listOf(
                    Triple("Members", stats.memberCount.toString(), CommunityIcon.MEMBERS to true),
                    Triple("Posts", stats.postCount.toString(), CommunityIcon.COMPOSE to true),
                    Triple("Needs review", stats.openReports.toString(), CommunityIcon.WARNING_FILL to false),
                )
                Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    cards.chunked(2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            row.forEach { (label, value, iconPositive) ->
                                StatCard(label, value, iconPositive.first, iconPositive.second,
                                    Modifier.weight(1f))
                            }
                            // Keeps a lone third card at half width instead of stretching it.
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
            statsError != null -> Emptyish(CommunityIcon.WARNING, statsError, "Pull down to try again.")
            adminLoading -> CenteredSpinner(vertical = VoiidSpacing.md)
        }

        if (queueError != null) {
            Row(Modifier.padding(top = VoiidSpacing.sm), verticalAlignment = Alignment.CenterVertically) {
                Text("Needs you", style = VoiidFont.rounded(15, FontWeight.Bold),
                    color = VoiidColor.textPrimary)
            }
            Emptyish(CommunityIcon.WARNING, queueError, "Pull down to try again.")
        } else if (queue.isNotEmpty()) {
            Row(
                Modifier.padding(top = VoiidSpacing.sm),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Needs you", style = VoiidFont.rounded(15, FontWeight.Bold),
                    color = VoiidColor.textPrimary)
                CountBadge(queue.size)
            }
            Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                queue.forEach { item -> QueueRow(item, queueBusy.contains(item.id), onResolve) }
            }
        }
        // An empty, error-free queue renders NOTHING — no "all clear" card.
    }
}

@Composable
private fun StatCard(
    label: String, value: String, icon: CommunityIcon, isPositive: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.md))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.xs),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CommunityGlyph(icon, size = 12.dp,
                tint = if (isPositive) VoiidColor.accentInk else VoiidColor.warning)
            Text(label, style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary)
        }
        Text(
            value,
            // Tabular figures, so a changing count does not shift the card's width.
            style = VoiidFont.rounded(21, FontWeight.Bold).copy(fontFeatureSettings = "tnum"),
            color = VoiidColor.textPrimary,
        )
    }
}

@Composable
private fun QueueRow(
    item: CommunityService.QueueItem,
    busy: Boolean,
    onResolve: (CommunityService.QueueItem, Boolean) -> Unit,
) {
    val isReport = item.resolvedKind == CommunityService.QueueItem.Kind.REPORTED_POST
    val detail = queueDetail(item)
    Row(
        Modifier
            .fillMaxWidth()
            .height(58.dp)
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.md))
            .padding(horizontal = 10.dp)
            .alpha(if (busy) 0.45f else 1f)
            .semantics {
                contentDescription =
                    "${if (isReport) "Reported post" else "Join request"}: ${item.name}, $detail"
            },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    if (isReport) VoiidColor.warning.copy(alpha = 0.14f) else VoiidColor.accentTint
                ),
            contentAlignment = Alignment.Center,
        ) {
            CommunityGlyph(
                if (isReport) CommunityIcon.FLAG else CommunityIcon.PERSON_ADD,
                size = 13.dp,
                tint = if (isReport) VoiidColor.warning else VoiidColor.accentInk,
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(item.name, style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(CommunityFeedDate.age(item.at), style = VoiidFont.rounded(10.5f),
            color = VoiidColor.textSecondary)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            CircleAction(
                icon = CommunityIcon.CHECK, tint = VoiidColor.textOnAccent,
                background = VoiidColor.accent, enabled = !busy,
                label = if (isReport) "Keep this post" else "Approve",
                onClick = { onResolve(item, true) },
            )
            CircleAction(
                icon = CommunityIcon.CLOSE, tint = VoiidColor.textSecondary,
                background = VoiidColor.surfaceRaised, enabled = !busy,
                label = if (isReport) "Remove this post" else "Reject",
                onClick = { onResolve(item, false) },
            )
        }
    }
}

/** Exact strings from iOS `taskDetail`. The separator is U+00B7 with spaces. */
private fun queueDetail(item: CommunityService.QueueItem): String =
    when (item.resolvedKind) {
        CommunityService.QueueItem.Kind.JOIN_REQUEST ->
            if (!item.username.isNullOrEmpty()) "Wants to join · @${item.username}" else "Wants to join"
        CommunityService.QueueItem.Kind.REPORTED_POST -> {
            val n = item.reporter_count ?: 0
            val who = if (n == 1) "1 member reported this" else "$n members reported this"
            val excerpt = item.detail?.trim().orEmpty()
            if (excerpt.isNotEmpty()) "$who · $excerpt" else who
        }
        null -> "Needs review"
    }

// ══════════════════════════════════════════════════════════════════════════════════
//  THE PINNED ANNOUNCEMENT
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun AnnouncementSlot(
    pinned: CommunityService.Announcement?,
    isAdmin: Boolean,
    loading: Boolean,
    announcementError: String?,
    unpinBusy: Boolean,
    onUnpin: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    when {
        pinned != null -> {
            Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                AnnouncementCard(pinned)
                if (isAdmin) {
                    Row(
                        Modifier.alpha(if (unpinBusy) 0.5f else 1f),
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    ) {
                        AnnouncementControl("Replace", CommunityIcon.REPLACE, !unpinBusy) {
                            haptics.tap()
                        }
                        AnnouncementControl("Unpin", CommunityIcon.PIN_SLASH, !unpinBusy) {
                            haptics.tap(); onUnpin()
                        }
                    }
                }
            }
        }
        announcementError != null && !loading ->
            Emptyish(CommunityIcon.WARNING, announcementError, "Pull down to try again.")
        isAdmin && !loading -> PinAnnouncementSlot { haptics.tap() }
        // A member with no announcement sees no element at all.
    }
}

@Composable
private fun AnnouncementCard(pinned: CommunityService.Announcement) {
    val haptics = LocalVoiidHaptics.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
            .pressableClickable { haptics.tap() }
            .padding(VoiidSpacing.md),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CommunityGlyph(CommunityIcon.PIN_FILL, size = 10.dp, tint = VoiidColor.accentInk)
                Text("Pinned Announcement", style = VoiidFont.rounded(12, FontWeight.SemiBold),
                    color = VoiidColor.accentInk)
            }
            Text(pinned.headline, style = VoiidFont.rounded(14.5f, FontWeight.SemiBold),
                color = VoiidColor.textPrimary)
            Text(pinned.text, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            Text(
                "By ${pinned.displayName} · ${CommunityFeedDate.age(pinned.pinned_at)}",
                style = VoiidFont.rounded(11.5f),
                color = VoiidColor.textSecondary.copy(alpha = 0.8f),
                modifier = Modifier.padding(top = 1.dp),
            )
        }
        CommunityGlyph(CommunityIcon.CHEVRON_RIGHT, size = 12.dp, tint = VoiidColor.textSecondary,
            modifier = Modifier.padding(top = 2.dp))
    }
}

@Composable
private fun AnnouncementControl(
    title: String, icon: CommunityIcon, enabled: Boolean, onClick: () -> Unit,
) {
    Row(
        Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.pill))
            .pressableClickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 13.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommunityGlyph(icon, size = 11.dp, tint = VoiidColor.accentInk)
        Text(title, style = VoiidFont.rounded(12.5f, FontWeight.SemiBold), color = VoiidColor.accentInk)
    }
}

@Composable
private fun PinAnnouncementSlot(onClick: () -> Unit) {
    val shape = RoundedCornerShape(VoiidRadius.lg)
    val dividerColor = VoiidColor.divider
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(VoiidColor.surfaceCard)
            // A DASHED border — 1dp, 5 on / 4 off, drawn inside the bounds like
            // SwiftUI's `strokeBorder`. Compose's `border()` cannot dash, hence drawBehind.
            .drawBehind {
                val stroke = 1.dp.toPx()
                val r = VoiidRadius.lg.toPx()
                drawRoundRect(
                    color = dividerColor,
                    topLeft = Offset(stroke / 2, stroke / 2),
                    size = androidx.compose.ui.geometry.Size(
                        size.width - stroke, size.height - stroke,
                    ),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(r, r),
                    style = Stroke(
                        width = stroke,
                        pathEffect = PathEffect.dashPathEffect(
                            floatArrayOf(5.dp.toPx(), 4.dp.toPx())
                        ),
                    ),
                )
            }
            .pressableClickable(onClick = onClick)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(34.dp).clip(CircleShape).background(VoiidColor.accentTint),
            contentAlignment = Alignment.Center,
        ) {
            CommunityGlyph(CommunityIcon.PIN, size = 14.dp, tint = VoiidColor.accentInk)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text("Pin an announcement", style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.textPrimary)
            Text("It sits at the top of Home for everyone.",
                style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary)
        }
        CommunityGlyph(CommunityIcon.PLUS, size = 12.dp, tint = VoiidColor.textSecondary)
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  THE FEED
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun Feed(
    posts: List<CommunityService.Post>,
    loading: Boolean,
    postsError: String?,
    isAdmin: Boolean,
    deleteBusy: Set<String>,
    canDelete: (CommunityService.Post) -> Boolean,
    onDelete: (CommunityService.Post) -> Unit,
    onLike: (CommunityService.Post) -> Unit,
) {
    when {
        loading && posts.isEmpty() -> CenteredSpinner(vertical = VoiidSpacing.lg)
        postsError != null && posts.isEmpty() ->
            Emptyish(CommunityIcon.WARNING, postsError, "Pull down to try again.")
        posts.isEmpty() -> Emptyish(
            CommunityIcon.COMPOSE, "No posts yet",
            if (isAdmin) "Post something to get the feed started."
            else "Nothing has been posted here yet.",
        )
        else -> Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
            posts.forEach { post ->
                CommunityPostCard(
                    post = post,
                    busy = deleteBusy.contains(post.id),
                    // NULL hides the menu item entirely rather than disabling it, so a
                    // member never sees a Delete they cannot use.
                    onDelete = if (canDelete(post)) ({ onDelete(post) }) else null,
                    onLike = { onLike(post) },
                )
            }
        }
    }
}

@Composable
private fun CommunityPostCard(
    post: CommunityService.Post,
    busy: Boolean,
    onDelete: (() -> Unit)?,
    onLike: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    var menuOpen by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
            .padding(VoiidSpacing.md)
            .alpha(if (busy) 0.45f else 1f),
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CommunityAvatar(name = post.displayName, size = 32.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(post.displayName, style = VoiidFont.rounded(14, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary)
                Text(CommunityFeedDate.age(post.created_at),
                    style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary)
            }
            Box {
                Box(
                    Modifier
                        .size(28.dp)
                        .pressableClickable(enabled = !busy) { menuOpen = true }
                        .semantics { contentDescription = "Post options" },
                    contentAlignment = Alignment.Center,
                ) {
                    CommunityGlyph(CommunityIcon.ELLIPSIS, size = 14.dp,
                        tint = VoiidColor.textSecondary)
                }
                CommunityMenu(expanded = menuOpen, onDismiss = { menuOpen = false }) {
                    CommunityMenuItem("Save post", CommunityIcon.BOOKMARK) {
                        menuOpen = false; haptics.tap()
                    }
                    CommunityMenuItem("Share", CommunityIcon.SHARE) {
                        menuOpen = false; haptics.tap()
                    }
                    CommunityMenuItem("Report", CommunityIcon.WARNING, destructive = true) {
                        menuOpen = false; haptics.tap()
                    }
                    if (onDelete != null) {
                        CommunityMenuDivider()
                        CommunityMenuItem("Delete post", CommunityIcon.TRASH, destructive = true) {
                            menuOpen = false; haptics.tap(); onDelete()
                        }
                    }
                }
            }
        }

        Text(post.text, style = VoiidFont.rounded(14.5f), color = VoiidColor.textPrimary)

        post.media_url?.takeIf { it.isNotEmpty() }?.let {
            // The gradient is a PLACEHOLDER THAT STAYS BEHIND the image, so the card never
            // reflows while it loads. Its two stops hash off different strings, matching iOS.
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(172.dp)
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(
                        Brush.linearGradient(
                            listOf(
                                AvatarPalette.colorFor(post.id),
                                AvatarPalette.colorFor(post.displayName).copy(alpha = 0.6f),
                            ),
                            start = Offset.Zero, end = Offset.Infinite,
                        )
                    )
            )
        }

        Row(
            Modifier.padding(top = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.lg),
        ) {
            PostAction(
                icon = if (post.isLiked) CommunityIcon.HEART_FILL else CommunityIcon.HEART,
                label = post.likes.toString(),
                tint = if (post.isLiked) VoiidColor.accent else VoiidColor.textSecondary,
                enabled = !busy,
                onClick = onLike,
            )
            PostAction(CommunityIcon.COMMENT, post.comments.toString(),
                VoiidColor.textSecondary, !busy) { haptics.tap() }
            PostAction(CommunityIcon.SHARE, "Share",
                VoiidColor.textSecondary, !busy) { haptics.tap() }
        }
    }
}

@Composable
private fun PostAction(
    icon: CommunityIcon, label: String, tint: Color, enabled: Boolean, onClick: () -> Unit,
) {
    Row(
        Modifier.pressableClickable(enabled = enabled, onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommunityGlyph(icon, size = 13.5.dp, tint = tint)
        Text(label, style = VoiidFont.rounded(12.5f), color = tint)
    }
}
