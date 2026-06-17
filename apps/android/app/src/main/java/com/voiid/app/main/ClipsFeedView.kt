package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** Clips feed (Figma Screen-9) — port of `ClipsFeedView.swift`. */
@Composable
fun ClipsFeedView(clips: ClipsStore, onOpenClip: (VClip) -> Unit, onNewClip: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Clips", style = VoiidFont.display, color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Icon(
                Icons.Default.AddCircle, "New clip", tint = VoiidColor.primary,
                modifier = Modifier.size(28.dp).softClickable(scale = 0.9f) { onNewClip() },
            )
            Spacer(Modifier.size(8.dp))
            Icon(Icons.Default.Videocam, null, tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
        }
        LazyColumn(
            Modifier.fillMaxWidth().weight(1f),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            items(clips.clips, key = { it.id }) { clip ->
                ClipCard(clip, Modifier.softClickable(scale = 0.97f) { haptics.tap(); onOpenClip(clip) })
            }
        }
    }
}

@Composable
private fun ClipCard(clip: VClip, modifier: Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            VoiidAvatar(size = 35.dp)
            Text(clip.authorName, style = VoiidFont.subhead, color = VoiidColor.textPrimary)
        }
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(Brush.verticalGradient(listOf(VoiidColor.primary.copy(alpha = 0.7f), VoiidColor.accent))),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.PlayCircle, null, tint = Color.White.copy(alpha = 0.9f), modifier = Modifier.size(54.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.FavoriteBorder, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp))
                // SwiftUI Text interpolation groups numbers by locale ("50,000") — match it.
                Text("%,d".format(clip.likes), style = VoiidFont.subhead, color = VoiidColor.textSecondary)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.AutoMirrored.Outlined.Chat, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp))
                Text("%,d".format(clip.comments), style = VoiidFont.subhead, color = VoiidColor.textSecondary)
            }
        }
    }
}
