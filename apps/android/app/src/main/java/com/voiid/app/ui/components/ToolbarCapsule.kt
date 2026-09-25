package com.voiid.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor

/**
 * The trailing toolbar group as iOS 26 draws it: the items share ONE raised capsule (Liquid
 * Glass) rather than sitting as bare glyphs. Card-coloured, soft shadow, 50 tall.
 */
@Composable
fun ToolbarCapsule(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val shape = RoundedCornerShape(25.dp)
    Row(
        modifier
            .height(50.dp)
            .shadow(14.dp, shape, ambientColor = Color.Black.copy(alpha = 0.10f), spotColor = Color.Black.copy(alpha = 0.10f))
            .clip(shape)
            .background(VoiidColor.surfaceCard)
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        content = content,
    )
}

/** One glyph inside a [ToolbarCapsule], in the toolbar tint. */
@Composable
fun ToolbarCapsuleIcon(icon: ImageVector, description: String, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(icon, description, tint = VoiidColor.primary, modifier = Modifier.size(24.dp))
    }
}
