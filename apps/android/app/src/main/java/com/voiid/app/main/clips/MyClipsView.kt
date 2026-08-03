package com.voiid.app.main.clips

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipCount
import com.voiid.app.model.ClipUploadState
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import java.io.ByteArrayOutputStream

/**
 * "My clips" — the author's own grid, and the only place a clip can be managed.
 * Port of iOS `MyClipsView.swift`.
 *
 * Editing is deliberately limited to the CAPTION and the COVER. The video itself is
 * immutable: people have already watched, liked and commented on those bytes, and
 * swapping them under a stable id would silently turn every existing like into an
 * endorsement of something the audience never saw. Re-uploading is a new clip.
 */
@Composable
fun MyClipsView(
    clips: ClipsStore,
    onBack: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val gridState = rememberLazyGridState()

    var editing by remember { mutableStateOf<VClip?>(null) }
    var confirmingDelete by remember { mutableStateOf<VClip?>(null) }

    LaunchedEffect(Unit) {
        if (!clips.myHasLoadedOnce) clips.refreshMine()
    }
    LaunchedEffect(gridState) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { clips.loadMoreMineIfNeeded(it) }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.ArrowBack, "Back", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(24.dp).softClickable(scale = 0.9f) { onBack() },
            )
            Spacer(Modifier.width(12.dp))
            Text("My clips", style = VoiidFont.display, color = VoiidColor.textPrimary)
        }

        val error = clips.myLoadError
        val slot = Modifier.fillMaxWidth().weight(1f)
        when {
            // The error state must win over the empty state — "You haven't posted a clip"
            // for a failed request is a lie about the user's own content.
            error != null && clips.myClips.isEmpty() ->
                ClipsEmptyState(
                    kind = ClipsEmptyKind.Failed(error),
                    onAction = { clips.refreshMine() },
                    modifier = slot,
                )

            clips.myLoading && clips.myClips.isEmpty() -> ClipsGridSkeleton(modifier = slot)

            clips.myClips.isEmpty() && clips.myHasLoadedOnce ->
                ClipsEmptyState(kind = ClipsEmptyKind.NoneFromYou, modifier = slot)

            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                state = gridState,
                modifier = Modifier.fillMaxWidth().weight(1f),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(clips.myClips, key = { it.id }) { clip ->
                    MyClipTile(
                        clip = clip,
                        onEdit = { haptics.tap(); editing = clip },
                        onDelete = { haptics.tap(); confirmingDelete = clip },
                    )
                }
                item(span = { GridItemSpan(maxLineSpan) }) { Spacer(Modifier.height(100.dp)) }
            }
        }
    }

    editing?.let { clip ->
        ClipEditSheet(
            clip = clip,
            clips = clips,
            onDismiss = { editing = null },
        )
    }

    // Destructive and irreversible, so it gets a real confirmation. The message says what
    // delete does NOT do — see the note in routes/clips.ts.
    confirmingDelete?.let { clip ->
        AlertDialog(
            onDismissRequest = { confirmingDelete = null },
            title = { Text("Delete this clip?", color = VoiidColor.textPrimary) },
            text = {
                Text(
                    "This removes it from Clips. People who already watched or saved it " +
                        "may still have a copy.",
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    haptics.tap()
                    clips.deleteClip(clip.id)
                    confirmingDelete = null
                }) { Text("Delete", color = VoiidColor.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = null }) {
                    Text("Cancel", color = VoiidColor.textSecondary)
                }
            },
            containerColor = VoiidColor.surfaceCard,
        )
    }
}

/**
 * A tile with its management affordances. Unlike the explore tile these are always
 * visible: Compose has no context-menu idiom as discoverable as the iOS long-press, so
 * hiding Edit/Delete behind a hold would leave most people unable to find them at all.
 */
@Composable
private fun MyClipTile(clip: VClip, onEdit: () -> Unit, onDelete: () -> Unit) {
    Box(Modifier.fillMaxWidth().aspectRatio(9f / 16f)) {
        ClipThumbnail(
            url = clip.thumbUrl,
            localPath = clip.localThumbPath,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.35f),
                    0.45f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.55f),
                )
            )
        )

        Row(
            Modifier.align(Alignment.TopEnd).padding(4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            TileAction(Icons.Default.Edit, "Edit clip", onEdit)
            TileAction(Icons.Default.Delete, "Delete clip", onDelete)
        }

        // A still-uploading clip has no server row yet, so its counts are meaningless.
        if (clip.uploadState == ClipUploadState.None) {
            Row(
                Modifier.align(Alignment.BottomStart).padding(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Icon(
                    Icons.Default.RemoveRedEye, null,
                    tint = Color.White, modifier = Modifier.size(11.dp),
                )
                Text(
                    ClipCount.compact(clip.viewCount),
                    style = VoiidFont.rounded(11, FontWeight.SemiBold),
                    color = Color.White,
                )
            }
        }
    }
}

