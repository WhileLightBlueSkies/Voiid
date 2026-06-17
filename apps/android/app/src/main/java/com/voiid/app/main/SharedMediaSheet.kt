package com.voiid.app.main

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.DummyData
import com.voiid.app.model.VMediaItem
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

private enum class MediaTab(val label: String) { PHOTOS("Photos"), VIDEOS("Videos"), VOICE("Voice"), DOCS("Docs") }

/** "See all" shared media — segmented Photos / Videos / Voice / Documents (iOS `SharedMediaSheet`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SharedMediaSheet(onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var tab by remember { mutableStateOf(MediaTab.PHOTOS) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background, dragHandle = null) {
        Column(Modifier.fillMaxHeight(0.92f)) {
            Text(
                "Shared media", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 16.dp, bottom = 8.dp),
            )
            Tabs(tab) { haptics.selection(); tab = it }
            when (tab) {
                MediaTab.PHOTOS -> PhotoGrid(DummyData.sharedPhotos)
                MediaTab.VIDEOS -> PhotoGrid(DummyData.sharedVideos)
                MediaTab.VOICE -> MediaList(DummyData.sharedVoice, Icons.Default.Mic)
                MediaTab.DOCS -> MediaList(DummyData.sharedDocs, Icons.Default.Description)
            }
        }
    }
}

@Composable
private fun Tabs(selected: MediaTab, onSelect: (MediaTab) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val slot = maxWidth / 4
        val underlineX by animateDpAsState(
            targetValue = slot * selected.ordinal,
            animationSpec = spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMedium),
            label = "mediaUnderline",
        )
        Column {
            Row(Modifier.fillMaxWidth()) {
                MediaTab.entries.forEach { t ->
                    Box(
                        Modifier
                            .weight(1f)
                            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { onSelect(t) }
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            t.label, style = VoiidFont.rounded(14, FontWeight.SemiBold),
                            color = if (selected == t) VoiidColor.primary else VoiidColor.textSecondary,
                        )
                    }
                }
            }
            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
        }
        Box(
            Modifier
                .offset(x = underlineX)
                .align(Alignment.BottomStart)
                .size(width = slot, height = 3.dp)
                .background(VoiidColor.primary),
        )
    }
}

@Composable
private fun PhotoGrid(items: List<VMediaItem>) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        contentPadding = PaddingValues(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        items(items, key = { it.id }) { item ->
            Box(
                Modifier.aspectRatio(1f).clip(RoundedCornerShape(4.dp)).background(VoiidColor.accent.copy(alpha = 0.35f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (item.kind == VMediaItem.Kind.VIDEO) Icons.Default.PlayCircle else Icons.Default.Image,
                    null, tint = VoiidColor.primary, modifier = Modifier.size(24.dp),
                )
                if (item.kind == VMediaItem.Kind.VIDEO && item.title.isNotEmpty()) {
                    Text(
                        item.title, style = VoiidFont.rounded(10, FontWeight.Medium), color = Color.White,
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color.Black.copy(alpha = 0.4f))
                            .padding(horizontal = 4.dp, vertical = 1.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun MediaList(items: List<VMediaItem>, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        items.forEach { item ->
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Box(
                    Modifier.size(44.dp).clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.fieldFill),
                    contentAlignment = Alignment.Center,
                ) { Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(18.dp)) }
                Text(item.title.ifEmpty { "Item" }, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp))
            }
            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.3f), modifier = Modifier.padding(start = 72.dp))
        }
    }
}
