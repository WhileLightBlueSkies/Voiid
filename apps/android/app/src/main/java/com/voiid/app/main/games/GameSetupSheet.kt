package com.voiid.app.main.games

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * "Who are you playing?" — the one entry point into any game (docs/GAMES.md §3).
 *
 * ONE SHEET, TWO PATHS. Previously "play a friend" and "practice" were separate rows on the
 * home grid, which put an implementation detail (one is online, one is local) in front of
 * the user as if it were a choice about two different things. It isn't: it is the same
 * game, against a different opponent. So the game is picked first, then the opponent.
 *
 * Difficulty only appears once Bot is chosen, and it EXPANDS in place rather than pushing a
 * new screen — the choice is small enough that a navigation step would cost more than it
 * explains. It stays locked once the match starts (see TicTacToeBotScreen).
 *
 * Mirrors iOS `GameSetupSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GameSetupSheet(
    gameName: String,
    /**
     * The catalog slug, which is how the rules are looked up. Defaulted so a caller that has no
     * slug still compiles — it simply shows no rules rather than another game's.
     */
    slug: String = "",
    onPlayFriend: () -> Unit,
    onPlayBot: (BotDifficulty, Float) -> Unit,
    /**
     * Snake only: open the appearance picker. Null hides the row, so no other game shows an
     * option it does not have.
     */
    onCustomise: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var botExpanded by remember { mutableStateOf(false) }
    var level by remember { mutableStateOf(BotDifficulty.MODERATE) }
    var skill by remember { mutableStateOf(BotDifficulty.MODERATE.skill) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                // SCROLLABLE, because the rules can push this past a small screen. Without it
                // the bottom option is simply unreachable — a sheet whose primary action cannot
                // be tapped is worse than one with no rules in it.
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VoiidSpacing.md)
                .padding(bottom = VoiidSpacing.xl),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Text(
                gameName,
                color = VoiidColor.textPrimary,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            GameRules.tagline(slug)?.let { tagline ->
                Text(
                    tagline,
                    color = VoiidColor.textSecondary,
                    fontSize = 14.sp,
                )
            }

            // The rules, as a short scannable list.
            //
            // COLLAPSED AFTER THE FIRST LOOK would be the obvious refinement, and is deliberately
            // not done: a player who needs the rules needs them on the sheet, and remembering
            // "has this person played before" is state that does not exist here. Five short
            // lines cost less than a wrong first match.
            val rules = GameRules.lines(slug)
            if (rules.isNotEmpty()) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.lg))
                        .background(VoiidColor.fieldFill.copy(alpha = 0.5f))
                        .padding(VoiidSpacing.md),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    rules.forEach { line ->
                        Row(verticalAlignment = Alignment.Top) {
                            Icon(
                                line.icon,
                                contentDescription = null,
                                tint = VoiidColor.primary,
                                // Fixed width so the text edges line up into a column; ragged
                                // icons make a list read as clutter rather than as structure.
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(VoiidSpacing.sm))
                            Text(
                                line.text,
                                color = VoiidColor.textSecondary,
                                fontSize = 13.sp,
                                lineHeight = 18.sp,
                            )
                        }
                    }
                }
            }

            Text(
                "Who are you playing?",
                color = VoiidColor.textSecondary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = VoiidSpacing.xs, bottom = VoiidSpacing.xs),
            )

            if (onCustomise != null) {
                OpponentOption(
                    icon = Icons.Outlined.Palette,
                    title = "Your snake",
                    subtitle = "Pick a skin or a colour",
                    selected = false,
                    onClick = onCustomise,
                )
            }

            // Neither row is pre-selected: this is a fork, not a default. Marking "A friend"
            // as selected whenever the bot panel was closed implied a choice the user hadn't
            // made yet, and made the sheet look like it was already committed to online play.
            OpponentOption(
                icon = Icons.Outlined.Person,
                title = "A friend",
                subtitle = "Online — counts on the leaderboard",
                selected = false,
                onClick = onPlayFriend,
            )

            OpponentOption(
                icon = Icons.Outlined.Memory,
                title = "The bot",
                subtitle = "Offline practice — doesn't count",
                selected = botExpanded,
                onClick = { botExpanded = !botExpanded },
            )

            AnimatedVisibility(
                visible = botExpanded,
                enter = fadeIn() + expandVertically(spring(dampingRatio = 0.7f)),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                        BotDifficulty.entries.forEach { l ->
                            val selected = BotDifficulty.matching(skill) == l
                            val chipScale by animateFloatAsState(
                                targetValue = if (selected) 1.06f else 1f,
                                animationSpec = spring(
                                    dampingRatio = 0.45f,
                                    stiffness = Spring.StiffnessMedium,
                                ),
                                label = "chip",
                            )
                            Box(
                                Modifier
                                    .weight(1f)
                                    .scale(chipScale)
                                    .clip(CircleShape)
                                    .background(
                                        if (selected) VoiidColor.primary else VoiidColor.fieldFill
                                    )
                                    .clickable { level = l; skill = l.skill }
                                    .padding(vertical = VoiidSpacing.sm),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    l.label,
                                    color = if (selected) VoiidColor.textOnPrimary
                                            else VoiidColor.textPrimary,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                        }
                    }

                    Slider(
                        value = skill,
                        onValueChange = { skill = it },
                        valueRange = 0f..1f,
                        colors = SliderDefaults.colors(
                            thumbColor = VoiidColor.primary,
                            activeTrackColor = VoiidColor.primary,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Bot difficulty ${(skill * 100).toInt()} percent"
                        },
                    )
                    Row(Modifier.fillMaxWidth()) {
                        Text("Fine-tune", color = VoiidColor.textSecondary, fontSize = 12.sp)
                        Text(
                            "${(skill * 100).toInt()}%",
                            color = VoiidColor.textSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                            textAlign = TextAlign.End,
                        )
                    }

                    Box(
                        Modifier
                            .fillMaxWidth()
                            .clip(CircleShape)
                            .background(VoiidColor.primary)
                            .clickable { onPlayBot(level, skill) }
                            .padding(vertical = VoiidSpacing.md),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "Start match",
                            color = VoiidColor.textOnPrimary,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun OpponentOption(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .clickable { onClick() }
            .padding(VoiidSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(VoiidColor.primary.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = VoiidColor.primary,
                modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = VoiidColor.textPrimary, fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = VoiidColor.textSecondary, fontSize = 12.sp)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = VoiidColor.textSecondary,
        )
    }
}
