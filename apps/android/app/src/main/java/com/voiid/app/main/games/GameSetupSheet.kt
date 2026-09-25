package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.Spa
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Game setup sheet: Offline bot & practice mode with clear difficulty selection.
 * Full parity twin of iOS GameSetupSheet.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GameSetupSheet(
    gameName: String,
    slug: String = "",
    onPlayFriend: () -> Unit = {},
    onPlayBot: ((BotDifficulty, Float) -> Unit)? = null,
    onCustomise: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var selectedDifficulty by remember { mutableStateOf(BotDifficulty.EASY) }
    // The thumb's own position, which is continuous — `selectedDifficulty` is the discrete
    // mode it resolves to. Keeping them apart lets the thumb sit between two stops.
    var sliderValue by remember { mutableFloatStateOf(0f) }
    var dragging by remember { mutableStateOf(false) }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(
            com.voiid.app.ui.components.VoiidDetent.Medium,
            com.voiid.app.ui.components.VoiidDetent.Large,
        ),
        initialDetentIndex = 0,
        showHandle = true,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VoiidSpacing.md)
                .padding(bottom = VoiidSpacing.xl),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    gameName,
                    color = VoiidColor.textPrimary,
                    style = VoiidFont.rounded(22, FontWeight.Bold),
                )
                GameRules.tagline(slug)?.let { tagline ->
                    Text(
                        tagline,
                        color = VoiidColor.textSecondary,
                        style = VoiidFont.rounded(13, FontWeight.Normal),
                    )
                }
            }

            // Rules card
            val rules = GameRules.lines(slug)
            if (rules.isNotEmpty()) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.md))
                        .background(VoiidColor.surfaceCard)
                        .padding(VoiidSpacing.sm + 4.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    rules.forEach { line ->
                        Row(
                            verticalAlignment = Alignment.Top,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(
                                line.icon,
                                contentDescription = null,
                                tint = VoiidColor.primary,
                                modifier = Modifier.size(15.dp),
                            )
                            Text(
                                line.text,
                                color = VoiidColor.textSecondary,
                                style = VoiidFont.rounded(13, FontWeight.Normal),
                            )
                        }
                    }
                }
            }

            if (onCustomise != null) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.md))
                        .background(VoiidColor.surfaceCard)
                        .clickable { onCustomise() }
                        .padding(horizontal = VoiidSpacing.md, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                ) {
                    Icon(
                        Icons.Outlined.Palette,
                        contentDescription = null,
                        tint = VoiidColor.primary,
                        modifier = Modifier.size(20.dp),
                    )
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Your snake",
                            color = VoiidColor.textPrimary,
                            style = VoiidFont.rounded(14, FontWeight.SemiBold),
                        )
                        Text(
                            "Pick a skin or a colour",
                            color = VoiidColor.textSecondary,
                            style = VoiidFont.rounded(12, FontWeight.Normal),
                        )
                    }
                }
            }

            Text(
                "How do you want to play?",
                color = VoiidColor.textPrimary,
                style = VoiidFont.rounded(16, FontWeight.Bold),
            )

            // Difficulty as one track rather than three radio rows: the modes are ordered
            // and mutually exclusive, which is a magnitude, not a set of unrelated options.
            // Mirrors iOS GameSetupSheet.swift.
            val steps = listOf(
                Triple(BotDifficulty.EASY, Icons.Outlined.Spa, "Easy"),
                Triple(BotDifficulty.MODERATE, Icons.Outlined.Memory, "Moderate"),
                Triple(BotDifficulty.HARD, Icons.Outlined.Bolt, "Hard"),
            )
            val index = steps.indexOfFirst { it.first == selectedDifficulty }.coerceAtLeast(0)
            val (_, stepIcon, _) = steps[index]
            val title = when (selectedDifficulty) {
                BotDifficulty.EASY -> if (slug == "snake") "Easy Mode (Practice)" else "Easy Mode (vs Bots)"
                BotDifficulty.MODERATE -> if (slug == "snake") "Standard Arena" else "Moderate Mode (vs Bots)"
                BotDifficulty.HARD -> if (slug == "snake") "Hardcore Arena" else "Hard Mode (vs Bots)"
            }
            val detail = when (selectedDifficulty) {
                BotDifficulty.EASY -> if (slug == "carrom") "You play white, the bot plays black" else if (slug == "snake") "Calm arena with fewer bots, relaxed growth" else "Relaxed bots, gentle moves, easy practice"
                BotDifficulty.MODERATE -> if (slug == "carrom") "You play white, the bot plays black" else if (slug == "snake") "Competitive 8 bots, balanced speed" else "Standard balanced match against 3 bots"
                BotDifficulty.HARD -> if (slug == "carrom") "You play white, the bot plays black" else if (slug == "snake") "Fast paced, aggressive hunting bots" else "Aggressive bots that cut and race"
            }

            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.surfaceCard)
                    .padding(VoiidSpacing.md),
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                Row(
                    // Reserved so the card does not resize as the two lines change length.
                    Modifier.fillMaxWidth().height(44.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        stepIcon,
                        contentDescription = null,
                        tint = VoiidColor.primary,
                        modifier = Modifier.size(20.dp),
                    )
                    Column(Modifier.weight(1f)) {
                        Text(
                            title,
                            color = VoiidColor.textPrimary,
                            style = VoiidFont.rounded(14, FontWeight.SemiBold),
                        )
                        Text(
                            detail,
                            color = VoiidColor.textSecondary,
                            style = VoiidFont.rounded(12, FontWeight.Normal),
                        )
                    }
                }

                // CONTINUOUS WHILE DRAGGING, SETTLING ON RELEASE.
                //
                // `steps` made the thumb teleport between the three stops: it cannot rest
                // between them, so the control stopped tracking the finger and the motion
                // read as broken rather than as snapping. Here the thumb follows exactly,
                // the selection updates as it crosses each stop, and on release it animates
                // to the chosen one. Mirrors iOS GameSetupSheet.swift.
                val settled by androidx.compose.animation.core.animateFloatAsState(
                    targetValue = index.toFloat(),
                    animationSpec = androidx.compose.animation.core.spring(
                        dampingRatio = 0.78f,
                        stiffness = androidx.compose.animation.core.Spring.StiffnessMediumLow,
                    ),
                    label = "difficultySettle",
                )
                androidx.compose.material3.Slider(
                    value = if (dragging) sliderValue else settled,
                    onValueChange = { raw ->
                        dragging = true
                        sliderValue = raw
                        val step = raw.roundToInt().coerceIn(0, steps.lastIndex)
                        if (steps[step].first != selectedDifficulty) {
                            selectedDifficulty = steps[step].first
                        }
                    },
                    onValueChangeFinished = { dragging = false },
                    valueRange = 0f..steps.lastIndex.toFloat(),
                    colors = androidx.compose.material3.SliderDefaults.colors(
                        thumbColor = VoiidColor.primary,
                        activeTrackColor = VoiidColor.primary,
                    ),
                )

                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    steps.forEachIndexed { offset, (_, _, label) ->
                        Text(
                            label,
                            color = if (offset == index) VoiidColor.primary else VoiidColor.textSecondary,
                            style = VoiidFont.rounded(
                                11.5f,
                                if (offset == index) FontWeight.Bold else FontWeight.Medium,
                            ),
                        )
                    }
                }
            }

            Spacer(Modifier.height(4.dp))

            // Start Game Button
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.primary)
                    .clickable {
                        onPlayBot?.invoke(selectedDifficulty, selectedDifficulty.skill)
                    }
                    .padding(vertical = 15.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Default.PlayArrow,
                        contentDescription = null,
                        tint = VoiidColor.textOnPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        "Start game",
                        color = VoiidColor.textOnPrimary,
                        style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    )
                }
            }
        }
    }
}

