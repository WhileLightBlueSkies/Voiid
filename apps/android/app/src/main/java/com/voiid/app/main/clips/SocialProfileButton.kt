package com.voiid.app.main.clips

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.SocialStore
import com.voiid.app.net.SocialService
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Your own avatar, opening your Social Profile. Port of iOS `SocialProfileButton`.
 *
 * ── WHY IT IS SHARED ────────────────────────────────────────────────────────────
 * The Social Profile is ONE public identity across Clips, Games and Communities, and the way
 * to reach it should not be three different things in three places. Clips grew this button
 * first; Games and Communities had no way in at all, so the same identity was one tap away on
 * one tab and unreachable on the other two.
 *
 * ── WHY IT CAN BE ABSENT ────────────────────────────────────────────────────────
 * It renders nothing until a profile exists. Before that there is no page to open, and a
 * button that raised the setup sheet from a tab header would be asking for an identity at the
 * moment somebody is trying to browse — the gate belongs on the public ACTION (posting,
 * joining, liking), not on arriving.
 */
@Composable
fun SocialProfileButton(
    creators: SocialStore,
    diameter: androidx.compose.ui.unit.Dp = 28.dp,
    onOpen: (String) -> Unit,
) {
    val me = creators.me ?: return

    Box(
        Modifier
            .size(44.dp)
            .softClickable(scale = 0.9f) { onOpen(me.handle) },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            // The accent ring marks this one avatar as YOURS. Every other avatar on these
            // surfaces is unringed, so the ring is the only thing telling "me" from "someone"
            // at this size.
            Modifier
                .size(diameter + 6.dp)
                .border(2.dp, VoiidColor.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Avatar(me, diameter)
        }
    }
}

@Composable
private fun Avatar(me: SocialService.Profile, diameter: androidx.compose.ui.unit.Dp) {
    if (me.avatar_url != null) {
        ClipThumbnail(
            url = me.avatar_url,
            modifier = Modifier.size(diameter).clip(CircleShape),
        )
    } else {
        Box(
            Modifier.size(diameter).clip(CircleShape).background(VoiidColor.fieldFill),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                me.handle.take(1).uppercase(),
                style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
        }
    }
}
