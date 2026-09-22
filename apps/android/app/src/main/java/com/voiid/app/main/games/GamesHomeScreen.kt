package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Gesture
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.QuestionMark
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GamesService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * One action in the Games header, styled exactly as Communities styles its create button:
 * a 40dp circle of [VoiidColor.fieldFill] around an accent glyph. The filled circle is the
 * whole point — a bare icon gives no indication of where the tap target ends.
 */
@Composable
private fun HeaderAction(icon: ImageVector, label: String, onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Box(
        Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.fieldFill)
            .softClickable { haptics.tap(); onClick() },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, tint = VoiidColor.primary) }
}

/**
 * The Games arcade tab: 1-screen, fast entry, hero playable games, and honest upcoming games.
 * Parity twin of iOS GamesScreen.swift in Voiid Ui.
 */
@Composable
fun GamesHomeScreen(
    /** Opening a Social Profile by handle. The root owns the destination. */
    onOpenProfile: (String) -> Unit = {},
    onPickGame: (GamesService.CatalogGame) -> Unit,
    onLeaderboard: () -> Unit,
    onDaily: () -> Unit = {},
    onAcceptInvite: (GamesService.PendingInvite) -> Unit = {},
) {
    val context = LocalContext.current
    var category by remember { mutableStateOf("All") }
    val service = remember { GamesService(ApiClient(TokenStore.get(context))) }

    var games by remember { mutableStateOf<List<GamesService.CatalogGame>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }

    var invites by remember { mutableStateOf<List<GamesService.PendingInvite>>(emptyList()) }
    val dismissed = remember { mutableStateListOf<String>() }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(Unit) {
        runCatching { service.catalog() }.onSuccess { games = it }
        while (true) {
            runCatching { service.invites() }.onSuccess { invites = it }
            kotlinx.coroutines.delay(20_000)
        }
    }

    if (showSettings) {
        GameSettingsSheet(onDismiss = { showSettings = false })
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 96.dp),
    ) {
        // MARK: Header
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = VoiidSpacing.md)
                .padding(top = VoiidSpacing.sm),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Sized and weighted to match Communities — the two tabs sit next to each
                // other in the same bar, so a 32sp title on one and 22sp on the other read
                // as two different apps.
                Text(
                    "Games",
                    style = VoiidFont.rounded(22, FontWeight.Bold),
                    color = VoiidColor.textPrimary,
                )
                Spacer(Modifier.weight(1f))
                // Communities' header treatment: each action is a 40dp filled circle, not a
                // bare glyph, so the tap target is visible before it is touched.
                HeaderAction(Icons.Outlined.EmojiEvents, "Leaderboard", onLeaderboard)
                HeaderAction(Icons.Outlined.Tune, "Game settings") { showSettings = true }

                // The same identity, in the same corner, as Clips and Communities.
                com.voiid.app.main.clips.SocialProfileButton(
                    creators = androidx.lifecycle.viewmodel.compose.viewModel(),
                    onOpen = onOpenProfile,
                )
            }

            // Continue last played
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.surfaceCard)
                    .clickable {
                        val target = games.firstOrNull { it.slug == "ludo" }
                            ?: GamesService.CatalogGame("ludo", "ludo", "Ludo", "Board", 1, 4)
                        onPickGame(target)
                    }
                    .padding(VoiidSpacing.sm + 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm + 2.dp),
            ) {
                Box(
                    Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.primary),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Refresh,
                        contentDescription = null,
                        tint = VoiidColor.textOnPrimary,
                        modifier = Modifier.size(16.dp),
                    )
                }

                Column(Modifier.weight(1f)) {
                    Text(
                        "Continue Ludo",
                        style = VoiidFont.rounded(14, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                    )
                    Text(
                        "Yesterday",
                        style = VoiidFont.rounded(11, FontWeight.Normal),
                        color = VoiidColor.textSecondary,
                    )
                }

                Icon(
                    Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = VoiidColor.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        // Active Invites if any
        val visibleInvites = invites.filter { it.match_id !in dismissed }
        if (visibleInvites.isNotEmpty()) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = VoiidSpacing.md)
                    .padding(top = VoiidSpacing.md),
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                visibleInvites.forEach { invite ->
                    InviteBanner(
                        invite = invite,
                        onAccept = { onAcceptInvite(invite) },
                        onDismiss = {
                            dismissed.add(invite.match_id)
                            scope.launch { runCatching { service.decline(invite.match_id) } }
                        },
                    )
                }
            }
        }

        Spacer(Modifier.height(VoiidSpacing.lg))

        // MARK: Play section
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = VoiidSpacing.md),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm + 4.dp),
        ) {
            Text(
                "Play",
                style = VoiidFont.rounded(18, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("All", "Board", "Arcade").forEach { label ->
                    androidx.compose.material3.FilterChip(selected = category == label, onClick = { category = label }, label = {
                        Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textPrimary)
                    })
                }
            }
            // Ludo Card
            if (category != "Arcade") HeroGameCard(
                title = "Ludo",
                pitch = "Roll a six to leave home. First to get all four in wins.",
                players = "1–4",
                duration = "10–20 min",
                artwork = com.voiid.app.R.drawable.game_ludo_home,
                icon = Icons.Default.Casino,
                gradient = Brush.linearGradient(
                    listOf(Color(0xFF13828C), Color(0xFF68B8BD))
                ),
                onClick = {
                    val target = games.firstOrNull { it.slug == "ludo" }
                        ?: GamesService.CatalogGame("ludo", "ludo", "Ludo", "Board", 1, 4)
                    onPickGame(target)
                },
            )

            // Snake Card
            if (category != "Board") HeroGameCard(
                title = "Snake Arena",
                pitch = "Eat, grow, and cut off anyone bigger than you.",
                players = "You + 11 bots",
                duration = "3–8 min",
                artwork = com.voiid.app.R.drawable.game_snake_home,
                icon = Icons.Default.Gesture,
                gradient = Brush.linearGradient(
                    listOf(Color(0xFF2FA36B), Color(0xFFE8A72E))
                ),
                onClick = {
                    val target = games.firstOrNull { it.slug == "snake" }
                        ?: GamesService.CatalogGame("snake", "snake", "Snake Arena", "Arcade", 1, 12)
                    onPickGame(target)
                },
            )
        }

        Spacer(Modifier.height(VoiidSpacing.xl))

        // MARK: Coming soon section
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = VoiidSpacing.md),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Text(
                "Coming soon",
                style = VoiidFont.rounded(18, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )

            ComingSoonRow(
                title = "Word Duel",
                pitch = "Two players, one board, seven letters.",
                icon = Icons.Outlined.TextFields,
                tint = Color(0xFF3B7DD8),
            )

            ComingSoonRow(
                title = "Carrom",
                pitch = "Flick, pocket, repeat.",
                icon = Icons.Outlined.SportsEsports,
                tint = Color(0xFFE8A72E),
            )

            ComingSoonRow(
                title = "Quiz Night",
                pitch = "Ten questions, everyone at once.",
                icon = Icons.Outlined.QuestionMark,
                tint = Color(0xFF8B5CF6),
            )
        }
    }
}

