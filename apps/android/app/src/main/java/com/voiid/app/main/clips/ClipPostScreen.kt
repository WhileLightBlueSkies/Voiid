package com.voiid.app.main.clips

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** What the author chose on the post screen. */
data class ClipPostChoices(
    val caption: String,
    val commentsEnabled: Boolean,
    val saveToGallery: Boolean,
)

/**
 * Step 3: caption, who can watch, comments, save a copy, Post. Port of iOS ClipPostView.
 * The cover is shown the size it matters and tapping it goes back to the editor's cover tray.
 * Post shows a beat on the cover with a tick, then the flow closes — the encode and upload
 * carry on on the clip's tile in the grid, so nothing here waits on them.
 */
@Composable
fun ClipPostScreen(
    sourceFile: File,
    edit: ClipEdit,
    onBack: () -> Unit,
    onEditCover: () -> Unit,
    onPost: (ClipPostChoices) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    var caption by remember { mutableStateOf(TextFieldValue("")) }
    var allowComments by remember { mutableStateOf(true) }
    var saveToGallery by remember { mutableStateOf(false) }
    var cover by remember { mutableStateOf<Bitmap?>(null) }
    var posting by remember { mutableStateOf(false) }
    val captionFocus = remember { FocusRequester() }

    LaunchedEffect(sourceFile, edit.coverMs, edit.filter, edit.customCoverJpeg) {
        // The exporter's precedence exactly: an uploaded image wins over the frame.
        val custom = edit.customCoverJpeg
        cover = withContext(Dispatchers.IO) {
            if (custom != null) android.graphics.BitmapFactory.decodeByteArray(custom, 0, custom.size)
            else ClipExporter.frameBitmap(sourceFile, edit.coverMs)?.let { edit.filter.applyToBitmap(downscale(it)) }
        }
    }

    fun insert(token: String) {
        val t = caption.text
        val needsSpace = !(t.isEmpty() || t.endsWith(" ") || t.endsWith("\n"))
        val next = (t + (if (needsSpace) " " else "") + token).take(ClipCaps.MAX_CAPTION)
        caption = TextFieldValue(next, TextRange(next.length))
        runCatching { captionFocus.requestFocus() }
    }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
                Box(Modifier.size(44.dp).softClickable(scale = 0.9f) { if (!posting) { haptics.tap(); onBack() } },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to editing", tint = VoiidColor.textPrimary)
                }
                Text("New clip", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                    modifier = Modifier.align(Alignment.Center))
            }

            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                // Caption + cover
                Column(Modifier.clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Box(Modifier.size(width = 96.dp, height = 170.dp).clip(RoundedCornerShape(14.dp))
                            .softClickable(scale = 0.96f) { haptics.tap(); onEditCover() }) {
                            cover?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                                ?: ClipShimmer(Modifier.fillMaxSize())
                            Text(shortDuration(edit.durationMs), style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White,
                                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).clip(RoundedCornerShape(50))
                                    .background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 6.dp, vertical = 2.dp))
                            Text("Edit cover", style = VoiidFont.rounded(11, FontWeight.SemiBold), color = Color.White,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                                    .background(Color.Black.copy(alpha = 0.55f)).padding(vertical = 5.dp))
                        }
                        Column(Modifier.weight(1f).height(170.dp)) {
                            BasicTextField(
                                value = caption,
                                onValueChange = {
                                    caption = if (it.text.length > ClipCaps.MAX_CAPTION)
                                        it.copy(text = it.text.take(ClipCaps.MAX_CAPTION)) else it
                                },
                                textStyle = VoiidFont.rounded(15).copy(color = VoiidColor.textPrimary),
                                cursorBrush = SolidColor(VoiidColor.accent),
                                modifier = Modifier.weight(1f).fillMaxWidth().focusRequester(captionFocus),
                                decorationBox = { inner ->
                                    if (caption.text.isEmpty()) {
                                        Text("Write a caption…", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                                    }
                                    inner()
                                },
                            )
                            Text("${caption.text.length}/${ClipCaps.MAX_CAPTION}", style = VoiidFont.rounded(11),
                                color = VoiidColor.textSecondary, textAlign = TextAlign.End, modifier = Modifier.fillMaxWidth())
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        InsertChip("# Hashtag") { haptics.tap(); insert("#") }
                        InsertChip("@ Mention") { haptics.tap(); insert("@") }
                    }
                }

                // Settings
                Column(Modifier.clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard)) {
                    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        RowIcon(Icons.Default.Public)
                        Text("Who can watch", style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary,
                            modifier = Modifier.weight(1f))
                        Text("Everyone", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                    }
                    RowDivider()
                    ToggleRow(Icons.Default.ChatBubbleOutline, "Allow comments", "People can comment and reply.",
                        allowComments) { haptics.selection(); allowComments = it }
                    // Saving needs Android 10's scoped MediaStore; older phones would need a
                    // storage permission Voiid does not ask for, so the switch is not offered.
                    if (android.os.Build.VERSION.SDK_INT >= 29) RowDivider()
                    if (android.os.Build.VERSION.SDK_INT >= 29) ToggleRow(Icons.Default.Download, "Save to gallery", "Keeps a copy of the finished clip on this phone.",
                        saveToGallery) { haptics.selection(); saveToGallery = it }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
                    Icon(Icons.Default.Info, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(14.dp).padding(top = 2.dp))
                    Text("Clips are public. Unlike your chats and moments, they aren't end-to-end encrypted.",
                        style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                }
                Spacer(Modifier.height(90.dp))
            }
        }

        if (!posting) {
            Row(
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding()
                    .padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth().height(52.dp)
                    .clip(RoundedCornerShape(50)).background(VoiidColor.accent)
                    .softClickable(scale = 0.97f) {
                        haptics.success()
                        posting = true
                        scope.launch {
                            delay(700)
                            onPost(ClipPostChoices(caption.text.trim(), allowComments, saveToGallery))
                        }
                    },
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, null, tint = Color.White, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(8.dp))
                Text("Post clip", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = Color.White)
            }
        }

        AnimatedVisibility(posting, enter = fadeIn(), exit = fadeOut()) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    Box(Modifier.size(width = 120.dp, height = 212.dp).clip(RoundedCornerShape(18.dp)).background(Color.Black),
                        contentAlignment = Alignment.Center) {
                        cover?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)))
                        Box(Modifier.size(64.dp).clip(CircleShape).background(VoiidColor.success), contentAlignment = Alignment.Center) {
                            Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(32.dp))
                        }
                    }
                    Text("Posting your clip", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = Color.White)
                    Text("It's uploading in Clips — you can keep using Voiid.", style = VoiidFont.rounded(13),
                        color = Color.White.copy(alpha = 0.7f), textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 40.dp))
                }
            }
        }
    }
}

@Composable
private fun InsertChip(label: String, onClick: () -> Unit) {
    Box(Modifier.clip(RoundedCornerShape(50)).background(VoiidColor.textPrimary.copy(alpha = 0.07f))
        .softClickable(scale = 0.95f, onClick = onClick).padding(horizontal = 12.dp, vertical = 7.dp)) {
        Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}

@Composable
private fun RowIcon(icon: ImageVector) {
    Icon(icon, null, tint = VoiidColor.accent, modifier = Modifier.size(22.dp))
}

@Composable
private fun RowDivider() {
    Box(Modifier.fillMaxWidth().padding(start = 52.dp).height(1.dp).background(VoiidColor.textPrimary.copy(alpha = 0.07f)))
}

@Composable
private fun ToggleRow(icon: ImageVector, title: String, note: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        RowIcon(icon)
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
            Text(note, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
        Switch(checked = on, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = VoiidColor.accent, checkedThumbColor = Color.White))
    }
}
