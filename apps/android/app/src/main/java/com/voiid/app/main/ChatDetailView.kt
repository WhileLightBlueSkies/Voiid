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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Forward
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.Mood
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import kotlinx.coroutines.launch

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
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val isGroup = conversation.type == ConversationType.GROUP
    /** Note to Self has no second party — no profile to open, no presence, no verification. */
    val isSelfChat = conversation.type == ConversationType.SELF
    var draft by remember { mutableStateOf("") }
    // Recording state is hoisted HERE, not owned by the mic button: the RecordingBar is a
    // sibling that replaces the composer row, so both need to read it.
    var isRecording by remember { mutableStateOf(false) }
    var recordingDiscarding by remember { mutableStateOf(false) }
    var recordingCancelRequest by remember { mutableStateOf(0) }
    var recordingError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(recordingDiscarding) {
        if (recordingDiscarding) {
            kotlinx.coroutines.delay(240)
            recordingDiscarding = false
        }
    }
    var recDragX by remember { mutableFloatStateOf(0f) }
    var recSeconds by remember { mutableFloatStateOf(0f) }
    val messages = chat.messages(conversation.id)
    val typing = conversation.id in chat.typingConversations
    val listState = rememberLazyListState()
    val notificationTarget by com.voiid.app.net.DeepLinkRouter.pendingMessage.collectAsState()
    var notificationPositioned by remember(conversation.id) { mutableStateOf(false) }
    val lastMineId = messages.lastOrNull { it.isMine }?.id
    var showDetails by remember { mutableStateOf(false) }
    var replyingTo by remember { mutableStateOf<VMessage?>(null) }
    // REAL group members (from the server) for @mentions + group-call tiles — never DummyData.
    var groupMembers by remember { mutableStateOf<List<VMember>>(emptyList()) }
    LaunchedEffect(conversation.id) {
        if (isGroup) {
            groupMembers = runCatching { com.voiid.app.net.ChatService(context).fetchMembers(conversation.id) }
                .getOrDefault(emptyList())
                .map { VMember(id = it.userId, name = it.name, phone = "", role = com.voiid.app.model.MemberRole.MEMBER, isYou = it.isYou) }
        }
    }

    // overflow / attach menus
    var showOverflow by remember { mutableStateOf(false) }
    // The safety-number screen (anti-MITM verification). A full-screen overlay like the profile,
    // not a bottom sheet: the number is read aloud digit by digit, so it needs the whole width.
    var showSafetyNumber by remember { mutableStateOf(false) }
    var showAttach by remember { mutableStateOf(false) }

    // sheets / dialogs
    var showPollCompose by remember { mutableStateOf(false) }
    var showGifPicker by remember { mutableStateOf(false) }
    var showLocation by remember { mutableStateOf(false) }
    var showLudoSetup by remember { mutableStateOf(false) }
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
                members = if (isGroup) groupMembers else emptyList(),
                photoName = conversation.photoName, kind = kind,
                conversationId = conversation.id, peerUserId = conversation.peerUserId,
            ),
        )
    }

    BackHandler {
        when {
            selectionMode -> exitSelection()
            else -> onBack()
        }
    }

    var cameraPath by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf<String?>(null) }
    // A picked file over 25 MB that needs a choice (a video, a PDF) — the compress sheet.
    var oversize by remember { mutableStateOf<com.voiid.app.net.ChatOversizeFile?>(null) }
    var preparingAttachment by remember { mutableStateOf(false) }

    fun sendPickedMedia(uri: android.net.Uri, capturedFile: java.io.File? = null) {
        scope.launch {
            try {
                val picked = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    com.voiid.app.net.ChatAttachmentIntake.describe(context, uri)
                }
                // Over the limit: a video asks how to shrink it; a photo is shrunk quietly.
                if (picked.bytes > com.voiid.app.net.ChatMediaLimit.BYTES && picked.mime.startsWith("video/")) {
                    preparingAttachment = true
                    oversize = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        com.voiid.app.net.ChatAttachmentIntake.oversize(context, picked)
                    }
                    preparingAttachment = false
                    return@launch
                }
                val (bytes, mime) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    val type = picked.mime.takeIf { it != "application/octet-stream" } ?: "image/jpeg"
                    val data = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        ?: throw java.io.IOException("Media unavailable")
                    if (data.isEmpty()) throw java.io.IOException("Empty media")
                    if (data.size > com.voiid.app.net.ChatMediaLimit.BYTES && type.startsWith("image/")) {
                        val fitted = com.voiid.app.net.ChatPhotoCompressor.fit(data)
                            ?: throw java.io.IOException("Unreadable photo")
                        fitted to "image/jpeg"
                    } else data to type
                }
                chat.sendMedia(bytes, mime, conversationId = conversation.id)
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                chat.actionError = "Couldn’t open this photo or video. Please try again."
            } finally { capturedFile?.delete() }
        }
    }
    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) sendPickedMedia(uri)
    }

    /** A compressed file (or one under the limit) read from disk and sent. */
    fun sendPreparedFile(file: java.io.File, mime: String, documentName: String?) {
        scope.launch {
            val data = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                runCatching { file.readBytes() }.getOrNull()
            }
            cleanUpCompressed(context, file, oversize?.file)
            if (data == null) {
                chat.actionError = "Couldn't read that file."
                return@launch
            }
            chat.sendMedia(data, mime, caption = documentName ?: "", conversationId = conversation.id,
                filename = documentName)
        }
    }

    val pickDocument = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            preparingAttachment = true
            try {
                val picked = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    com.voiid.app.net.ChatAttachmentIntake.describe(context, uri)
                }
                if (picked.bytes > com.voiid.app.net.ChatMediaLimit.BYTES) {
                    oversize = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        com.voiid.app.net.ChatAttachmentIntake.oversize(context, picked)
                    }
                } else {
                    val data = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
                    }
                    if (data == null || data.isEmpty()) chat.actionError = "Couldn't read that file."
                    else chat.sendMedia(data, picked.mime, caption = picked.name, conversationId = conversation.id,
                        filename = picked.name)
                }
            } finally {
                preparingAttachment = false
            }
        }
    }
    val takePhoto = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val file = cameraPath?.let { java.io.File(it) }
        cameraPath = null
        if (saved && file != null) {
            val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.chatmedia", file)
            sendPickedMedia(uri, file)
        } else file?.delete()
    }
    // The Voiid camera (face filters included) rather than the system camera intent.
    var showVoiidCamera by remember { mutableStateOf(false) }
    fun openCamera() { showVoiidCamera = true }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) openCamera() else chat.actionError = "Allow camera access in Settings to take a photo."
    }
    fun requestCamera() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA)
            == android.content.pm.PackageManager.PERMISSION_GRANTED) openCamera()
        else cameraPermission.launch(android.Manifest.permission.CAMERA)
    }

    val grouped = messages.sortedBy { it.createdAt }.groupBy { VoiidDate.startOfDay(it.createdAt) }
    val sortedDays = grouped.keys.sorted()
    val itemCount = sortedDays.sumOf { 1 + (grouped[it]?.size ?: 0) } + if (typing) 1 else 0

    val hasEncryptionNotice = !isSelfChat
    LaunchedEffect(notificationTarget?.requestId, conversation.id) {
        val target = notificationTarget?.takeIf { it.conversationId == conversation.id } ?: return@LaunchedEffect
        if (messages.none { it.id == target.messageId }) chat.syncMessages(conversation)
    }
    LaunchedEffect(notificationTarget, messages.map { it.id }) {
        val target = notificationTarget?.takeIf { it.conversationId == conversation.id } ?: return@LaunchedEffect
        val rowIds = buildList {
            if (hasEncryptionNotice) add("e2ee-notice")
            sortedDays.forEach { day ->
                add("sep-$day")
                addAll(grouped[day].orEmpty().map { it.id })
            }
        }
        val index = rowIds.indexOf(target.messageId)
        if (index >= 0) {
            notificationPositioned = true
            listState.scrollToItem(index)
            com.voiid.app.net.DeepLinkRouter.consumeMessage(target)
        }
    }
    var previousMessageCount by remember(conversation.id) { mutableStateOf(0) }
    LaunchedEffect(messages.size, typing) {
        val oldCount = previousMessageCount
        previousMessageCount = messages.size
        val layout = listState.layoutInfo
        val nearBottom = (layout.visibleItemsInfo.lastOrNull()?.index ?: 0) >= layout.totalItemsCount - 3
        val appendedOwnMessage = messages.size > oldCount && messages.lastOrNull()?.isMine == true
        if (!notificationPositioned && notificationTarget?.conversationId != conversation.id && itemCount > 0) {
            val target = itemCount - 1 + if (hasEncryptionNotice) 1 else 0
            if (oldCount == 0) listState.scrollToItem(target)
            else if (messages.size >= oldCount && (nearBottom || appendedOwnMessage)) listState.animateScrollToItem(target)
        }
    }

    // Load cached + sync (fetch + decrypt) the real E2EE messages on open.
    // Open on entry, CLOSE on exit — the close is what stops read receipts firing for this
    // chat once the user has navigated away.
    androidx.compose.runtime.DisposableEffect(conversation.id) {
        chat.openConversation(conversation)
        onDispose { chat.closeConversation(conversation.id) }
    }
    // Call bubbles come from the local call_history table, not the message store, so they are
    // loaded alongside the transcript rather than arriving through sync. Re-loaded whenever a
    // call finishes (state → null) so a call made from THIS chat leaves its bubble behind
    // immediately, instead of only on the next open.
    val callState by com.voiid.app.net.CallManager.state.collectAsState()
    LaunchedEffect(conversation.id, callState == null) { chat.loadCallLogs(conversation.id) }

    // Location: wire the relay seam + reconcile any live shares for this chat (docs/LOCATION.md).
    LaunchedEffect(conversation.id) { com.voiid.app.net.LocationShareEngine.refresh(context) }

    // Poll the conversation while open — fetch+decrypt new messages, send receipts,
    // refresh presence — so delivery doesn't depend on the (sometimes-dropped) WS push.
    LaunchedEffect(conversation.id) {
        while (true) {
            chat.syncMessages(conversation)
            kotlinx.coroutines.delay(4_000)
        }
    }

    // Emit typing on the empty<->non-empty transition ONLY — never per keystroke, which
    // would push a redundant identical frame for every character typed.
    //
    // While still typing, REFRESH it every 5s: the receiver expires a stale indicator after
    // 8s (a "stop" is not guaranteed to arrive), so without a heartbeat a slow typist's
    // indicator would vanish mid-sentence.
    val isTyping = draft.isNotEmpty()
    LaunchedEffect(isTyping) {
        chat.sendTyping(conversation.id, isTyping)
        // Only the typing branch loops. LaunchedEffect cancels this coroutine the moment the
        // key flips, so the loop exits by CANCELLATION rather than by its own condition —
        // `isTyping` is captured and never changes inside the body.
        if (!isTyping) return@LaunchedEffect
        while (true) {
            kotlinx.coroutines.delay(5_000)
            chat.sendTyping(conversation.id, true)
        }
    }

    // @mention support (group only)
    val mentionQuery: String? = if (isGroup) {
        val at = draft.lastIndexOf('@')
        if (at >= 0) {
            val after = draft.substring(at + 1)
            if (after.contains(" ")) null else after
        } else null
    } else null
    val mentionSuggestions: List<VMember> = if (mentionQuery != null) {
        groupMembers.filter { !it.isYou && (mentionQuery.isEmpty() || it.name.contains(mentionQuery, ignoreCase = true)) }
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
                    Text("All", color = VoiidColor.primary, modifier = Modifier.clickable {
                        selectedIds.clear()
                        selectedIds.addAll(messages.filter { it.call == null && it.kind != MessageKind.SYSTEM }.map { it.id })
                    })
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
                    androidx.compose.material3.IconButton(onClick = { haptics.tap(); onBack() }, modifier = Modifier.size(44.dp)) {
                        Icon(Icons.Default.ChevronLeft, "Back", tint = VoiidColor.textPrimary, modifier = Modifier.size(28.dp))
                    }
                    Row(
                        modifier = Modifier.weight(1f).clickable(
                            interactionSource = remember { MutableInteractionSource() }, indication = null,
                        ) { if (!isSelfChat) { haptics.tap(); showDetails = true } },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        ProfileAvatar(photoUrl = conversation.photoURL, name = conversation.title, size = 36.dp)
                        Column(Modifier.weight(1f)) {
                            Text(conversation.title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1)
                            Text(
                                presenceText(context, chat.directConversations.firstOrNull { it.id == conversation.id } ?: conversation, typing), style = VoiidFont.rounded(12, FontWeight.Medium),
                                color = if (typing) VoiidColor.primary else VoiidColor.textSecondary, maxLines = 1,
                            )
                        }
                    }
                    Row(
                        modifier = Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(24.dp)).background(VoiidColor.fieldFill),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        androidx.compose.material3.IconButton(onClick = { haptics.tap(); startCall(CallKind.VOICE) }, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Default.Call, "Voice call", tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp))
                        }
                        Box(Modifier.width(1.dp).height(20.dp).background(VoiidColor.divider))
                        androidx.compose.material3.IconButton(onClick = { haptics.tap(); startCall(CallKind.VIDEO) }, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Default.Videocam, "Video call", tint = VoiidColor.textPrimary, modifier = Modifier.size(23.dp))
                        }
                    }
                }
            }

            // Persistent "sharing live location" banner for THIS chat (docs/LOCATION.md §8.A).
            LocationBanner(conversationId = conversation.id)

            // "Ongoing call — Join". Groups only: a 1:1 call rings the peer directly, so there
            // is no such thing as a 1:1 call you could be missing quietly.
            if (isGroup) {
                OngoingCallBanner(conversationId = conversation.id) { startCall(CallKind.VOICE) }
            }

            // Messages
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxWidth().weight(1f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Always retain the badge at the beginning of the transcript.
                if (hasEncryptionNotice) {
                    item(key = "e2ee-notice") {
                        EncryptionNotice(
                            canVerify = conversation.peerUserId != null,
                            onVerify = { haptics.tap(); showSafetyNumber = true },
                        )
                    }
                }
                sortedDays.forEach { day ->
                    item(key = "sep-$day") { DateSeparator(VoiidDate.separator(day)) }
                    items(grouped[day].orEmpty(), key = { it.id }) { msg ->
                        androidx.compose.runtime.CompositionLocalProvider(LocalMessageRetry provides { m -> chat.retryFailed(m) }) {
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
                            onSelect = {
                                // Enter selection ALREADY holding this message. The old
                                // overflow item entered empty, which made the first tap
                                // afterwards mean something different from every tap after it.
                                haptics.selection()
                                selectionMode = true
                                selectedIds.clear(); selectedIds.add(msg.id)
                            },
                            onReply = { replyingTo = msg },
                            onForward = { forwardMessage = msg },
                            onReact = { e -> chat.react(msg.id, e, conversation.id); haptics.tap() },
                            onCopy = { clipboard.setText(AnnotatedString(msg.text)) },
                            // Tap a call bubble to call back with the SAME kind.
                            onCallBack = { isVideo -> startCall(if (isVideo) CallKind.VIDEO else CallKind.VOICE) },
                            onInfo = { infoMessage = msg },
                            onDelete = { deleteMessage = msg },
                            onVote = { optId -> chat.vote(msg.id, optId, conversation.id) },
                        )
                        }
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
                val pillShape = RoundedCornerShape(22.dp)

                // RECORDING IS A MODAL STATE and takes the whole row. The bar cannot live
                // inside the mic button — a 44dp capsule in a 32dp slot overflowed and fought
                // the text field for space, which is what made the old one look broken.
                //
                // The mic itself stays MOUNTED in both branches (below), only hidden. Swapping
                // it out mid-gesture destroys the composable that owns the pointer loop, which
                // is exactly how the iOS version lost its drag callbacks.
                val recordingOverlay = isRecording || recordingDiscarding
                Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
                    // Preserve the mic's position and dimensions for the entire gesture.
                    Row(Modifier.fillMaxWidth().alpha(if (recordingOverlay) 0f else 1f),
                        verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Box {
                            androidx.compose.material3.IconButton(
                                onClick = { haptics.tap(); showAttach = true }, enabled = !recordingOverlay,
                                modifier = Modifier.size(46.dp)) {
                                Icon(Icons.Default.Add, "Attach", tint = VoiidColor.primary, modifier = Modifier.size(25.dp))
                            }
                        ChatAttachSheet(
                            visible = showAttach,
                            allowsPoll = isGroup,
                            onDismiss = { showAttach = false },
                        ) { action ->
                            showAttach = false
                            when (action) {
                                ChatAttachAction.PHOTOS -> pickMedia.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                                ChatAttachAction.CAMERA -> requestCamera()
                                ChatAttachAction.DOCUMENT -> pickDocument.launch(arrayOf("*/*"))
                                ChatAttachAction.LOCATION -> showLocation = true
                                ChatAttachAction.GAME -> showLudoSetup = true
                                ChatAttachAction.POLL -> showPollCompose = true
                            }
                        }
                        }
                        Row(Modifier.weight(1f).clip(pillShape).background(VoiidColor.fieldFill)
                            .border(1.dp, VoiidColor.fieldBorder, pillShape)
                            .padding(start = 14.dp, end = 2.dp), verticalAlignment = Alignment.Bottom) {
                            Box(Modifier.weight(1f).padding(vertical = 12.dp)) {
                                if (draft.isEmpty()) Text("Message", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                                BasicTextField(value = draft, onValueChange = { draft = it }, enabled = !recordingOverlay,
                                    textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary, lineHeight = 22.sp)),
                                    cursorBrush = SolidColor(VoiidColor.primary), minLines = 1, maxLines = 6,
                                    // Let the native text field own scrolling and cursor tracking.
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 22.dp))
                            }
                            if (!hasText) androidx.compose.material3.IconButton(onClick = { haptics.tap(); showGifPicker = true },
                                enabled = !recordingOverlay, modifier = Modifier.size(44.dp)) {
                                Icon(Icons.Outlined.Mood, "GIFs", tint = VoiidColor.textSecondary, modifier = Modifier.size(22.dp))
                            }
                            if (!hasText) androidx.compose.material3.IconButton(onClick = { haptics.tap(); requestCamera() },
                                enabled = !recordingOverlay, modifier = Modifier.size(44.dp)) {
                                Icon(Icons.Default.CameraAlt, "Camera", tint = VoiidColor.textSecondary, modifier = Modifier.size(21.dp))
                            }
                        }
                        Box(Modifier.size(46.dp), contentAlignment = Alignment.Center) {
                            Box(Modifier.alpha(if (hasText || recordingDiscarding) 0f else 1f)) {
                                VoiceRecordButton(
                                    onSend = { bytes, duration ->
                                        chat.sendMedia(bytes, "audio/m4a", caption = "Voice · ${duration.toInt()}s", conversationId = conversation.id)
                                    },
                                    onRecordingChange = { isRecording = it }, onDrag = { recDragX = it }, onTick = { recSeconds = it },
                                    cancelRequest = recordingCancelRequest, enabled = !hasText && !recordingDiscarding,
                                    onDiscard = { recordingDiscarding = true }, onError = { recordingError = it },
                                )
                            }
                            if (hasText) androidx.compose.material3.IconButton(
                                onClick = {
                                    haptics.tap()
                                    chat.send(draft.trim(), conversationId = conversation.id, replyTo = replyingTo)
                                    draft = ""; replyingTo = null
                                }, enabled = !recordingOverlay,
                                modifier = Modifier.size(44.dp).clip(CircleShape).background(VoiidColor.primary)) {
                                Icon(Icons.Default.ArrowUpward, "Send", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(23.dp))
                            }
                        }
                    }
                    if (recordingOverlay) RecordingBar(seconds = recSeconds, dragX = recDragX,
                        isDiscarding = recordingDiscarding, onCancel = { recordingCancelRequest++ })
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
                GroupInfoView(conversation = conversation, chat = chat, onBack = { showDetails = false }, onStartCall = { kind -> showDetails = false; startCall(kind) })
            } else if (isSelfChat) {
                // ContactProfileView would open, find peerUserId == null, and render a
                // profile of nobody. There is no second person to show.
                Unit
            } else {
                ContactProfileView(
                    conversation = conversation,
                    onBack = { showDetails = false },
                    // The profile asks the CHAT to place the call — ChatDetailView already owns
                    // peer resolution and the group-call lock, so this stays one code path.
                    onStartCall = { kind -> showDetails = false; startCall(kind) },
                    // Same delegation as the call above: the chat owns the store, so the
                    // profile asks rather than reaching for it.
                    onClearChat = { showDetails = false; chat.clearChat(conversation.id) },
                )
            }
        }

        // Safety number (verify encryption) — mirrors iOS `SafetyNumberView`.
        AnimatedVisibility(
            visible = showSafetyNumber,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = slideOutHorizontally { it } + fadeOut(),
        ) {
            SafetyNumberScreen(
                peerUserId = conversation.peerUserId.orEmpty(),
                peerName = conversation.title,
                onClose = { showSafetyNumber = false },
            )
        }
    }

    // Sheets
    if (showGifPicker) {
        GifPickerSheet(
            onDismiss = { showGifPicker = false },
            onPick = { bytes ->
                // A GIF is ORDINARY E2EE MEDIA once it reaches here — same encrypt-and-upload
                // path as a photo. The recipient never contacts Tenor, so no third party learns
                // who received what, and the GIF survives the provider deleting it.
                chat.sendMedia(bytes, "image/gif", conversationId = conversation.id)
            },
        )
    }
    ChatCompressSheet(
        file = oversize,
        onDismiss = {
            // Our own copy of the original is dropped whether it was sent or not.
            oversize?.file?.let { com.voiid.app.net.ChatAttachmentIntake.removeTemporary(context, it) }
            oversize = null
        },
        onReady = { file, mime, name -> sendPreparedFile(file, mime, name) },
    )

    if (preparingAttachment) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Row(Modifier.clip(RoundedCornerShape(50)).background(VoiidColor.surfaceCard)
                .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                androidx.compose.material3.CircularProgressIndicator(color = VoiidColor.primary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                Text("Preparing…", style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.textPrimary)
            }
        }
    }

    if (showPollCompose) {
        PollComposeSheet(onSend = { q, opts -> chat.sendPoll(q, opts, conversation.id) }, onDismiss = { showPollCompose = false })
    }
    if (showVoiidCamera) {
        com.voiid.app.main.camera.VoiidPhotoCameraDialog(
            onPhoto = { bytes -> chat.sendMedia(bytes, "image/jpeg", conversationId = conversation.id) },
            onDismiss = { showVoiidCamera = false },
        )
    }
    if (showLocation) {
        LocationComposeSheet(conv = conversation, onDismiss = { showLocation = false })
    }
    if (showLudoSetup) {
        val humanCandidates = if (isGroup) groupMembers.filterNot { it.isYou }.map { it.id }
            else listOfNotNull(conversation.peerUserId)
        com.voiid.app.main.games.ludo.LudoChatSetupDialog(
            hasHumanPeer = humanCandidates.isNotEmpty() || (!isGroup && !isSelfChat),
            onStart = { mode, difficulty ->
                showLudoSetup = false
                scope.launch {
                    val resolved = if (!isGroup && humanCandidates.isEmpty()) {
                        listOfNotNull(runCatching {
                            com.voiid.app.net.ChatService(context).resolvePeer(conversation.id).peerUserId
                        }.getOrNull())
                    } else humanCandidates
                    val opponents = when (mode) {
                        com.voiid.app.main.games.ludo.LudoChatMode.DUEL_HUMAN -> resolved.take(1)
                        com.voiid.app.main.games.ludo.LudoChatMode.DUEL_BOT -> emptyList()
                        com.voiid.app.main.games.ludo.LudoChatMode.FOUR -> resolved.take(3)
                    }
                    val bots = when (mode) {
                        com.voiid.app.main.games.ludo.LudoChatMode.DUEL_HUMAN -> 0
                        com.voiid.app.main.games.ludo.LudoChatMode.DUEL_BOT -> 1
                        com.voiid.app.main.games.ludo.LudoChatMode.FOUR -> 3 - opponents.size
                    }
                    val id = com.voiid.app.net.GamesEngine.get(context).createLudoFromChat(
                        conversation.id, opponents, bots, difficulty) ?: return@launch
                    if (opponents.isNotEmpty()) {
                        chat.send(
                            com.voiid.app.net.GameInvite.encode("ludo", id,
                                com.voiid.app.net.GameInvite.Meta(
                                    game = "Ludo",
                                    format = if (mode == com.voiid.app.main.games.ludo.LudoChatMode.FOUR) "4 players" else "1 vs 1",
                                    level = if (bots > 0) difficulty.replaceFirstChar { it.uppercase() } else "",
                                    sentAt = System.currentTimeMillis())),
                            conversationId = conversation.id,
                        )
                    }
                    com.voiid.app.net.DeepLinkRouter.openGameMatch(id, "ludo")
                }
            },
            onDismiss = { showLudoSetup = false },
        )
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
        com.voiid.app.ui.components.VoiidDialogCustom(onDismissRequest = { deleteMessage = null }) {
            Spacer(Modifier.height(20.dp))
            Text("Delete message?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.height(6.dp))
            if (m.isMine && !isGroup && !m.deletedForEveryone && m.status != com.voiid.app.model.MessageStatus.SENDING && m.status != com.voiid.app.model.MessageStatus.FAILED) {
                com.voiid.app.ui.components.VoiidDialogAction("Delete for everyone", destructive = true) {
                    chat.deleteMessage(m.id, conversation.id, true); deleteMessage = null
                }
            }
            com.voiid.app.ui.components.VoiidDialogAction("Delete for me", destructive = true) {
                chat.deleteMessage(m.id, conversation.id, false); deleteMessage = null
            }
            com.voiid.app.ui.components.VoiidDialogAction("Cancel") { deleteMessage = null }
            Spacer(Modifier.height(8.dp))
        }
    }
    if (showClearChat) {
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { showClearChat = false },
            title = "Clear this chat?",
            body = "All messages will be removed from this chat.",
            confirmLabel = "Clear chat",
            onConfirm = { chat.clearChat(conversation.id); showClearChat = false },
            confirmDestructive = true,
        )
    }
    recordingError?.let { error ->
        AlertDialog(onDismissRequest = { recordingError = null },
            title = { Text("Couldn’t record") }, text = { Text(error) },
            confirmButton = { TextButton(onClick = { recordingError = null }) { Text("OK") } })
    }
    chat.actionError?.let { error ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { chat.actionError = null }, title = "Action couldn’t finish",
            body = error, confirmLabel = "OK", onConfirm = { chat.actionError = null },
        )
    }
    if (showBulkDelete) {
        val selected = messages.filter { it.id in selectedIds }
        com.voiid.app.ui.components.VoiidDialogCustom(onDismissRequest = { showBulkDelete = false }) {
            Spacer(Modifier.height(20.dp))
            Text("Delete ${selectedIds.size} message${if (selectedIds.size == 1) "" else "s"}?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text("Choose who the selected messages are deleted for.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
            if (!isGroup && selected.isNotEmpty() && selected.all {
                it.isMine && !it.deletedForEveryone && it.status != com.voiid.app.model.MessageStatus.SENDING && it.status != com.voiid.app.model.MessageStatus.FAILED
            }) {
                com.voiid.app.ui.components.VoiidDialogAction("Delete for everyone", destructive = true) {
                    chat.deleteMessages(selectedIds.toSet(), conversation.id, true)
                    showBulkDelete = false; exitSelection()
                }
            }
            com.voiid.app.ui.components.VoiidDialogAction("Delete for me", destructive = true) {
                chat.deleteMessages(selectedIds.toSet(), conversation.id, false)
                showBulkDelete = false; exitSelection()
            }
            com.voiid.app.ui.components.VoiidDialogAction("Cancel") { showBulkDelete = false }
            Spacer(Modifier.height(8.dp))
        }
    }
}

