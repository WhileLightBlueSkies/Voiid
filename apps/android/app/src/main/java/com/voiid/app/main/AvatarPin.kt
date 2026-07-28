package com.voiid.app.main

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.net.AvatarCache
import com.voiid.app.store.UserDirectory
import com.voiid.app.store.displayName
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * A friend's FACE on a map, in place of the stock red Google pin — the design reference is
 * iOS's `contactMarker` (a circular avatar with a state-coloured ring), so the two platforms
 * read the same.
 *
 * Used by the Map tab (ambient presence) and by the full-screen live-location detail, which is
 * why it lives in its own file rather than either screen: both need identical semantics for
 * "this person's signal is fresh / stale / gone".
 *
 * RING COLOUR is the state channel, matching the bubble's [com.voiid.app.model.ShareState]:
 *   LIVE  → brand primary, full colour
 *   STALE → grey ring, dimmed and de-emphasised ("may have lost signal")
 *   ENDED → further faded (the marker is on its way off the map)
 *
 * FALLBACK is never the red default pin: a photo-less peer gets initials on a disc whose
 * colour is derived deterministically from their user id, so the same person is always the
 * same colour on every device.
 */
@Composable
fun AvatarPin(
    userId: String?,
    stale: Boolean,
    ended: Boolean = false,
    size: Dp = 44.dp,
) {
    val context = LocalContext.current
    val photoRef = userId?.let { UserDirectory.photoUrl(it) }
    // Instant paint from cache, then a single de-duplicated fetch on a miss. Marker content is
    // recomposed as the map moves, so the fetch must never be started from the composition body.
    var avatar by remember(photoRef) { mutableStateOf(AvatarCache.cached(photoRef)) }
    LaunchedEffect(photoRef) {
        if (avatar == null) avatar = AvatarCache.resolve(context, photoRef)
    }

    val ring = when {
        ended -> VoiidColor.textSecondary.copy(alpha = 0.5f)
        stale -> VoiidColor.textSecondary
        else -> VoiidColor.primary
    }

    Box(
        Modifier
            .size(size)
            .alpha(if (ended) 0.6f else if (stale) 0.8f else 1f)
            .clip(CircleShape)
            .background(discColor(userId))
            .border(2.dp, ring, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        val bmp = avatar
        when {
            bmp != null -> Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            userId != null -> Text(
                initials(UserDirectory.displayName(userId)),
                style = VoiidFont.rounded((size.value * 0.34f).toInt().coerceAtLeast(9), FontWeight.SemiBold),
                color = Color.White,
            )
            else -> Icon(
                Icons.Default.Person, null, tint = Color.White,
                modifier = Modifier.size(size * 0.5f),
            )
        }
    }
}

private fun initials(name: String): String =
    name.trim().split(" ").filter { it.isNotBlank() }.take(2)
        .mapNotNull { it.firstOrNull() }.joinToString("").uppercase()

/**
 * A stable colour per user id, so a photo-less friend keeps the same disc colour everywhere and
 * across launches (a random colour per composition would flicker as markers recompose).
 */
private fun discColor(userId: String?): Color {
    if (userId == null) return VoiidColor.textSecondary
    val hues = listOf(0xFF5B8DEF, 0xFFE0685A, 0xFF3FAE7A, 0xFFB06BD6, 0xFFE2A33C, 0xFF4BA8C9)
    return Color(hues[(userId.hashCode().toUInt() % hues.size.toUInt()).toInt()])
}