@Composable
private fun DifficultyOptionRow(
    title: String,
    detail: String,
    icon: ImageVector,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(if (isSelected) VoiidColor.primary.copy(alpha = 0.14f) else VoiidColor.surfaceCard)
            .border(
                width = if (isSelected) 1.5.dp else 1.dp,
                color = if (isSelected) VoiidColor.primary else VoiidColor.divider,
                shape = RoundedCornerShape(VoiidRadius.md),
            )
            .clickable { onClick() }
            .padding(horizontal = VoiidSpacing.md, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (isSelected) VoiidColor.primary else VoiidColor.textSecondary,
            modifier = Modifier.size(22.dp),
        )

        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                color = VoiidColor.textPrimary,
                style = VoiidFont.rounded(14, FontWeight.SemiBold),
            )
            Text(
                detail,
                color = VoiidColor.textSecondary,
                style = VoiidFont.rounded(12, FontWeight.Normal),
            )
        }

        // Selection indicator
        Box(
            Modifier
                .size(20.dp)
                .border(
                    width = if (isSelected) 2.dp else 1.5.dp,
                    color = if (isSelected) VoiidColor.primary else VoiidColor.textSecondary,
                    shape = CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (isSelected) {
                Box(
                    Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.primary)
                )
            }
        }
    }
}
