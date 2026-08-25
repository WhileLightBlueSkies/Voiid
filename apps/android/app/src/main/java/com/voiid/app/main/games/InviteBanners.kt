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
import androidx.compose.material3.minimumInteractiveComponentSize
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
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.voiid.app.net.GamesService
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * Incoming-invite banners for the games home screen.
 *
 * TWO KINDS, AND THE DIFFERENCE MATTERS. A LIVE invite is actionable and carries a countdown — the
 * point is to make you decide now. A MISSED one is information: it tells you someone wanted to play
 * and you weren't there, which is worth knowing once and never again. So a missed banner is
 * dismissed as soon as it has been seen (see [onSeen]), while a live one stays until it is answered,
 * declined or expires. Treating both the same would either nag about dead invites or hide live ones.
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

    // Init in `remember`, not a LaunchedEffect: the name below is read SYNCHRONOUSLY during this
    // composition, so an effect that runs after the first frame would show the server-sent name
    // (or "Someone") once and only then correct itself to the saved contact name. Idempotent.
    remember { UserDirectory.init(context) }

    // The invitee's own address book wins over the inviter's self-chosen profile name — otherwise
    // the push notification for this very invite says "Mum" while the in-app banner says
    // "Priya Sharma". The directory's "Unknown" sentinel is an internal marker, never copy: this
    // surface says "Someone", and a raw uuid can never reach the screen because `displayName`
    // ignores a fallback equal to the id it was asked about.
    val inviterName = UserDirectory
        .displayName(invite.inviter_id.orEmpty(), invite.inviter_name)
        .let { if (it == "Unknown") "Someone" else it }

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
            if (invite.slug == "ludo") {
                com.voiid.app.main.LudoInviteMiniBoard(Modifier.size(40.dp))
            } else if (artId != 0) {
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
                if (dead) "Missed invite" else "$inviterName wants to play",
                style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // The countdown turns amber in the last minute so the deadline reads at a glance —
            // urgency without animating anything, which would fight the rest of the surface.
            val urgent = !dead && remaining < 60_000
            val urgentColor = VoiidColor.warning
            Text(
                buildAnnotatedString {
                    append(invite.name)
                    if (invite.overs > 0) {
                        append(" · ${invite.overs} ${if (invite.overs == 1) "over" else "overs"}")
                    }
                    if (!dead) {
                        append(" · ")
                        if (urgent) {
                            withStyle(SpanStyle(color = urgentColor)) {
                                append("${formatCountdown(remaining)} left")
                            }
                        } else {
                            append("${formatCountdown(remaining)} left")
                        }
                    }
                },
                style = VoiidFont.rounded(12),
                color = VoiidColor.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (dead) {
            Icon(
                Icons.Outlined.Close,
                contentDescription = "Dismiss",
                tint = VoiidColor.textSecondary,
                modifier = Modifier
                    .minimumInteractiveComponentSize()
                    .clip(CircleShape)
                    .clickable { onDismiss() }
                    .padding(6.dp)
                    .size(18.dp),
            )
        } else {
            // "No" needs to be sayable while the invite is still live. Without this the only
            // dismiss lived in the dead branch, so the sole way to turn an invite down was to let
            // it expire — and the person waiting learned nothing until it did. Ghost weight keeps
            // Play the obvious primary action.
            Text(
                "Decline",
                style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
                modifier = Modifier
                    .minimumInteractiveComponentSize()
                    .clip(CircleShape)
                    .clickable { onDismiss() }
                    .padding(horizontal = VoiidSpacing.sm, vertical = 7.dp),
            )
            Text(
                "Play",
                style = VoiidFont.rounded(13, FontWeight.Bold),
                color = VoiidColor.textOnPrimary,
                modifier = Modifier
                    .minimumInteractiveComponentSize()
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    .clickable { onAccept() }
                    .padding(horizontal = VoiidSpacing.md, vertical = 7.dp),
            )
        }
    }
}
