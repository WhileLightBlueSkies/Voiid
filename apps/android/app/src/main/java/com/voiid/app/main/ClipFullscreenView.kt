package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Clips fullscreen player (Figma Screen-10) — port of `ClipFullscreenView.swift`. */
@Composable
fun ClipFullscreenView(clip: VClip, clips: ClipsStore, onClose: () -> Unit) {
    BackHandler { onClose() }
    val haptics = LocalVoiidHaptics.current
    var liked by remember { mutableStateOf(false) }
    var showComments by remember { mutableStateOf(false) }

    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(VoiidColor.primary, Color.Black))),
    ) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(16.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White,
                    modifier = Modifier.size(26.dp).clickable { onClose() },
                )
            }
            Spacer(Modifier.weight(1f))
            Row(
                Modifier.fillMaxWidth().navigationBarsPadding().padding(16.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        VoiidAvatar(size = 53.dp)
                        Text(clip.authorName, style = VoiidFont.headline, color = Color.White)
                    }
                    Text(clip.heading, style = VoiidFont.subhead, color = Color.White)
                    Text(clip.caption, style = VoiidFont.footnote, color = Color.White.copy(alpha = 0.8f))
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    ClipAction(
                        icon = if (liked) Icons.Default.Favorite else Icons.Outlined.FavoriteBorder,
                        label = "${clip.likes + if (liked) 1 else 0}",
                        tint = if (liked) VoiidColor.error else Color.White,
                    ) {
                        haptics.tap(); liked = !liked; if (liked) clips.toggleLike(clip)
                    }
                    ClipAction(Icons.AutoMirrored.Outlined.Chat, "${clip.comments}", Color.White) { showComments = true }
                    ClipAction(Icons.AutoMirrored.Filled.Send, "Share", Color.White) {}
                }
            }
        }
    }

    if (showComments) {
        ClipCommentsSheet(clips = clips, onDismiss = { showComments = false })
    }
}

@Composable
private fun ClipAction(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.clickable { onClick() },
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(28.dp))
        Text(label, style = VoiidFont.caption, color = Color.White)
    }
}
