package com.voiid.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/*
 * The iOS `SettingsChrome.swift` primitives — VoiidSettingsHeader, VoiidCardSection,
 * VoiidSettingsRow, VoiidRowDivider, VoiidChevron — for screens ported from it.
 */

@Composable
fun VoiidSettingsHeader(title: String, subtitle: String? = null, badge: Pair<ImageVector, String>? = null) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = VoiidFont.rounded(34, FontWeight.Bold), color = VoiidColor.textPrimary)
        subtitle?.let { Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary) }
        badge?.let { (icon, text) ->
            Row(
                Modifier.padding(top = 4.dp).clip(CircleShape).background(VoiidColor.accent.copy(alpha = 0.10f))
                    .border(1.dp, VoiidColor.accent.copy(alpha = 0.4f), CircleShape)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(icon, null, tint = VoiidColor.accentInk, modifier = Modifier.size(13.dp))
                Text(text, style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.accentInk)
            }
        }
    }
}

@Composable
fun VoiidCardSection(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        header?.let {
            Text(it, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(start = 4.dp))
        }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg)),
            content = content,
        )
        footer?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(horizontal = 4.dp))
        }
    }
}

@Composable
fun VoiidRowDivider() {
    Box(Modifier.fillMaxWidth().padding(start = 66.dp).height(1.dp).background(VoiidColor.divider))
}

@Composable
fun VoiidChevron() {
    Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.textSecondary.copy(alpha = 0.7f), modifier = Modifier.size(18.dp))
}

/** 34dp stroked circle + title/detail + trailing. Tappable only when [onClick] is set. */
@Composable
fun VoiidSettingsRow(
    icon: ImageVector,
    title: String,
    detail: String? = null,
    destructive: Boolean = false,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val haptics = LocalVoiidHaptics.current
    val tint = if (destructive) VoiidColor.error else VoiidColor.accentInk
    Row(
        Modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.softClickable(enabled = enabled) { haptics.tap(); onClick() } else Modifier)
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(
            Modifier.size(34.dp).border(1.dp, if (destructive) VoiidColor.error else VoiidColor.accent.copy(alpha = 0.5f), CircleShape),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = tint, modifier = Modifier.size(17.dp)) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = if (destructive) VoiidColor.error else VoiidColor.textPrimary)
            detail?.let { Text(it, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary) }
        }
        trailing?.invoke()
    }
}
