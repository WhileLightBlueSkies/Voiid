package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.LocationShareEngine
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.reduceMotionEnabled
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/**
 * The persistent "sharing live location" banner (docs/LOCATION.md §8.A). Port of iOS
 * `LocationBanner`:
 *
 *  - Title and time are SEPARATE lines ("Sharing live location" / "12 min left"), not one run-on.
 *  - A live accent pulse is the eye-catcher on a solid primary fill; the text rides textOnPrimary.
 *  - Stop-all REQUIRES confirmation — ending every share is destructive and must be deliberate.
 *    Single-share Stop stays immediate. Rigid haptic on the destructive intent either way.
 *  - Slides in from the top with a fade (reduced motion: fade only).
 */
@Composable
fun LocationBanner(conversationId: String? = null, modifier: Modifier = Modifier) {
    val shares = LocationShareEngine.outboundActive.filter { conversationId == null || it.conversationId == conversationId }
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    var confirmStopAll by remember { mutableStateOf(false) }
    var stopping by remember { mutableStateOf(false) }
    val reduceMotion = reduceMotionEnabled()

    // Re-tick once a minute so "N min left" stays current without a heavy timer.
    val now by produceState(System.currentTimeMillis()) {
        while (true) { value = System.currentTimeMillis(); kotlinx.coroutines.delay(30_000) }
    }

    AnimatedVisibility(
        visible = shares.isNotEmpty(),
        enter = if (reduceMotion) fadeIn() else slideInVertically { -it } + fadeIn(),
        exit = if (reduceMotion) fadeOut() else slideOutVertically { -it } + fadeOut(),
        modifier = modifier,
    ) {
        if (shares.isEmpty()) return@AnimatedVisibility
        val soonest = shares.minByOrNull { it.expiresAt }
        val minsLeft = soonest?.let { ((it.expiresAt - now) / 60000L).coerceAtLeast(0) } ?: 0L
        Column(Modifier.fillMaxWidth().background(VoiidColor.primary)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                // The live dot — the one thing that should draw the eye here.
                Box(Modifier.size(9.dp).clip(CircleShape).background(VoiidColor.accent))
                Icon(Icons.Default.LocationOn, null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(15.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        if (shares.size == 1) "Sharing live location"
                        else "Sharing live location to ${shares.size} chats",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = VoiidColor.textOnPrimary,
                    )
                    Text(
                        when {
                            shares.size != 1 -> ""
                            minsLeft <= 1 -> "less than a minute left"
                            else -> "$minsLeft min left"
                        },
                        style = VoiidFont.rounded(11),
                        color = VoiidColor.textOnPrimary.copy(alpha = 0.8f),
                    )
                }
                Box(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(VoiidColor.error)
                        .clickable(enabled = !stopping) {
                            haptics.rigid()
                            if (shares.size == 1) {
                                LocationShareEngine.stopShareUi(soonest!!.shareId)
                            } else {
                                confirmStopAll = true
                            }
                        }
                        .padding(horizontal = 14.dp, vertical = 6.dp),
                ) {
                    Text(
                        if (shares.size == 1) "Stop" else "Stop all",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = VoiidColor.textOnPrimary,
                    )
                }
            }
            Spacer(Modifier.height(1.dp).background(VoiidColor.fieldBorder))
        }
    }

    if (confirmStopAll) {
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { if (!stopping) confirmStopAll = false },
            title = "Stop all live shares?",
            body = "This ends every live share you have running.",
            confirmLabel = "Stop all",
            onConfirm = {
                stopping = true
                scope.launch {
                    LocationShareEngine.stopAllFromSystem()
                    stopping = false
                    confirmStopAll = false
                }
            },
            confirmDestructive = true,
            busy = stopping,
        )
    }
}
