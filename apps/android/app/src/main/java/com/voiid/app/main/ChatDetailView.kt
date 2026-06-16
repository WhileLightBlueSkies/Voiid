package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.MessageKind
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import androidx.compose.ui.unit.dp

/** 1:1 / group chat (Figma Screen-11/12) — port of `ChatDetailView.swift`. */
@Composable
fun ChatDetailView(conversation: VConversation, chat: ChatStore, onBack: () -> Unit) {
    BackHandler { onBack() }
    val haptics = LocalVoiidHaptics.current
    var draft by remember { mutableStateOf("") }
    val messages = chat.messages(conversation.id)
    val typing = conversation.id in chat.typingConversations
    val listState = rememberLazyListState()

    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) chat.send("📷 Photo", MessageKind.IMAGE, conversation.id)
    }

    val grouped = messages.sortedBy { it.createdAt }.groupBy { VoiidDate.startOfDay(it.createdAt) }
    val sortedDays = grouped.keys.sorted()
    val itemCount = sortedDays.sumOf { 1 + (grouped[it]?.size ?: 0) } + if (typing) 1 else 0

    LaunchedEffect(messages.size, typing) {
        if (itemCount > 0) listState.animateScrollToItem(itemCount - 1)
    }

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).imePadding(),
    ) {
        // Header
        Column {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(VoiidColor.fieldFill.copy(alpha = 0.6f))
                    .statusBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = VoiidColor.primary,
                    modifier = Modifier.size(24.dp).clickable { haptics.tap(); onBack() },
                )
                VoiidAvatar(size = 35.dp)
                Column(Modifier.weight(1f)) {
                    Text(conversation.title, style = VoiidFont.headline, color = VoiidColor.textPrimary, maxLines = 1)
                    Text(presenceText(conversation, typing), style = VoiidFont.caption, color = VoiidColor.textSecondary, maxLines = 1)
                }
                Icon(Icons.Default.PhotoCamera, "Camera", tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
                Icon(Icons.Default.Call, "Call", tint = VoiidColor.primary, modifier = Modifier.size(22.dp).padding(horizontal = 0.dp))
                Spacer(Modifier.size(4.dp))
                Icon(Icons.Default.MoreVert, "More", tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        }

        // Messages
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxWidth().weight(1f),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            sortedDays.forEach { day ->
                item(key = "sep-$day") { DateSeparator(VoiidDate.separator(day)) }
                items(grouped[day].orEmpty(), key = { it.id }) { msg -> MessageBubble(msg) }
            }
            if (typing) item(key = "typing") { TypingBubble() }
        }

        // Input bar
        Column {
            Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(VoiidColor.fieldFill.copy(alpha = 0.6f))
                    .navigationBarsPadding()
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Default.AddCircle, "Attach", tint = VoiidColor.primary,
                    modifier = Modifier.size(28.dp).clickable {
                        pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                )

                val fieldShape = RoundedCornerShape(VoiidRadius.pill)
                Row(
                    Modifier
                        .weight(1f)
                        .heightIn(min = 44.dp)
                        .clip(fieldShape)
                        .background(VoiidColor.fieldFill)
                        .border(1.dp, VoiidColor.fieldBorder, fieldShape)
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        textStyle = VoiidFont.body.merge(TextStyle(color = VoiidColor.textPrimary)),
                        cursorBrush = SolidColor(VoiidColor.primary),
                        maxLines = 4,
                        modifier = Modifier.weight(1f).padding(vertical = 10.dp),
                        decorationBox = { inner ->
                            Box(contentAlignment = Alignment.CenterStart) {
                                if (draft.isEmpty()) Text("Message", style = VoiidFont.body, color = VoiidColor.placeholder)
                                inner()
                            }
                        },
                    )
                    if (draft.isEmpty()) {
                        Icon(Icons.Default.CameraAlt, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(20.dp))
                    }
                }

                if (draft.trim().isEmpty()) {
                    VoiceRecordButton { duration ->
                        chat.send("🎤 Voice message · ${duration.toInt()}s", MessageKind.VOICE, conversation.id)
                    }
                } else {
                    Icon(
                        Icons.Default.ArrowCircleUp, "Send", tint = VoiidColor.primary,
                        modifier = Modifier.size(32.dp).clickable {
                            haptics.tap()
                            chat.send(draft.trim(), conversationId = conversation.id)
                            draft = ""
                        },
                    )
                }
            }
        }
    }
}

private fun presenceText(conversation: VConversation, typing: Boolean): String = when {
    typing -> "typing…"
    conversation.type == ConversationType.GROUP -> "${conversation.memberCount} members"
    conversation.isOnline -> "Online"
    else -> "last seen recently"
}
