package com.voiid.app.main.games

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
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
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesService
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * Incoming-invite banners for the games home screen.
 *
 * TWO KINDS, AND THE DIFFERENCE MATTERS. A LIVE invite is actionable and carries a countdown — the
 * point is to make you decide now. A MISSED one is information: it tells you someone wanted to play
 * and you weren't there, which is worth knowing once and never again. So a missed banner is
 * dismissed as soon as it has been seen (see [onSeen]), while a live one stays until it is answered
 * or expires. Treating both the same would either nag about dead invites or hide live ones.
 *
 * The chat message is still the durable record; these banners are a shortcut, not the source of
 * truth. That is why dismissing one declines/acknowledges the invite rather than deleting anything.
 *
 * Mirrors iOS `InviteBanners.swift`.
 */
@Composable
fun InviteBanner(
    invite: GamesService.PendingInvite,
    onAccept: () -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val artId = remember(invite.slug) {
        context.resources.getIdentifier("game_${invite.slug}", "drawable", context.packageName)
    }

    // Live countdown, recomputed from the SERVER's expires_at rather than a local duration — a
    // device with a skewed clock still agrees with the backend about what has expired.
    var remaining by remember(invite.match_id) {
        mutableLongStateOf((invite.expires_at - System.currentTimeMillis()).coerceAtLeast(0))
    }
    LaunchedEffect(invite.match_id) {
        while (remaining > 0) {
            delay(1000)
            remaining = (invite.expires_at - System.currentTimeMillis()).coerceAtLeast(0)
        }
    }
    val dead = invite.missed || remaining <= 0

    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(
                if (dead) VoiidColor.surfaceCard
                else VoiidColor.primary.copy(alpha = 0.12f)
            )
            .clickable(enabled = !dead) { onAccept() }
            .padding(VoiidSpacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
    ) {
        Box(
            Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            if (artId != 0) {
                Image(
                    painter = painterResource(artId),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(48.dp),
                )
            } else {
                Icon(
                    Icons.Outlined.SportsEsports, null,
                    tint = VoiidColor.primary, modifier = Modifier.size(22.dp),
                )
            }
        }

        Column(Modifier.weight(1f)) {
            Text(
                if (dead) "Missed invite" else "${invite.inviter_name ?: "A friend"} wants to play",
                color = VoiidColor.textPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
            Text(
                buildString {
                    append(invite.name)
                    if (invite.overs > 0) {
                        append(" · ${invite.overs} ${if (invite.overs == 1) "over" else "overs"}")
                    }
                    if (!dead) append(" · ${formatCountdown(remaining)} left")
                },
                color = VoiidColor.textSecondary,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }

        if (dead) {
            Icon(
                Icons.Outlined.Close,
                contentDescription = "Dismiss",
                tint = VoiidColor.textSecondary,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable { onDismiss() }
                    .padding(6.dp)
                    .size(18.dp),
            )
        } else {
            Text(
                "Play",
                color = VoiidColor.textOnPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    .clickable { onAccept() }
                    .padding(horizontal = VoiidSpacing.md, vertical = 7.dp),
            )
        }
    }
}