@Composable
private fun TileAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onTap: () -> Unit,
) {
    Box(
        Modifier
            .size(26.dp)
            .clip(RoundedCornerShape(13.dp))
            .background(Color.Black.copy(alpha = 0.45f))
            .softClickable(scale = 0.9f) { onTap() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, tint = Color.White, modifier = Modifier.size(15.dp))
    }
}

/**
 * Caption + cover editor. The cover can be replaced from the photo library; the video is
 * never touched.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ClipEditSheet(
    clip: VClip,
    clips: ClipsStore,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var caption by remember { mutableStateOf(clip.caption ?: "") }
    var newCover by remember { mutableStateOf<Bitmap?>(null) }
    var saving by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        newCover = runCatching {
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
        }.getOrNull()
        if (newCover == null) errorText = "Couldn't read that image."
    }

    // Save must be reachable only when something actually changed, so an accidental tap
    // cannot mint a pointless PATCH (and a new cover object) for no edit at all.
    val hasChanges = newCover != null || caption != (clip.caption ?: "")

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.background,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "Edit clip",
                style = VoiidFont.rounded(20, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )

            Text("Cover", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Box(
                    Modifier
                        .width(90.dp)
                        .height(160.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(VoiidColor.fieldFill),
                ) {
                    val bmp = newCover
                    if (bmp != null) {
                        androidx.compose.foundation.Image(
                            bitmap = bmp.asImageBitmap(),
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        ClipThumbnail(
                            url = clip.thumbUrl,
                            localPath = clip.localThumbPath,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }

                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.softClickable(scale = 0.95f) {
                            picker.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                            )
                        },
                    ) {
                        Icon(
                            Icons.Default.Photo, null,
                            tint = VoiidColor.primary, modifier = Modifier.size(18.dp),
                        )
                        Text(
                            "Choose image",
                            style = VoiidFont.rounded(14, FontWeight.Medium),
                            color = VoiidColor.primary,
                        )
                    }
                    if (newCover != null) {
                        Text(
                            "Revert",
                            style = VoiidFont.rounded(14),
                            color = VoiidColor.textSecondary,
                            modifier = Modifier.softClickable(scale = 0.95f) { newCover = null },
                        )
                    }
                    Text(
                        "The video itself can't be changed.",
                        style = VoiidFont.rounded(12),
                        color = VoiidColor.textSecondary,
                    )
                }
            }

            Text("Caption", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            OutlinedTextField(
                value = caption,
                onValueChange = { caption = it },
                placeholder = { Text("Add a caption", color = VoiidColor.textSecondary) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                maxLines = 8,
            )
            // Mirrors MAX_CAPTION_LEN in routes/clips.ts.
            Text(
                "${caption.length}/2200",
                style = VoiidFont.rounded(12),
                color = if (caption.length > 2200) VoiidColor.error else VoiidColor.textSecondary,
            )

            errorText?.let {
                Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TextButton(onClick = onDismiss) {
                    Text("Cancel", color = VoiidColor.textSecondary)
                }
                Spacer(Modifier.weight(1f))
                if (saving) {
                    CircularProgressIndicator(
                        color = VoiidColor.primary,
                        modifier = Modifier.size(24.dp),
                    )
                } else {
                    TextButton(
                        onClick = {
                            if (caption.length > 2200) {
                                errorText = "Caption is too long."
                                return@TextButton
                            }
                            saving = true
                            errorText = null

                            val trimmed = caption.trim()
                            // An emptied caption is a CLEAR, not "leave it alone" — those
                            // are different requests and the service models them distinctly.
                            val clearing = trimmed.isEmpty() && !clip.caption.isNullOrEmpty()

                            // JPEG at 0.8 to match the exporter's cover quality; a PNG cover
                            // would be several megabytes for no visible gain.
                            val coverBytes = newCover?.let { bmp ->
                                ByteArrayOutputStream().use { out ->
                                    bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
                                    out.toByteArray()
                                }
                            }

                            clips.updateClip(
                                clipId = clip.id,
                                caption = trimmed.ifEmpty { null },
                                clearCaption = clearing,
                                newCoverJpeg = coverBytes,
                            ) { error ->
                                saving = false
                                if (error != null) {
                                    errorText = error
                                } else {
                                    haptics.success()
                                    onDismiss()
                                }
                            }
                        },
                        enabled = hasChanges,
                    ) {
                        Text(
                            "Save",
                            color = if (hasChanges) VoiidColor.primary
                            else VoiidColor.textSecondary.copy(alpha = 0.5f),
                        )
                    }
                }
            }
        }
    }
}
