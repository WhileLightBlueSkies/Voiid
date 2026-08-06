package com.voiid.app.main.clips

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipCount
import com.voiid.app.model.CreatorStore
import com.voiid.app.net.CreatorService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidStyledField
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * A creator's public page: header, follow button, and their grid of clips.
 * Mirrors iOS `CreatorProfileView.swift`.
 *
 * The grid is the SAME 3-column, 2dp-gutter, 9:16 layout as the Explore feed and My Clips,
 * reusing [ClipThumbnail]. That is deliberate and not up for redesign — it is the layout the
 * rest of Clips already uses, and a creator page that scrolled differently from the feed it
 * is reached from would read as a different app.
 *
 * ── NOT E2EE, AND A FOLLOW IS NOT A MESSAGING RIGHT ──────────────────────────────
 * Everything on this screen is public broadcast content. The Follow button grants the ability
 * to see clips that are already public to everyone and nothing else — it opens no
 * conversation, and there is deliberately no "Message" affordance here.
 */
@Composable
fun CreatorProfileView(
    handle: String,
    creators: CreatorStore,
    onBack: () -> Unit,
    onOpenClip: (Int) -> Unit = {},
) {
    val haptics = LocalVoiidHaptics.current
    val gridState = rememberLazyGridState()
    val profile = creators.cachedProfile(handle)
    val rows = creators.clipsFor(handle)
    var showEdit by remember { mutableStateOf(false) }

    LaunchedEffect(handle) {
        // Only fetch if not already cached — arriving from a feed tile usually means it is.
        if (creators.cachedProfile(handle) == null) creators.loadProfile(handle)
        if (creators.clipsFor(handle).isEmpty()) creators.refreshClips(handle)
    }

    // Page as the grid nears its end. Driven off the last visible index rather than a
    // per-item callback so a fast fling triggers one append, not thirty.
    LaunchedEffect(gridState, handle) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { creators.loadMoreClipsIfNeeded(handle, it) }
    }

    val entrance = rememberGridEntrance(ready = rows.isNotEmpty())

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(48.dp).softClickable(scale = 0.9f) { haptics.tap(); onBack() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack, "Back",
                    tint = VoiidColor.textPrimary, modifier = Modifier.size(24.dp),
                )
            }
            Text(
                "@${profile?.handle ?: handle}",
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
        }

        val slot = Modifier.fillMaxWidth().weight(1f)
        when {
            // The error state must win over the empty state: rendering "no clips yet" for a
            // failed request is a lie about someone else's page.
            profile == null && creators.profileError != null ->
                ClipsEmptyState(
                    kind = ClipsEmptyKind.Failed(creators.profileError!!),
                    onAction = { creators.loadProfile(handle) },
                    modifier = slot,
                )

            profile == null ->
                Box(slot, contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                }

            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                state = gridState,
                modifier = slot,
                verticalArrangement = Arrangement.spacedBy(2.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                item(span = { GridItemSpan(3) }) {
                    ProfileHeader(profile, creators, onEdit = { showEdit = true })
                }
                if (rows.isEmpty()) {
                    item(span = { GridItemSpan(3) }) {
                        Text(
                            if (profile.is_self) "You haven't posted a clip yet."
                            else "No clips yet.",
                            style = VoiidFont.rounded(15),
                            color = VoiidColor.textSecondary,
                            modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                        )
                    }
                }
                itemsIndexed(rows, key = { _, c -> c.id }) { index, clip ->
                    CreatorClipTile(
                        clip = clip,
                        modifier = Modifier.clipTileEntrance(index, entrance),
                        onTap = { haptics.tap(); onOpenClip(index) },
                    )
                }
                item(span = { GridItemSpan(3) }) { Spacer(Modifier.height(100.dp)) }
            }
        }
    }

    if (showEdit && profile != null) {
        CreatorEditSheet(
            profile = profile,
            creators = creators,
            onDismiss = { showEdit = false },
        )
    }
}