private fun presenceText(context: android.content.Context, conversation: VConversation, typing: Boolean): String = when {
    typing -> "typing…"
    conversation.type == ConversationType.GROUP -> "${conversation.memberCount} members"
    // Settings -> Privacy -> "Show online status": display-only on this device — it does
    // not change what anyone else can see about you (see PrivacySettings doc).
    !com.voiid.app.model.PrivacySettings.showOnlineStatus(context) -> ""
    conversation.isOnline -> "Online"
    conversation.lastSeenAt != null -> "last seen ${VoiidDate.relative(conversation.lastSeenAt!!)}"
    else -> "last seen recently"
}

/**
 * The end-to-end encryption notice at the top of a new chat. Mirrors iOS
 * `ChatDetailView.encryptionNotice` — same copy, same placement, same behaviour.
 *
 * SAYS WHAT IS ACTUALLY TRUE, and says it specifically. "Your messages are encrypted" is
 * vague enough to be worthless — the question people actually have is whether the PHOTOS and
 * VOICE NOTES are covered too, because that is the part every other app is evasive about.
 * Naming them is the point.
 *
 * Verified before it was written: 1:1 messages use the Double Ratchet, groups use MLS, calls
 * are E2E on both paths (DTLS-SRTP for 1:1; on-device keys for group, where the SFU forwards
 * frames it cannot decrypt), and media is encrypted per-attachment.
 *
 * @param canVerify false for a group, which has no single peer to compare a safety number
 *                  against — it gets the statement without the affordance rather than a tap
 *                  that leads nowhere.
 */
@Composable
private fun EncryptionNotice(canVerify: Boolean, onVerify: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(bottom = 8.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.heightIn(min = 48.dp)
                .then(if (canVerify) Modifier.clickable(onClick = onVerify) else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            Row(
                Modifier.clip(RoundedCornerShape(50)).background(VoiidColor.surfaceCard)
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
                Text("End-to-end encrypted", style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.textSecondary)
                if (canVerify) Icon(Icons.Default.ChevronRight, "Verify encryption", tint = VoiidColor.textSecondary, modifier = Modifier.size(13.dp))
            }
        }
    }
}
