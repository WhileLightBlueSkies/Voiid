package com.voiid.app.main

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.material3.Text
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
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import com.voiid.app.net.ChatEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

private enum class MediaTab(val label: String) { PHOTOS("Photos"), VIDEOS("Videos"), VOICE("Voice"), DOCS("Docs") }

/** "See all" shared media — segmented Photos / Videos / Voice / Documents (iOS `SharedMediaSheet`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SharedMediaSheet(conversationId: String, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    var tab by remember { mutableStateOf(MediaTab.PHOTOS) }

    // REAL shared media from the decrypted message store, newest first — never DummyData.
    val refs = remember(conversationId) {
        ChatEngine.get(context).messages(conversationId).mapNotNull { it.media }.reversed()
    }
    val photos = refs.filter { it.mime.startsWith("image/") }
    val videos = refs.filter { it.mime.startsWith("video/") }
    val voice = refs.filter { it.mime.startsWith("audio/") }
    val docs = refs.filter { !it.mime.startsWith("image/") && !it.mime.startsWith("video/") && !it.mime.startsWith("audio/") }

    com.voiid.app.ui.components.VoiidSheet(visible = true, onDismiss = onDismiss, detents = listOf(com.voiid.app.ui.components.VoiidDetent.Large)) {
        Column(Modifier.fillMaxHeight(0.92f)) {
            Text(
                "Shared media", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 16.dp, bottom = 8.dp),
            )
            Tabs(tab) { haptics.selection(); tab = it }
            // THE UNDERLINE SPRINGS ACROSS AND THE CONTENT TELEPORTED. Switching tabs
            // animated the indicator while the thing it indicates changed in a single frame,
            // so the one moving element pointed at a swap the eye never saw happen.
            //
            // A crossfade, not a slide: these four tabs are PEERS with no spatial order
            // (photos are not "left of" documents), so sliding would invent a geography that
            // does not exist. Opacity only, so no Reduce Motion gate is needed. Matches iOS.
            androidx.compose.animation.Crossfade(
                targetState = tab,
                animationSpec = tween(180),
                label = "mediaTab",
            ) { shown ->
                when (shown) {
                    MediaTab.PHOTOS -> MediaGrid(photos, "No photos yet")
                    MediaTab.VIDEOS -> MediaGrid(videos, "No videos yet")
                    MediaTab.VOICE -> RefList(voice, Icons.Default.Mic, "Voice message")
                    MediaTab.DOCS -> RefList(docs, Icons.Default.Description, "Document")
                }
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
private fun MediaGrid(refs: List<ChatEngine.MediaRef>, emptyText: String) {
    if (refs.isEmpty()) { EmptyState(emptyText); return }
    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        contentPadding = PaddingValues(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        items(refs, key = { it.mediaUrl }) { ref ->
            Box(Modifier.aspectRatio(1f).clip(RoundedCornerShape(4.dp))) { SharedMediaThumb(ref) }
        }
    }
}

@Composable
private fun RefList(refs: List<ChatEngine.MediaRef>, icon: androidx.compose.ui.graphics.vector.ImageVector, label: String) {
    if (refs.isEmpty()) { EmptyState("Nothing here yet"); return }
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        refs.forEach { _ ->
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Box(
                    Modifier.size(44.dp).clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.fieldFill),
                    contentAlignment = Alignment.Center,
                ) { Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(18.dp)) }
                Text(label, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
            }
            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.3f), modifier = Modifier.padding(start = 72.dp))
        }
    }
}

@Composable
private fun EmptyState(text: String) {
    Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) {
        Text(text, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
    }
}

/** A real decrypted media thumbnail (local-first via MediaCache), reused by the shared-media
 *  grid AND the Group Info / Contact Profile "Media, links & docs" strips. */
@Composable
fun SharedMediaThumb(ref: ChatEngine.MediaRef) {
    val context = LocalContext.current
    var bitmap by remember(ref.mediaUrl) { mutableStateOf<ImageBitmap?>(MediaCache.image(ref.mediaUrl)) }
    LaunchedEffect(ref.mediaUrl) {
        if (bitmap != null) return@LaunchedEffect
        withContext(Dispatchers.IO) { MediaCache.image(context, ref.mediaUrl) }?.let { bitmap = it; return@LaunchedEffect }
        runCatching {
            val bytes = ChatEngine.get(context).fetchMedia(ref)
            MediaCache.putData(context, ref.mediaUrl, bytes)
            val bmp = withContext(Dispatchers.IO) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
            if (bmp != null) { val ib = bmp.asImageBitmap(); MediaCache.putImage(ref.mediaUrl, ib); bitmap = ib }
        }
    }
    val b = bitmap
    // fillMaxSize, NOT fillMaxWidth().aspectRatio(1f).
    //
    // The profile strip puts this inside a fixed `Box(Modifier.size(76.dp))`, and asking for
    // an aspect ratio inside an already-square parent fights that constraint — portrait
    // photos came out stretched and the row rendered ragged. The CALLER owns the shape (a
    // square tile here, a grid cell in the sheet); this just fills whatever it is given and
    // crops to it.
    if (b != null) {
        Image(b, null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    } else {
        // A neutral placeholder, not accent-tinted. A strip of orange squares while photos
        // load reads as an error state; a quiet fill reads as "loading".
        Box(
            Modifier.fillMaxSize().background(VoiidColor.fieldFill),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(
                color = VoiidColor.primary,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
