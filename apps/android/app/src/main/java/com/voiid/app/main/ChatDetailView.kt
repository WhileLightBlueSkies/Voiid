package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.automirrored.filled.Forward
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.DummyData
import com.voiid.app.model.MessageKind
import com.voiid.app.model.VConversation
import com.voiid.app.model.VMember
import com.voiid.app.model.VMessage
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** 1:1 / group chat — port of the (refined) `ChatDetailView.swift`. */
@Composable
fun ChatDetailView(
    conversation: VConversation,
    chat: ChatStore,
    onBack: () -> Unit,
    onStartCall: (CallRequest) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val clipboard = LocalClipboardManager.current
    val isGroup = conversation.type == ConversationType.GROUP
    var draft by remember { mutableStateOf("") }
    val messages = chat.messages(conversation.id)
    val typing = conversation.id in chat.typingConversations
    val listState = rememberLazyListState()
    val lastMineId = messages.lastOrNull { it.isMine }?.id
    var showDetails by remember { mutableStateOf(false) }
    var replyingTo by remember { mutableStateOf<VMessage?>(null) }

    // overflow / attach menus
    var showOverflow by remember { mutableStateOf(false) }
    var showAttach by remember { mutableStateOf(false) }

    // sheets / dialogs
    var showPollCompose by remember { mutableStateOf(false) }
    var infoMessage by remember { mutableStateOf<VMessage?>(null) }
    var forwardMessage by remember { mutableStateOf<VMessage?>(null) }
    var deleteMessage by remember { mutableStateOf<VMessage?>(null) }
    var showClearChat by remember { mutableStateOf(false) }

    // multi-select
    var selectionMode by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var showBulkDelete by remember { mutableStateOf(false) }
    var forwardBulk by remember { mutableStateOf(false) }

    fun exitSelection() { selectionMode = false; selectedIds.clear() }
    fun startCall(kind: CallKind) {
        onStartCall(
            CallRequest(
                title = conversation.title, isGroup = isGroup,
                members = if (isGroup) DummyData.groupMembers else emptyList(),
                photoName = conversation.photoName, kind = kind,
            ),
        )
    }

    BackHandler {
        when {
            selectionMode -> exitSelection()
            else -> onBack()
        }
    }

    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) chat.send("📷 Photo", MessageKind.IMAGE, conversation.id)
    }

    val grouped = messages.sortedBy { it.createdAt }.groupBy { VoiidDate.startOfDay(it.createdAt) }
    val sortedDays = grouped.keys.sorted()
    val itemCount = sortedDays.sumOf { 1 + (grouped[it]?.size ?: 0) } + if (typing) 1 else 0

    LaunchedEffect(messages.size, typing) {
        if (itemCount > 0) listState.animateScrollToItem(itemCount - 1)
    }

    // Load cached + sync (fetch + decrypt) the real E2EE messages on open.
    LaunchedEffect(conversation.id) { chat.openConversation(conversation) }

    // Emit typing start/stop on the empty<->non-empty transition (debounced).
    LaunchedEffect(draft.isNotEmpty()) { chat.sendTyping(conversation.id, draft.isNotEmpty()) }

    // @mention support (group only)
    val mentionQuery: String? = if (isGroup) {
        val at = draft.lastIndexOf('@')
        if (at >= 0) {
            val after = draft.substring(at + 1)
            if (after.contains(" ")) null else after
        } else null
    } else null
    val mentionSuggestions: List<VMember> = if (mentionQuery != null) {
        DummyData.groupMembers.filter { !it.isYou && (mentionQuery.isEmpty() || it.name.contains(mentionQuery, ignoreCase = true)) }
    } else emptyList()

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().background(VoiidColor.background).imePadding()) {

            // Header — selection bar or normal
            if (selectionMode) {
                Row(
                    Modifier.fillMaxWidth().background(VoiidColor.background).statusBarsPadding()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("Cancel", style = VoiidFont.rounded(16), color = VoiidColor.primary, modifier = Modifier.clickable { exitSelection() })
                    Text("${selectedIds.size} selected", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Icon(
                        Icons.AutoMirrored.Filled.Forward, "Forward",
                        tint = if (selectedIds.isEmpty()) VoiidColor.primary.copy(alpha = 0.4f) else VoiidColor.primary,
                        modifier = Modifier.size(20.dp).clickable(enabled = selectedIds.isNotEmpty()) { forwardBulk = true },
                    )
                    Icon(
                        Icons.Default.Delete, "Delete",
                        tint = if (selectedIds.isEmpty()) VoiidColor.error.copy(alpha = 0.4f) else VoiidColor.error,
                        modifier = Modifier.size(20.dp).clickable(enabled = selectedIds.isNotEmpty()) { showBulkDelete = true },
                    )
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().background(VoiidColor.background).statusBarsPadding()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Default.ChevronLeft, "Back", tint = VoiidColor.textPrimary,
                        modifier = Modifier.size(28.dp).clickable { haptics.tap(); onBack() },
                    )
                    Row(
                        modifier = Modifier.weight(1f).clickable(
                            interactionSource = remember { MutableInteractionSource() }, indication = null,
                        ) { haptics.tap(); showDetails = true },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        VoiidAvatar(size = 36.dp, modifier = Modifier.clip(CircleShape))
                        Column(Modifier.weight(1f)) {
                            Text(conversation.title, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1)
                            Text(
                                presenceText(conversation, typing), style = VoiidFont.rounded(11),
                                color = if (typing) VoiidColor.primary else VoiidColor.textSecondary, maxLines = 1,
                            )
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Call, "Voice call", tint = VoiidColor.textPrimary, modifier = Modifier.size(18.dp).clickable { haptics.tap(); startCall(CallKind.VOICE) })
                        Icon(Icons.Default.Videocam, "Video call", tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp).clickable { haptics.tap(); startCall(CallKind.VIDEO) })
                        Box {
                            Icon(Icons.Default.MoreHoriz, "More", tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp).clickable { showOverflow = true })
                            DropdownMenu(expanded = showOverflow, onDismissRequest = { showOverflow = false }) {
                                DropdownMenuItem(
                                    text = { Text(if (isGroup) "Group info" else "View profile") },
                                    onClick = { showOverflow = false; showDetails = true },
                                    leadingIcon = { Icon(Icons.Default.Info, null) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Select messages") },
                                    onClick = { showOverflow = false; selectionMode = true },
                                    leadingIcon = { Icon(Icons.Default.CheckCircle, null) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Clear chat", color = VoiidColor.error) },
                                    onClick = { showOverflow = false; showClearChat = true },
                                    leadingIcon = { Icon(Icons.Default.Delete, null, tint = VoiidColor.error) },
                                )
                            }
                        }
                    }
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
                        MessageBubble(
                            message = msg,
                            isLastMine = msg.id == lastMineId,
                            isGroup = isGroup,
                            selectionMode = selectionMode,
                            selected = selectedIds.contains(msg.id),
                            onSelectTap = {
                                haptics.selection()
                                if (selectedIds.contains(msg.id)) selectedIds.remove(msg.id) else selectedIds.add(msg.id)
                            },
                            onReply = { replyingTo = msg },
                            onForward = { forwardMessage = msg },
                            onReact = { e -> chat.react(msg.id, e, conversation.id); haptics.tap() },
                            onCopy = { clipboard.setText(AnnotatedString(msg.text)) },
                            onInfo = { infoMessage = msg },
                            onDelete = { deleteMessage = msg },
                            onVote = { optId -> chat.vote(msg.id, optId, conversation.id) },
                        )
                    }
                }
                if (typing) item(key = "typing") { TypingBubble() }
            }

            // Input area (reply preview + mention strip + input row)
            Column(Modifier.fillMaxWidth().background(VoiidColor.background).navigationBarsPadding()) {
                // Reply preview
                replyingTo?.let { r ->
                    Row(
                        Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(Modifier.width(3.dp).size(width = 3.dp, height = 32.dp).clip(RoundedCornerShape(2.dp)).background(VoiidColor.primary))
                        Column(Modifier.weight(1f)) {
                            Text(
                                if (r.isMine) "You" else r.senderName.ifEmpty { conversation.title },
                                style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.primary,
                            )
                            Text(
                                if (r.kind == MessageKind.TEXT) r.text else "Attachment",
                                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, maxLines = 1,
                            )
                        }
                        Icon(Icons.Default.Close, "Cancel reply", tint = VoiidColor.textSecondary, modifier = Modifier.size(16.dp).clickable { replyingTo = null })
                    }
                }
                // @mention suggestions
                if (mentionSuggestions.isNotEmpty()) {
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        mentionSuggestions.forEach { m ->
                            Row(
                                Modifier
                                    .clip(CircleShape)
                                    .background(VoiidColor.surfaceCard)
                                    .clickable {
                                        val at = draft.lastIndexOf('@')
                                        if (at >= 0) draft = draft.substring(0, at) + "@${m.name} "
                                        haptics.selection()
                                    }
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                VoiidAvatar(size = 26.dp, modifier = Modifier.clip(CircleShape))
                                Text(m.name, style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textPrimary)
                            }
                        }
                    }
                }

                // Input row
                val hasText = draft.trim().isNotEmpty()
                val pillShape = RoundedCornerShape(VoiidRadius.pill)
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
                    Box {
                        Icon(
                            Icons.Outlined.AddCircleOutline, "Attach", tint = VoiidColor.textPrimary,
                            modifier = Modifier.size(26.dp).clickable { showAttach = true },
                        )
                        DropdownMenu(expanded = showAttach, onDismissRequest = { showAttach = false }) {
                            DropdownMenuItem(
                                text = { Text("Photo") },
                                onClick = {
                                    showAttach = false
                                    pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                                },
                                leadingIcon = { Icon(Icons.Default.Photo, null) },
                            )
                            if (isGroup) {
                                DropdownMenuItem(
                                    text = { Text("Poll") },
                                    onClick = { showAttach = false; showPollCompose = true },
                                    leadingIcon = { Icon(Icons.Default.BarChart, null) },
                                )
                            }
                        }
                    }
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
                            modifier = Modifier.size(20.dp).clickable {
                                haptics.tap()
                                chat.send(draft.trim(), conversationId = conversation.id, replyTo = replyingTo)
                                draft = ""; replyingTo = null
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

        // Chat details / profile overlay
        AnimatedVisibility(
            visible = showDetails,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = slideOutHorizontally { it } + fadeOut(),
        ) {
            if (isGroup) {
                GroupInfoView(conversation = conversation, onBack = { showDetails = false })
            } else {
                ContactProfileView(conversation = conversation, onBack = { showDetails = false })
            }
        }
    }

    // Sheets
    if (showPollCompose) {
        PollComposeSheet(onSend = { q, opts -> chat.sendPoll(q, opts, conversation.id) }, onDismiss = { showPollCompose = false })
    }
    infoMessage?.let { m ->
        MessageInfoSheet(message = m, isGroup = isGroup, onDismiss = { infoMessage = null })
    }
    forwardMessage?.let { m ->
        ForwardSheet(chat = chat, onForward = { targets -> chat.forward(m, targets) }, onDismiss = { forwardMessage = null })
    }
    if (forwardBulk) {
        ForwardSheet(
            chat = chat,
            onForward = { targets ->
                messages.filter { selectedIds.contains(it.id) }.forEach { chat.forward(it, targets) }
                exitSelection()
            },
            onDismiss = { forwardBulk = false },
        )
    }

    // Dialogs
    deleteMessage?.let { m ->
        AlertDialog(
            onDismissRequest = { deleteMessage = null },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Delete message?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = null,
            confirmButton = {
                Column {
                    if (m.isMine) {
                        TextButton(onClick = { chat.deleteMessage(m.id, conversation.id, true); deleteMessage = null }) {
                            Text("Delete for everyone", color = VoiidColor.error)
                        }
                    }
                    TextButton(onClick = { chat.deleteMessage(m.id, conversation.id, false); deleteMessage = null }) {
                        Text("Delete for me", color = VoiidColor.error)
                    }
                }
            },
            dismissButton = { TextButton(onClick = { deleteMessage = null }) { Text("Cancel", color = VoiidColor.primary) } },
        )
    }
    if (showClearChat) {
        AlertDialog(
            onDismissRequest = { showClearChat = false },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Clear this chat?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = { Text("All messages will be removed from this chat.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) },
            confirmButton = { TextButton(onClick = { chat.clearChat(conversation.id); showClearChat = false }) { Text("Clear chat", color = VoiidColor.error) } },
            dismissButton = { TextButton(onClick = { showClearChat = false }) { Text("Cancel", color = VoiidColor.primary) } },
        )
    }
    if (showBulkDelete) {
        AlertDialog(
            onDismissRequest = { showBulkDelete = false },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Delete ${selectedIds.size} message${if (selectedIds.size == 1) "" else "s"}?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = { Text("This will delete the selected messages.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    selectedIds.toList().forEach { chat.deleteMessage(it, conversation.id, false) }
                    showBulkDelete = false; exitSelection()
                }) { Text("Delete", color = VoiidColor.error) }
            },
            dismissButton = { TextButton(onClick = { showBulkDelete = false }) { Text("Cancel", color = VoiidColor.primary) } },
        )
    }
}

private fun presenceText(conversation: VConversation, typing: Boolean): String = when {
    typing -> "typing…"
    conversation.type == ConversationType.GROUP -> "${conversation.memberCount} members"
    conversation.isOnline -> "Online"
    else -> "last seen recently"
}
