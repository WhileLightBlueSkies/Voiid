package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ChatStore
import com.voiid.app.model.MessageKind
import com.voiid.app.model.VConversation
import com.voiid.app.model.VMessage
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** A small Cancel / title / action sheet header row, mirroring the iOS nav bar in `.sheet`s. */
@Composable
private fun SheetHeader(title: String, leading: String, trailing: String?, trailingEnabled: Boolean, onLeading: () -> Unit, onTrailing: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(leading, style = VoiidFont.rounded(16), color = VoiidColor.primary, modifier = Modifier.clickable { onLeading() })
        Spacer(Modifier.weight(1f))
        Text(title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.weight(1f))
        if (trailing != null) {
            Text(
                trailing,
                style = VoiidFont.rounded(16, FontWeight.SemiBold),
                color = if (trailingEnabled) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.5f),
                modifier = Modifier.clickable(enabled = trailingEnabled) { onTrailing() },
            )
        } else {
            Spacer(Modifier.size(40.dp))
        }
    }
}

@Composable
private fun PillSearchField(query: String, placeholder: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(CircleShape)
            .background(VoiidColor.fieldFill)
            .height(46.dp)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.size(20.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (query.isEmpty()) Text(placeholder, style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
            BasicTextField(
                value = query, onValueChange = onChange, singleLine = true,
                textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
                cursorBrush = SolidColor(VoiidColor.primary), modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// MARK: - Forward sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ForwardSheet(chat: ChatStore, onForward: (List<String>) -> Unit, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val selected = remember { mutableStateListOf<String>() }
    var query by remember { mutableStateOf("") }

    val all = chat.directConversations + chat.groupConversations
    val results = if (query.isBlank()) all else all.filter { it.title.contains(query, ignoreCase = true) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background, dragHandle = null) {
        Column(Modifier.fillMaxHeight(0.9f)) {
            SheetHeader(
                title = "Forward to", leading = "Cancel", trailing = "Send",
                trailingEnabled = selected.isNotEmpty(),
                onLeading = onDismiss,
                onTrailing = { haptics.success(); onForward(selected.toList()); onDismiss() },
            )
            PillSearchField(query, "Search", { query = it }, Modifier.fillMaxWidth().padding(24.dp))
            LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                items(results, key = { it.id }) { c ->
                    val isSel = selected.contains(c.id)
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable {
                                haptics.selection()
                                if (isSel) selected.remove(c.id) else selected.add(c.id)
                            }
                            .padding(horizontal = 24.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        VoiidAvatar(size = 44.dp, modifier = Modifier.clip(CircleShape))
                        Text(c.title, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                        Icon(
                            if (isSel) Icons.Default.CheckCircle else Icons.Outlined.Circle, null,
                            tint = if (isSel) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.5f),
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Message info sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageInfoSheet(message: VMessage, isGroup: Boolean, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background, dragHandle = null) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Text("Message info", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary, modifier = Modifier.align(Alignment.CenterHorizontally))
            // Message preview bubble (right-aligned, sent style)
            Row(Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(1f))
                Text(
                    if (message.kind == MessageKind.TEXT) message.text else "Attachment",
                    style = VoiidFont.rounded(15), color = VoiidColor.textPrimary,
                    modifier = Modifier
                        .clip(bubbleShape(true))
                        .background(VoiidColor.bubbleReceived)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
            ) {
                InfoRow(Icons.Outlined.Circle, VoiidColor.textSecondary, "Delivered", message.deliveredAt)
                HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                InfoRow(Icons.Default.CheckCircle, VoiidColor.primary, "Read", message.readAt)
            }
            if (isGroup) {
                Text(
                    "In groups, delivered/read reflects all members.",
                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun InfoRow(icon: androidx.compose.ui.graphics.vector.ImageVector, color: androidx.compose.ui.graphics.Color, label: String, time: Long?) {
    Row(
        Modifier.fillMaxWidth().padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        Text(label, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        Text(time?.let { VoiidDate.bubbleTime(it) } ?: "—", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
    }
}

// MARK: - Poll compose sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PollComposeSheet(onSend: (String, List<String>) -> Unit, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var question by remember { mutableStateOf("") }
    val options = remember { mutableStateListOf("", "") }
    val valid = question.trim().isNotEmpty() && options.count { it.trim().isNotEmpty() } >= 2

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background, dragHandle = null) {
        Column(Modifier.fillMaxWidth()) {
            SheetHeader(
                title = "New Poll", leading = "Cancel", trailing = "Send", trailingEnabled = valid,
                onLeading = onDismiss,
                onTrailing = {
                    haptics.success()
                    onSend(question.trim(), options.map { it.trim() }.filter { it.isNotEmpty() })
                    onDismiss()
                },
            )
            Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                PollField("Ask a question", question) { question = it }
                Text("Options", style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textSecondary)
                options.forEachIndexed { i, opt ->
                    PollField("Option ${i + 1}", opt) { options[i] = it }
                }
                if (options.size < 6) {
                    Row(
                        Modifier.clickable { haptics.tap(); options.add("") },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Default.Add, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
                        Text("Add option", style = VoiidFont.rounded(15), color = VoiidColor.primary)
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun PollField(placeholder: String, value: String, onChange: (String) -> Unit) {
    val shape = RoundedCornerShape(VoiidRadius.md)
    Box(
        Modifier
            .fillMaxWidth()
            .height(50.dp)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, shape)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        if (value.isEmpty()) Text(placeholder, style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
        BasicTextField(
            value = value, onValueChange = onChange, singleLine = true,
            textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary), modifier = Modifier.fillMaxWidth(),
        )
    }
}
