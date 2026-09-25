package com.voiid.app.main.clips

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.main.AvatarPalette
import com.voiid.app.model.ClipCount
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** iOS `ClipDuration.label`: rounded seconds as m:ss, or null when the row carries none. */
fun clipDurationLabel(ms: Int?): String? {
    if (ms == null || ms <= 0) return null
    val total = Math.round(ms / 1000.0).toInt()
    return "%d:%02d".format(total / 60, total % 60)
}

/**
 * Port of iOS `ClipTile`: a CARD, not a bare thumbnail. Cover at 0.72 with the top corners
 * rounded and a play-count / duration strip, then a handle row (18 avatar, @handle, seal) on
 * the card fill — 14 radius, hairline border. Both Explore and Following use it.
 */
@Composable
fun ClipCard(
    clipId: String,
    thumbUrl: String?,
    localThumbPath: String? = null,
    viewCount: Int,
    durationMs: Int?,
    handle: String?,
    authorName: String,
    authorPhotoUrl: String?,
    verified: Boolean,
    modifier: Modifier = Modifier,
    showMeta: Boolean = true,
    onOpen: () -> Unit,
    onCreator: (() -> Unit)? = null,
    overlay: @Composable BoxScope.() -> Unit = {},
) {
    val shape = RoundedCornerShape(14.dp)
    val seed = handle ?: authorName
    Column(
        modifier.fillMaxWidth().clip(shape).background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, shape),
    ) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(0.72f)
                .clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
                .clipZoomSource(scale = 0.97f) { onOpen() },
        ) {
            if (thumbUrl != null || localThumbPath != null) {
                ClipThumbnail(url = thumbUrl, localPath = localThumbPath, modifier = Modifier.fillMaxSize())
            } else {
                Box(
                    Modifier.fillMaxSize().background(Brush.linearGradient(listOf(
                        AvatarPalette.colorFor(clipId), AvatarPalette.colorFor(seed).copy(alpha = 0.7f),
                        Color.Black.copy(alpha = 0.6f)))),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.PlayCircle, null, tint = Color.White.copy(alpha = 0.35f), modifier = Modifier.size(26.dp)) }
            }
            if (showMeta) Row(
                Modifier.align(Alignment.BottomStart).fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f))))
                    .padding(start = 7.dp, end = 7.dp, top = 18.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Icons.Default.PlayArrow, null, tint = Color.White, modifier = Modifier.size(11.dp))
                Text(ClipCount.compact(viewCount), style = VoiidFont.rounded(11, FontWeight.SemiBold), color = Color.White)
                Spacer(Modifier.weight(1f))
                clipDurationLabel(durationMs)?.let {
                    Text(it, style = VoiidFont.rounded(11, FontWeight.SemiBold), color = Color.White)
                }
            }
            overlay()
        }
        Row(
            Modifier.fillMaxWidth()
                .then(if (onCreator != null && !handle.isNullOrEmpty()) Modifier.softClickable(onClick = onCreator) else Modifier)
                .padding(horizontal = 6.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (authorPhotoUrl != null) {
                ClipThumbnail(url = authorPhotoUrl, modifier = Modifier.size(18.dp).clip(CircleShape))
            } else {
                Box(
                    Modifier.size(18.dp).clip(CircleShape).background(Brush.linearGradient(listOf(
                        AvatarPalette.colorFor(seed), AvatarPalette.colorFor(seed).copy(alpha = 0.72f)))),
                    contentAlignment = Alignment.Center,
                ) { Text(AvatarPalette.initialsFor(seed), style = VoiidFont.rounded(7f, FontWeight.SemiBold), color = Color.White) }
            }
            Text(
                if (!handle.isNullOrEmpty()) "@$handle" else authorName,
                style = VoiidFont.rounded(10.5f), color = VoiidColor.textPrimary,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
            )
            if (verified) Icon(Icons.Default.Verified, "Verified", tint = VoiidColor.accent, modifier = Modifier.size(10.dp))
        }
    }
}
