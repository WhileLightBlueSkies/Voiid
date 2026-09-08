package com.voiid.app.main.games

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.Grid3x3
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import kotlinx.coroutines.launch
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GamesService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * The Games tab — a 2-per-row grid of large artwork cards.
 *
 * WHY THE LIST IS SERVER-DRIVEN: the catalog lives in Postgres (`games`, seeded by
 * 024_games.sql) and carries an `enabled` flag, so a broken game can be pulled without an
 * app update. A hardcoded client list would make that impossible.
 *
 * ARTWORK: each row's `icon_key` maps to a drawable (`game_tictactoe`, `game_rps`). The
 * lookup is by NAME at runtime rather than a compile-time R reference, so adding a game is
 * a DB row plus a drop-in PNG — no client change. A game whose art hasn't shipped yet falls
 * back to a tinted glyph rather than an empty card, which is what makes that possible.
 *
 * ONE ENTRY POINT PER GAME: tapping a card asks who you're playing (friend or bot) in
 * GameSetupSheet. Practice is not a separate row, because it is the same game against a
 * different opponent — not a different thing.
 *
 * Mirrors iOS `GamesHomeView.swift`.
 */
@Composable
fun GamesHomeScreen(
    onPickGame: (GamesService.CatalogGame) -> Unit,
    onLeaderboard: () -> Unit,
    /** Today's seeded Snake arena (docs/games/CROSS_CUTTING.md §5). */
    onDaily: () -> Unit = {},
    onAcceptInvite: (GamesService.PendingInvite) -> Unit = {},
) {
    val context = LocalContext.current
    val service = remember { GamesService(ApiClient(TokenStore.get(context))) }

    var games by remember { mutableStateOf<List<GamesService.CatalogGame>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var loadFailed by remember { mutableStateOf(false) }
    var reloadToken by remember { mutableStateOf(0) }
    /** Sound + haptics sheet (docs/games/CROSS_CUTTING.md §12). */
    var showSettings by remember { mutableStateOf(false) }

    // Incoming invites. Polled rather than pushed: an invite arrives as a chat message, and the
    // games surface has no socket subscription of its own — a 20s poll while this tab is open is
    // cheaper than inventing a second delivery path for a banner.
    var invites by remember { mutableStateOf<List<GamesService.PendingInvite>>(emptyList()) }
    // Match ids the user has already acknowledged this session. A MISSED invite is information you
    // need once; without this, dismissing one would bring it straight back on the next poll.
    val dismissed = remember { mutableStateListOf<String>() }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(reloadToken) {
        loading = true
        loadFailed = false
        runCatching { service.catalog() }
            .onSuccess { games = it }
            .onFailure { loadFailed = true }
        loading = false
    }

    LaunchedEffect(Unit) {
        while (true) {
            runCatching { service.invites() }.onSuccess { invites = it }
            kotlinx.coroutines.delay(20_000)
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .padding(horizontal = VoiidSpacing.md),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Games",
                style = VoiidFont.rounded(28, FontWeight.Bold),
                color = VoiidColor.textPrimary,
                modifier = Modifier.weight(1f),
            )
            // Standings sit behind an icon: a reference you check occasionally, not a
            // thing you launch.
            Icon(
                Icons.Outlined.EmojiEvents,
                contentDescription = "Leaderboard",
                tint = VoiidColor.primary,
                modifier = Modifier
                    .minimumInteractiveComponentSize()
                    .clip(CircleShape)
                    .clickable { onLeaderboard() }
                    .padding(VoiidSpacing.sm),
            )
            // Sound and haptics. On the TAB rather than inside each match: it is a preference
            // about the games, not a control for the one you happen to be in, and a player who
            // wants silence wants it before the crowd starts.
            Icon(
                Icons.Outlined.Tune,
                contentDescription = "Game settings",
                tint = VoiidColor.textSecondary,
                modifier = Modifier
                    .minimumInteractiveComponentSize()
                    .clip(CircleShape)
                    .clickable { showSettings = true }
                    .padding(VoiidSpacing.sm),
            )
        }

        if (showSettings) {
            GameSettingsSheet(onDismiss = { showSettings = false })
        }

        // Invites sit ABOVE the catalog: an invitation is time-bound and someone is waiting on it,
        // which makes it more urgent than browsing.
        val visible = invites.filter { it.match_id !in dismissed }
        if (visible.isNotEmpty()) {
            Column(
                Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.sm),
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                visible.forEach { invite ->
                    InviteBanner(
                        invite = invite,
                        onAccept = { onAcceptInvite(invite) },
                        onDismiss = {
                            // Acknowledge locally at once so the banner goes immediately, then tell
                            // the server. A failed decline is harmless — it expires anyway.
                            dismissed.add(invite.match_id)
                            scope.launch { runCatching { service.decline(invite.match_id) } }
                        },
                    )
                }
            }
        }

        // BELOW invites, ABOVE the catalog — which is exactly its urgency. Someone waiting on an
        // invite beats it; browsing does not, because the daily expires at midnight and browsing
        // does not.
        Row(
            Modifier
                .fillMaxWidth()
                .padding(bottom = VoiidSpacing.sm)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .clickable { onDaily() }
                .padding(VoiidSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "Daily challenge",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
                Text(
                    "One Snake arena. Same for everyone. Resets at midnight.",
                    style = VoiidFont.rounded(12, FontWeight.Normal),
                    color = VoiidColor.textSecondary,
                )
            }
            Text(
                "›",
                style = VoiidFont.rounded(18, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
        }

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            when {
                loading -> CircularProgressIndicator(color = VoiidColor.primary)

                loadFailed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // An empty list and a failed fetch look identical to a user; say which.
                    Text(
                        "Couldn't load games",
                        style = VoiidFont.rounded(17, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                    )
                    Text(
                        "Try again",
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = VoiidColor.primary,
                        modifier = Modifier
                            .padding(top = VoiidSpacing.sm)
                            // A bare text link measured ~20dp tall — under the 48dp floor. This
                            // expands only the touch target, leaving the type where it is.
                            .minimumInteractiveComponentSize()
                            .clip(RoundedCornerShape(VoiidRadius.sm))
                            .clickable { reloadToken++ }
                            .padding(horizontal = VoiidSpacing.sm, vertical = VoiidSpacing.xs),
                    )
                }

                else -> LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    modifier = Modifier.fillMaxSize(),
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    contentPadding = PaddingValues(bottom = VoiidSpacing.xxl),
                ) {
                    items(games, key = { it.id }) { game ->
                        GameCard(game) { onPickGame(game) }
                    }
                }
            }
        }
    }
}

