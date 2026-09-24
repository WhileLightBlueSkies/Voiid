package com.voiid.app.main.stories

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.model.Story
import com.voiid.app.store.StoryLocalStore
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/** Author-only, opt-in, local archive. Opening it never sends a view receipt or downloads expired media. */
@Composable
fun StoryArchiveScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var moments by remember { mutableStateOf<List<Story>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var open by remember { mutableStateOf<Story?>(null) }
    var delete by remember { mutableStateOf<Story?>(null) }
    LaunchedEffect(Unit) {
        try { moments = StoryLocalStore.keptMoments(context) }
        catch (_: Exception) { error = "Couldn’t load kept moments." }
        finally { loading = false }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(VoiidColor.background).systemBarsPadding().padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Kept moments", style = VoiidFont.rounded(22), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Done", color = VoiidColor.accentInk) }
            }
            Text("Moments you keep stay here after they expire. Only on this device.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            Spacer(Modifier.height(16.dp))
            when {
                loading -> CircularProgressIndicator(color = VoiidColor.primary)
                error != null -> Text(error!!, color = VoiidColor.error)
                moments.isEmpty() -> Text("Open one of your moments and tap Keep to save it here.", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                else -> LazyVerticalGrid(columns = GridCells.Fixed(2), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(moments, key = { it.id }) { moment ->
                        Column(Modifier.clip(RoundedCornerShape(18.dp)).background(VoiidColor.surfaceCard)) {
                            val path = moment.localPath
                            val thumbnail = if (path != null) rememberStoryThumbnail(path, moment.isVideo, 360, 480) else null
                            Box(Modifier.fillMaxWidth().height(170.dp).clickable { open = moment }, Alignment.Center) {
                                if (thumbnail != null) Image(thumbnail, moment.caption.ifBlank { "Kept moment" }, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                                else Text("Preview unavailable", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                            }
                            Text(java.text.DateFormat.getDateInstance().format(java.util.Date(moment.createdAt)), style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, modifier = Modifier.padding(10.dp))
                            TextButton(onClick = { delete = moment }) { Text("Delete", color = VoiidColor.error) }
                        }
                    }
                }
            }
        }
    }
    open?.let { moment ->
        Dialog(onDismissRequest = { open = null }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            var muted by remember(moment.id) { mutableStateOf(true) }
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                moment.localPath?.takeIf { java.io.File(it).isFile }?.let {
                    StoryMediaFrame(it, moment.isVideo, paused = false, muted = muted)
                } ?: Text("This file is no longer on this device.", color = Color.White, modifier = Modifier.align(Alignment.Center))
                Row(Modifier.align(Alignment.TopEnd).statusBarsPadding()) {
                    if (moment.isVideo) TextButton(onClick = { muted = !muted }) { Text(if (muted) "Unmute" else "Mute", color = Color.White) }
                    TextButton(onClick = { open = null }) { Text("Close", color = Color.White) }
                }
            }
        }
    }
    delete?.let { moment ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { delete = null },
            title = "Delete this kept moment?",
            body = "This removes the copy on this device. It can’t be undone.",
            confirmLabel = "Delete",
            confirmDestructive = true,
            onConfirm = {
                scope.launch {
                    try {
                        StoryLocalStore.deleteKeptMoment(context, moment.id)
                        moments = StoryLocalStore.keptMoments(context)
                        delete = null
                    } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                    catch (_: Exception) { error = "Couldn’t delete this kept moment. Please try again."; delete = null }
                }
            },
            onCancel = { delete = null },
        )
    }
}