@Composable
private fun HeroGameCard(
    title: String,
    pitch: String,
    players: String,
    duration: String,
    artwork: Int,
    icon: ImageVector,
    gradient: Brush,
    onClick: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(VoiidColor.surfaceCard)
            .clickable { onClick() }
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(148.dp)
                .background(gradient),
        ) {
            androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(artwork), null,
                modifier = Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.8f)))))

            Column(
                Modifier.align(Alignment.BottomStart).padding(VoiidSpacing.md),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    title,
                    style = VoiidFont.rounded(24, FontWeight.Bold),
                    color = Color.White,
                )
                Text(
                    pitch,
                    style = VoiidFont.rounded(13, FontWeight.Normal),
                    color = Color.White.copy(alpha = 0.9f),
                )
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = VoiidSpacing.md, vertical = VoiidSpacing.sm + 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            MetaChip(Icons.Outlined.People, players)
            MetaChip(Icons.Outlined.Schedule, duration)

            Spacer(Modifier.weight(1f))

            Box(
                Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.primary),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.PlayArrow,
                    contentDescription = "Play",
                    tint = VoiidColor.textOnPrimary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun MetaChip(icon: ImageVector, text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = VoiidColor.textSecondary,
            modifier = Modifier.size(12.dp),
        )
        Text(
            text,
            style = VoiidFont.rounded(11, FontWeight.Medium),
            color = VoiidColor.textSecondary,
        )
    }
}

@Composable
private fun ComingSoonRow(
    title: String,
    pitch: String,
    icon: ImageVector,
    tint: Color,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard.copy(alpha = 0.6f))
            .padding(VoiidSpacing.sm + 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm + 2.dp),
    ) {
        Box(
            Modifier
                .size(42.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(tint.copy(alpha = 0.25f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.7f),
                modifier = Modifier.size(20.dp),
            )
        }

        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Text(
                pitch,
                style = VoiidFont.rounded(12, FontWeight.Normal),
                color = VoiidColor.textSecondary,
                maxLines = 1,
            )
        }

        Box(
            Modifier
                .clip(CircleShape)
                .background(VoiidColor.surfaceRaised)
                .padding(horizontal = 9.dp, vertical = 4.dp),
        ) {
            Text(
                "Soon",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = VoiidColor.textSecondary,
            )
        }
    }
}
