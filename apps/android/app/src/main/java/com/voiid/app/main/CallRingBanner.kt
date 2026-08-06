package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CallRingCapability
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * "Calls can't ring on this phone" — the one visible trace of an OS state that otherwise makes
 * incoming calls vanish in complete silence (see [CallRingCapability] for the three states and
 * why each one is invisible).
 *
 * Tapping opens the exact settings screen that repairs it. The state re-reads on every app
 * foreground (`MainActivity.onStart`), so the banner clears itself the moment the user returns
 * from granting the permission.
 */
@Composable
fun CallRingBanner(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val state by CallRingCapability.state.collectAsState()
    LaunchedEffect(Unit) { CallRingCapability.refresh(context) }
    if (!state.degraded) return

    val label = if (state.notificationsBlocked) "Calls can't ring — notifications are off"
                else "Calls won't ring on the lock screen"

    Row(
        modifier
            .fillMaxWidth()
            .background(VoiidColor.surfaceCard)
            .clickable {
                CallRingCapability.fixIntent(context)?.let { runCatching { context.startActivity(it) } }
            }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Default.NotificationsOff, null, tint = VoiidColor.warning, modifier = Modifier.size(16.dp))
        Text(
            label,
            style = VoiidFont.rounded(13, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Text("Fix", style = VoiidFont.rounded(13, FontWeight.Bold), color = VoiidColor.warning)
    }
}
