package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.PhotoCamera
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
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.MessageKind
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** 1:1 / group chat — port of the (refined) `ChatDetailView.swift`. */
@Composable
fun ChatDetailView(conversation: VConversation, chat: ChatStore, onBack: () -> Unit) {
    BackHandler { onBack() }
    val haptics = LocalVoiidHaptics.current
    var draft by remember { mutableStateOf("") }
    val messages = chat.messages(conversation.id)
    val typing = conversation.id in chat.typingConversations
    val listState = rememberLazyListState()
    val lastMineId = messages.lastOrNull { it.isMine }?.id
    var showDetails by remember { mutableStateOf(false) }

    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) chat.send("📷 Photo", MessageKind.IMAGE, conversation.id)
    }

    val grouped = messages.sortedBy { it.createdAt }.groupBy { VoiidDate.startOfDay(it.createdAt) }
    val sortedDays = grouped.keys.sorted()
    val itemCount = sortedDays.sumOf { 1 + (grouped[it]?.size ?: 0) } + if (typing) 1 else 0

    LaunchedEffect(messages.size, typing) {
        if (itemCount > 0) listState.animateScrollToItem(itemCount - 1)
    }

    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().background(VoiidColor.background).imePadding()) {

        // Header — back · avatar · name/presence · camera · phone · ⋯ (no divider, bg = background)
        Row(
            Modifier
                .fillMaxWidth()
                .background(VoiidColor.background)
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Default.ChevronLeft, "Back", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(28.dp).clickable { haptics.tap(); onBack() },
            )
            // Tap avatar/name → chat details (profile)
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                        haptics.tap(); showDetails = true
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                VoiidAvatar(size = 36.dp, modifier = Modifier.clip(CircleShape))
                Column(Modifier.weight(1f)) {
                    Text(conversation.title, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1)
                    Text(
                        presenceText(conversation, typing),
                        style = VoiidFont.rounded(11),
                        color = if (typing) VoiidColor.primary else VoiidColor.textSecondary,
                        maxLines = 1,
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.PhotoCamera, "Camera", tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp))
                Icon(Icons.Default.Call, "Call", tint = VoiidColor.textPrimary, modifier = Modifier.size(18.dp))
                Icon(Icons.Default.MoreHoriz, "More", tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp))
            }
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
                items(grouped[day].orEmpty(), key = { it.id }) { msg ->
                    MessageBubble(msg, isLastMine = msg.id == lastMineId, isGroup = conversation.type == ConversationType.GROUP)
                }
            }
            if (typing) item(key = "typing") { TypingBubble() }
        }

        // Input bar — single pink pill: ⊕ · field · send/voice
        val hasText = draft.trim().isNotEmpty()
        val pillShape = RoundedCornerShape(VoiidRadius.pill)
        Box(Modifier.fillMaxWidth().background(VoiidColor.background).navigationBarsPadding()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(pillShape)
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, pillShape)
                    .padding(start = 8.dp, top = 4.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Outlined.AddCircleOutline, "Attach", tint = VoiidColor.textPrimary,
                    modifier = Modifier.size(26.dp).clickable {
                        pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                )
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    maxLines = 5,
                    modifier = Modifier.weight(1f).heightIn(min = 46.dp).padding(horizontal = 16.dp),
                )
                if (hasText) {
                    Icon(
                        Icons.AutoMirrored.Filled.Send, "Send", tint = VoiidColor.primary,
                        modifier = Modifier
                            .size(20.dp)
                            .clickable {
                                haptics.tap()
                                chat.send(draft.trim(), conversationId = conversation.id)
                                draft = ""
                            },
                    )
                } else {
                    VoiceRecordButton { duration ->
                        chat.send("🎤 Voice message · ${duration.toInt()}s", MessageKind.VOICE, conversation.id)
                    }
                }
                Spacer(Modifier.size(8.dp))
            }
        }
    }

        // Chat details / profile overlay (opened by tapping the name/avatar in the header)
        AnimatedVisibility(
            visible = showDetails,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = slideOutHorizontally { it } + fadeOut(),
        ) {
            if (conversation.type == ConversationType.GROUP) {
                GroupInfoView(conversation = conversation, onBack = { showDetails = false })
            } else {
                ContactProfileView(conversation = conversation, onBack = { showDetails = false })
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
