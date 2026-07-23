package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.LocationShareEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * The persistent "sharing live location" banner (docs/LOCATION.md §8.A). Shown whenever I have an
 * active outbound live share. One tap on Stop ends it; the countdown is derived from expiresAt (the
 * timer guarantee). [conversationId] scopes it to a single chat when set (ChatDetailView); null
 * shows any active share (ChatsHomeView).
 */
@Composable
fun LocationBanner(conversationId: String? = null, modifier: Modifier = Modifier) {
    val shares = LocationShareEngine.outboundActive.filter { conversationId == null || it.conversationId == conversationId }
    if (shares.isEmpty()) return
    // Re-tick once a minute so "N min left" stays current without a heavy timer.
    val now by produceState(System.currentTimeMillis()) {
        while (true) { value = System.currentTimeMillis(); kotlinx.coroutines.delay(30_000) }
    }
    val soonest = shares.minByOrNull { it.expiresAt } ?: return
    val minsLeft = ((soonest.expiresAt - now) / 60000L).coerceAtLeast(0)
    val label = if (shares.size == 1) "Sharing live location · ${minsLeft}m left"
                else "Sharing live location to ${shares.size} chats"

    Row(
        modifier.fillMaxWidth().background(VoiidColor.primary).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(9.dp).clip(CircleShape).background(VoiidColor.accent))
        Icon(Icons.Default.LocationOn, null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(16.dp))
        Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textOnPrimary, modifier = Modifier.weight(1f))
        Text(
            if (shares.size == 1) "Stop" else "Stop all",
            style = VoiidFont.rounded(13, FontWeight.Bold), color = VoiidColor.textOnPrimary,
            modifier = Modifier.clickable {
                if (shares.size == 1) LocationShareEngine.stopShareUi(soonest.shareId)
                else LocationShareEngine.stopAllFromSystem()
            },
        )
    }
}
