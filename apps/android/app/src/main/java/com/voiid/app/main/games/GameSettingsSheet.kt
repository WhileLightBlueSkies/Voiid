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
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
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
 * DELIBERATELY TWO SWITCHES AND NOTHING ELSE. CROSS_CUTTING.md §12 also lists a control
 * scheme, a handedness option and a graphics-quality tier; those are real settings for real
 * problems, and none of them is what shipping realistic audio just made necessary.
 *
 * Mirrors iOS `GameSettingsSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GameSettingsSheet(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val haptics = remember(context) { VoiidHaptics(context) }
    val sheetState = rememberModalBottomSheetState()

    var soundOn by remember { mutableStateOf(GameSettings.soundEnabled(context)) }
    var hapticsOn by remember { mutableStateOf(GameSettings.hapticsEnabled(context)) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.background,
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
                modifier = Modifier.padding(top = VoiidSpacing.sm, bottom = VoiidSpacing.lg),
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
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = VoiidColor.textOnPrimary,
                checkedTrackColor = VoiidColor.primary,
            ),
        )
    }
}
