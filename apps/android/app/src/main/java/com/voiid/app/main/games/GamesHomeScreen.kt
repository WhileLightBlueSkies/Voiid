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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.Grid3x3
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GamesService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.theme.VoiidColor
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
) {
    val context = LocalContext.current
    val service = remember { GamesService(ApiClient(TokenStore.get(context))) }

    var games by remember { mutableStateOf<List<GamesService.CatalogGame>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var loadFailed by remember { mutableStateOf(false) }
    var reloadToken by remember { mutableStateOf(0) }

    LaunchedEffect(reloadToken) {
        loading = true
        loadFailed = false
        runCatching { service.catalog() }
            .onSuccess { games = it }
            .onFailure { loadFailed = true }
        loading = false
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
                color = VoiidColor.textPrimary,
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
            )
            // Standings sit behind an icon: a reference you check occasionally, not a
            // thing you launch.
            Icon(
                Icons.Outlined.EmojiEvents,
                contentDescription = "Leaderboard",
                tint = VoiidColor.primary,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable { onLeaderboard() }
                    .padding(VoiidSpacing.sm),
            )
        }

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            when {
                loading -> CircularProgressIndicator(color = VoiidColor.primary)

                loadFailed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // An empty list and a failed fetch look identical to a user; say which.
                    Text(
                        "Couldn't load games",
                        color = VoiidColor.textPrimary,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "Try again",
                        color = VoiidColor.primary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .padding(top = VoiidSpacing.sm)
                            .clickable { reloadToken++ },
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

@Composable
private fun GameCard(game: GamesService.CatalogGame, onClick: () -> Unit) {
    val context = LocalContext.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    // Card dips under the finger and springs back — the same bouncy language as the board.
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.96f else 1f,
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
            .clickable(interactionSource = interaction, indication = null) { onClick() },
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
                    modifier = Modifier.fillMaxSize(),
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
                        color = VoiidColor.textPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = VoiidSpacing.sm),
                    )
                }
            }
        }
    }
}