@Composable
private fun ProfileHeader(
    p: CreatorService.Profile,
    creators: CreatorStore,
    onEdit: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    var bioExpanded by remember(p.handle) { mutableStateOf(false) }

    Column(
        Modifier.fillMaxWidth().padding(VoiidSpacing.md),
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            GradientAvatar(p)
            // Counts sit beside the avatar rather than under the bio so the numbers stay
            // above the fold on a small phone.
            //
            // They are NOT tappable: Voiid has no follower-list screen, and a press style on
            // something that opens nothing promises a destination that does not exist.
            Row(
                Modifier.weight(1f).padding(start = VoiidSpacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Stat(ClipCount.compact(p.clip_count), "Clips", Modifier.weight(1f))
                StatDivider()
                Stat(ClipCount.compact(p.follower_count), "Followers", Modifier.weight(1f))
                StatDivider()
                Stat(ClipCount.compact(p.following_count), "Following", Modifier.weight(1f))
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    p.display_name ?: "@${p.handle}",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
                if (p.is_verified) {
                    Spacer(Modifier.width(4.dp))
                    VerifiedSeal()
                }
            }
            if (p.display_name != null) {
                Text("@${p.handle}", style = VoiidFont.rounded(13),
                    color = VoiidColor.textSecondary)
            }
            p.bio?.takeIf { it.isNotEmpty() }?.let { bio ->
                var clamped by remember(bio) { mutableStateOf(false) }
                Text(
                    bio,
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.textPrimary,
                    maxLines = if (bioExpanded) Int.MAX_VALUE else 3,
                    overflow = TextOverflow.Ellipsis,
                    // The expander appears only when there is genuinely more to read: a
                    // permanent "more" under a one-line bio is a control that does nothing.
                    onTextLayout = { if (!bioExpanded) clamped = it.hasVisualOverflow },
                )
                if (clamped && !bioExpanded) {
                    Text(
                        "more",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = VoiidColor.textSecondary,
                        modifier = Modifier.softClickable(scale = 0.95f) { bioExpanded = true },
                    )
                }
            }
            p.link_url?.takeIf { it.isNotEmpty() }?.let { link ->
                // Openable only when the string actually parses as a URL with a scheme — a
                // creator-supplied value is not guaranteed to be one, and handing
                // "instagram.com/me" to the system would throw rather than open a browser.
                // Mirrors the parse-before-Link guard on iOS.
                val target = runCatching { Uri.parse(link) }.getOrNull()
                    ?.takeIf { !it.scheme.isNullOrEmpty() }
                Text(
                    link,
                    style = VoiidFont.rounded(13, FontWeight.SemiBold),
                    color = if (target != null) VoiidColor.primary else VoiidColor.textSecondary,
                    maxLines = 1,
                    modifier = if (target != null) {
                        Modifier.softClickable(scale = 0.97f) {
                            haptics.tap()
                            runCatching { uriHandler.openUri(target.toString()) }
                        }
                    } else Modifier,
                )
            }
        }

        // Two-up rather than one full-width bar: on your own page the primary act is editing,
        // on someone else's it is following, and both pages still want a way to pass the
        // profile on. There is deliberately no Message button — see the header note.
        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
            if (p.is_self) {
                HeaderButton("Edit profile", Modifier.weight(1f)) { haptics.tap(); onEdit() }
            } else {
                FollowButton(p, creators, Modifier.weight(1f))
            }
            HeaderButton("Share profile", Modifier.weight(1f)) {
                haptics.tap()
                val text = "@${p.handle} on Voiid"
                runCatching {
                    context.startActivity(
                        Intent.createChooser(
                            Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                            },
                            null,
                        )
                    )
                }
            }
        }
    }
}

/**
 * 96dp avatar inside a gradient ring. The ring is what separates a creator page from every
 * other circular avatar in the app — the old bare circle read as a contact row, not as the
 * subject of the screen. Primary→accent so it belongs to the palette rather than importing
 * someone else's rainbow.
 */
