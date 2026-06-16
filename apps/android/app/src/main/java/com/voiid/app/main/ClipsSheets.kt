package com.voiid.app.main

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.VideoCall
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClipComment
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.components.VoiidTextField
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Clips comments — native Material3 modal bottom sheet (port of iOS `ClipCommentsView` sheet). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ClipCommentsSheet(clips: ClipsStore, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var draft by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background) {
        Column(Modifier.fillMaxHeight(0.85f)) {
            Text("Comments", style = VoiidFont.headline, color = VoiidColor.textPrimary,
                modifier = Modifier.padding(16.dp).align(Alignment.CenterHorizontally))
            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.5f))

            LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp)) {
                items(clips.comments, key = { it.id }) { c -> CommentRow(c) }
            }

            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.5f))
            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(
                    Modifier.weight(1f).height(44.dp).clip(CircleShape).background(VoiidColor.fieldFill).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                        if (draft.isEmpty()) Text("Add a comment…", style = VoiidFont.body, color = VoiidColor.placeholder)
                        BasicTextField(
                            value = draft,
                            onValueChange = { draft = it },
                            singleLine = true,
                            textStyle = VoiidFont.body.merge(TextStyle(color = VoiidColor.textPrimary)),
                            cursorBrush = SolidColor(VoiidColor.primary),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Icon(
                    Icons.Default.ArrowCircleUp, "Send", tint = VoiidColor.primary,
                    modifier = Modifier.size(30.dp).clickable {
                        val t = draft.trim(); if (t.isNotEmpty()) { haptics.tap(); clips.addComment(t); draft = "" }
                    },
                )
            }
        }
    }
}

@Composable
private fun CommentRow(c: VClipComment) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        VoiidAvatar(size = 30.dp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(c.authorName, style = VoiidFont.subhead, color = VoiidColor.textPrimary)
            Text(c.text, style = VoiidFont.footnote, color = VoiidColor.textSecondary)
        }
    }
}

/** New clip upload — native modal bottom sheet (port of iOS `NewClipView` sheet). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewClipSheet(onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf(false) }

    val pickVideo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        picked = uri != null
        if (picked) haptics.success()
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background) {
        Column(
            Modifier.fillMaxWidth().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("New Clip", style = VoiidFont.headline, color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.CenterHorizontally))

            Box(
                Modifier
                    .fillMaxWidth()
                    .height(280.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(VoiidColor.fieldFill)
                    .clickable { pickVideo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(
                        if (picked) Icons.Default.CheckCircle else Icons.Default.VideoCall,
                        null, tint = VoiidColor.primary, modifier = Modifier.size(54.dp),
                    )
                    Text(
                        if (picked) "Video selected" else "Tap to pick a video",
                        style = VoiidFont.body, color = VoiidColor.textSecondary,
                    )
                }
            }

            VoiidTextField(placeholder = "Title", value = title, onValueChange = { title = it })
            VoiidTextField(placeholder = "Description", value = description, onValueChange = { description = it })

            VoiidPrimaryButton(title = "Share", enabled = picked && title.isNotEmpty()) {
                haptics.success(); onDismiss()
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}
