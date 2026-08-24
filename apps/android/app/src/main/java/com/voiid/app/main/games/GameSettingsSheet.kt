package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Vibration
import androidx.compose.material.icons.outlined.VolumeUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.VoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Sound and haptics toggles for the Games tab (docs/games/CROSS_CUTTING.md §12).
 *
 * There were no game settings of any kind. `GameAudio.isMuted` already existed and already
 * persisted — it simply had no UI, so the only way to silence a match was to silence the
 * phone. That was liveable while the palette was a handful of synthesised bleeps; with a
 * stadium crowd running under every cricket match it is not.
 *
 * Sound and haptics came first, because shipping realistic audio made them necessary. The
 * Snake steering scheme joined them once the competitor audit showed two control schemes are
 * table stakes rather than a nicety (docs/games/SNAKE_COMPETITIVE_PARITY.md §2.5).
 *
 * §12 also lists a left/right-handed layout and a graphics-quality tier. Both are real settings
 * for real problems and neither is here yet — this sheet grows when something makes a setting
 * necessary, not to pre-empt one.
 *
 * Mirrors iOS `GameSettingsSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GameSettingsSheet(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val haptics = remember(context) { VoiidHaptics(context) }

    var soundOn by remember { mutableStateOf(GameSettings.soundEnabled(context)) }
    var hapticsOn by remember { mutableStateOf(GameSettings.hapticsEnabled(context)) }
    val choices = remember(context) { SnakeChoiceStore(context) }
    var control by remember { mutableStateOf(choices.controlScheme) }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = VoiidSpacing.lg, vertical = VoiidSpacing.sm),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Text(
                "Game settings",
                style = VoiidFont.rounded(22, FontWeight.Bold),
                color = VoiidColor.textPrimary,
                modifier = Modifier.padding(bottom = VoiidSpacing.sm),
            )

            SettingRow(
                icon = Icons.Outlined.VolumeUp,
                title = "Sound",
                subtitle = "Crowd, chalk, and everything else in a match",
                checked = soundOn,
            ) { on ->
                soundOn = on
                GameSettings.setSoundEnabled(context, on)
                // The confirming buzz fires only when turning sound ON. Turning it off and
                // being answered by the device is a small joke at the player's expense.
                if (on) haptics.tap()
            }

            SettingRow(
                icon = Icons.Outlined.Vibration,
                title = "Haptics",
                subtitle = "Buzz on eats, kills and wickets",
                checked = hapticsOn,
            ) { on ->
                hapticsOn = on
                GameSettings.setHapticsEnabled(context, on)
                // Fired AFTER the write, so switching haptics on demonstrates itself and
                // switching them off is silent — the setting proving it took effect.
                if (on) haptics.tap()
            }

            Text(
                "Games always respect your ringer switch and never play over a call.",
                style = VoiidFont.rounded(12, FontWeight.Normal),
                color = VoiidColor.textSecondary,
                modifier = Modifier.padding(top = VoiidSpacing.sm, bottom = VoiidSpacing.md),
            )

            // SNAKE ONLY, and labelled as such. Sound and haptics above apply to every game; a
            // control scheme applies to exactly one, and burying that distinction would have
            // players hunting for why the setting did nothing in cricket.
            Text(
                "Snake",
                style = VoiidFont.rounded(12, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )

            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard)
                    .padding(VoiidSpacing.md),
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                Text(
                    "Steering",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.md))
                        .background(VoiidColor.fieldFill)
                        .padding(3.dp),
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    SnakeChoiceStore.ControlScheme.entries.forEach { option ->
                        val selected = option == control
                        Text(
                            option.label,
                            style = VoiidFont.rounded(14, FontWeight.SemiBold),
                            color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(VoiidRadius.sm))
                                .background(
                                    if (selected) VoiidColor.primary else Color.Transparent
                                )
                                .clickable {
                                    control = option
                                    choices.controlScheme = option
                                    haptics.tap()
                                }
                                .padding(vertical = VoiidSpacing.sm),
                        )
                    }
                }
                Text(
                    control.detail,
                    style = VoiidFont.rounded(12, FontWeight.Normal),
                    color = VoiidColor.textSecondary,
                )
            }

            // Says WHEN it takes effect, because it does not take effect now. The arena reads
            // the scheme once on open so the controls cannot move out from under a thumb
            // mid-match, and a setting that appears to do nothing is worse than one that
            // explains its own timing.
            Text(
                "Applies to your next match.",
                style = VoiidFont.rounded(12, FontWeight.Normal),
                color = VoiidColor.textSecondary,
                modifier = Modifier.padding(top = VoiidSpacing.xs, bottom = VoiidSpacing.lg),
            )
        }
    }
}

@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            // The whole row toggles, not just the switch — a 48 dp switch inside a 72 dp row
            // is a target most thumbs miss on the first try.
            .clickable { onChange(!checked) }
            .padding(VoiidSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (checked) VoiidColor.primary else VoiidColor.textSecondary,
            modifier = Modifier.size(22.dp),
        )
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = VoiidSpacing.md),
        ) {
            Text(
                title,
                style = VoiidFont.rounded(16, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Text(
                subtitle,
                style = VoiidFont.rounded(12, FontWeight.Normal),
                color = VoiidColor.textSecondary,
            )
        }
        com.voiid.app.ui.components.VoiidToggle(checked = checked, onCheckedChange = onChange)
    }
}