/**
 * One catalog row.
 *
 * ── AN UNPLAYABLE CARD IS NOT A DISABLED BUTTON ──────────────────────────────────
 * A disabled clickable still takes the tap, gives no reason, and leaves the user pressing
 * it again. A card that was never clickable cannot fail, and the badge is the whole
 * explanation — the same call `CommunitySettingsScreen` makes for unavailable join tiers.
 *
 * An ANNOUNCED game has no engine in any build; an out-of-date one has an engine the server
 * decided not to show. Neither opens anything, so neither is a control.
 *
 * Mirrors iOS `GameTile`.
 */
@Composable
private fun GameCard(game: GamesService.CatalogGame, onClick: () -> Unit) {
    val context = LocalContext.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val playable = game.availability == GamesService.Availability.PLAYABLE
    // Card dips under the finger and springs back — the same bouncy language as the board.
    // Only when there is something to press.
    val scale by animateFloatAsState(
        targetValue = if (pressed && playable) 0.96f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
        label = "press",
    )

    // Resolve artwork by NAME so a new game needs no client change (see the file header).
    val artId = remember(game.icon_key) {
        game.icon_key?.let {
            context.resources.getIdentifier(it, "drawable", context.packageName)
        } ?: 0
    }

    Column(
        Modifier
            .scale(scale)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .then(
                if (playable) {
                    Modifier.clickable(interactionSource = interaction, indication = null) {
                        onClick()
                    }
                } else {
                    Modifier.semantics {
                        contentDescription = "${game.name}, " +
                            if (game.availability == GamesService.Availability.ANNOUNCED)
                                "coming soon" else "requires an app update"
                    }
                }
            ),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                // 4:3 — the aspect the shipped artwork is authored at.
                .aspectRatio(4f / 3f)
                .background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            if (artId != 0) {
                // The artwork IS the title: the shipped art carries the game's name as a
                // lettering treatment, so the card shows no text of its own. A name label
                // under it read the title twice, and the scrim that used to sit here existed
                // only to keep that label legible — both are gone with it.
                Image(
                    painter = painterResource(artId),
                    contentDescription = game.name,
                    contentScale = ContentScale.Crop,
                    // Dimmed, not greyscaled: the art still has to read as THIS game's art,
                    // and a desaturated card beside five colour ones looks broken rather
                    // than pending.
                    modifier = Modifier.fillMaxSize().alpha(if (playable) 1f else 0.42f),
                )
            } else {
                // Art hasn't shipped for this game yet — a tinted glyph over its NAME, since
                // without artwork there is nothing else identifying the card.
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    Icon(
                        if (game.slug == "rps") Icons.Outlined.PanTool else Icons.Outlined.Grid3x3,
                        contentDescription = null,
                        tint = VoiidColor.primary,
                        modifier = Modifier.size(44.dp),
                    )
                    Text(
                        game.name,
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = if (playable) VoiidColor.textPrimary
                                else VoiidColor.textSecondary,
                        maxLines = 2,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = VoiidSpacing.sm),
                    )
                }
            }

            // ── THE STATE, ON THE CARD ──────────────────────────────────────────────
            // Top-left over the art, and it carries the reason as well as the badge: a
            // teaser line the server supplied ("Coming in October") beats an undated card,
            // which reads as abandoned the longer it sits there.
            if (!playable) {
                Column(
                    Modifier
                        .align(Alignment.TopStart)
                        .padding(VoiidSpacing.sm),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        if (game.availability == GamesService.Availability.ANNOUNCED) "SOON"
                        else "UPDATE",
                        style = VoiidFont.rounded(9.5f, FontWeight.Bold),
                        // All-caps at this size reads cramped without a positive bump —
                        // tracking is size-specific.
                        letterSpacing = 0.6.sp,
                        color = VoiidColor.textPrimary,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(VoiidColor.surfaceRaised.copy(alpha = 0.92f))
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                    )
                    val reason = when (game.availability) {
                        GamesService.Availability.ANNOUNCED -> game.teaser ?: "Coming soon"
                        else -> "Update Voiid to play"
                    }
                    Text(
                        reason,
                        style = VoiidFont.rounded(11f),
                        color = VoiidColor.textPrimary,
                        maxLines = 2,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(VoiidColor.surfaceRaised.copy(alpha = 0.85f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
        }
    }
}