@Composable
private fun GradientAvatar(p: CreatorService.Profile) {
    val ring = Brush.linearGradient(listOf(VoiidColor.primary, VoiidColor.accent))
    Box(
        Modifier
            .size(96.dp)
            .border(2.5.dp, ring, CircleShape)
            // 2.5 ring + 3 gap: the gap is what stops the ring reading as a hard outline
            // welded to the photo.
            .padding(5.5.dp),
        contentAlignment = Alignment.Center,
    ) {
        // ClipThumbnail already handles async load, failure and shimmer; a creator
        // avatar is the same problem (a presigned URL that may expire or 404).
        if (p.avatar_url != null) {
            ClipThumbnail(
                url = p.avatar_url,
                modifier = Modifier.fillMaxSize().clip(CircleShape),
            )
        } else {
            Box(
                Modifier.fillMaxSize().clip(CircleShape).background(VoiidColor.fieldFill),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    p.handle.take(1).uppercase(),
                    style = VoiidFont.rounded(34, FontWeight.SemiBold),
                    color = VoiidColor.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun Stat(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
        Text(label, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
    }
}

/** A hairline, not a gap: three numbers with nothing between them read as one number. */
@Composable
private fun StatDivider() {
    Box(Modifier.width(1.dp).height(24.dp).background(VoiidColor.divider))
}

/**
 * Follow / Following. Flips colour on a spring rather than cutting, because the state change
 * is the entire feedback for a request that has not actually come back from the server yet.
 */
@Composable
private fun FollowButton(
    p: CreatorService.Profile,
    creators: CreatorStore,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    val shape = RoundedCornerShape(VoiidRadius.md)
    val fill by animateColorAsState(
        targetValue = if (p.following) VoiidColor.fieldFill else VoiidColor.primary,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow),
        label = "followFill",
    )
    val label by animateColorAsState(
        targetValue = if (p.following) VoiidColor.textPrimary else VoiidColor.textOnPrimary,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow),
        label = "followLabel",
    )
    Box(
        modifier
            // 40dp of drawn height, but the tap target is the whole row height plus the
            // padding around it; see the 48dp frame on the parent Row's spacing.
            .height(44.dp)
            .clip(shape)
            .background(fill)
            .then(
                if (p.following) Modifier.border(1.dp, VoiidColor.fieldBorder, shape)
                else Modifier
            )
            .softClickable(scale = 0.98f) {
                // Success, not a tap: following someone is a completed act, and the double
                // pulse is what distinguishes it from the press feedback already fired.
                haptics.success()
                creators.toggleFollow(p.handle)
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (p.following) "Following" else "Follow",
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = label,
        )
    }
}

@Composable
private fun HeaderButton(
    title: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(VoiidRadius.md)
    Box(
        modifier
            .height(44.dp)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, shape)
            .softClickable(scale = 0.98f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
        )
    }
}

@Composable
private fun CreatorClipTile(
    clip: CreatorService.CreatorClipRow,
    modifier: Modifier = Modifier,
    onTap: () -> Unit,
) {
    Box(modifier.aspectRatio(9f / 16f).softClickable(scale = 0.98f, onClick = onTap)) {
        ClipThumbnail(url = clip.thumb_url, modifier = Modifier.fillMaxSize())
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.5f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.55f),
                    )
                )
        )
        Row(
            Modifier.align(Alignment.BottomStart).padding(6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Icon(Icons.Filled.Visibility, null, tint = Color.White, modifier = Modifier.size(10.dp))
            Text(
                ClipCount.compact(clip.view_count),
                style = VoiidFont.rounded(11, FontWeight.SemiBold),
                color = Color.White,
            )
        }
    }
}

// ── Edit sheet ────────────────────────────────────────────────────────────────────

/**
 * Edit your own creator profile — the Android half of what iOS ships as `CreatorEditSheet`.
 * Before this, an Android creator's own page offered nothing at all: no Edit affordance and
 * no sheet, so a display name or bio set at signup could never be changed from this device.
 *
 * THE HANDLE IS DELIBERATELY NOT SENT. This sheet does not edit it, and including it
 * unchanged would still be a no-op that risks burning the server's 30-day rename window if
 * the comparison there ever changed. Renaming belongs to its own flow.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreatorEditSheet(
    profile: CreatorService.Profile,
    creators: CreatorStore,
    onDismiss: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var displayName by remember { mutableStateOf(profile.display_name ?: "") }
    var bio by remember { mutableStateOf(profile.bio ?: "") }
    var link by remember { mutableStateOf(profile.link_url ?: "") }
    var saving by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = { if (!saving) onDismiss() },
        sheetState = sheetState,
        containerColor = VoiidColor.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VoiidSpacing.md)
                .padding(bottom = VoiidSpacing.lg)
                .imePadding()
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        ) {
            Text(
                "Edit profile",
                style = VoiidFont.rounded(24, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Text(
                "@${profile.handle}",
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
            )

            EditField("Display name", displayName) { displayName = it; errorText = null }
            EditField("Bio", bio, singleLine = false) { bio = it; errorText = null }
            EditField("Link", link) { link = it; errorText = null }

            errorText?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }

            Box(
                Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.primary)
                    .softClickable(enabled = !saving, scale = 0.98f) {
                        haptics.tap()
                        saving = true
                        errorText = null
                        scope.launch {
                            runCatching {
                                creators.updateProfile(
                                    displayName = displayName.trim(),
                                    bio = bio.trim(),
                                    linkUrl = link.trim(),
                                )
                            }
                                .onSuccess { haptics.success(); onDismiss() }
                                .onFailure {
                                    errorText = it.message ?: "Couldn't save that."
                                }
                            saving = false
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (saving) "Saving…" else "Save",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textOnPrimary,
                )
            }
        }
    }
}

@Composable
private fun EditField(
    label: String,
    value: String,
    singleLine: Boolean = true,
    onValueChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.xs)) {
        Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        VoiidStyledField(
            value = value,
            onValueChange = onValueChange,
            placeholder = "Optional",
            modifier = Modifier.fillMaxWidth(),
            horizontalPadding = VoiidSpacing.md,
            height = if (singleLine) 56.dp else 96.dp,
            singleLine = singleLine,
        )
    }
}
