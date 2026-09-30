package com.voiid.app.main

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMade
import androidx.compose.material.icons.automirrored.filled.CallMissed
import androidx.compose.material.icons.automirrored.filled.CallReceived
import androidx.compose.material.icons.filled.AddIcCall
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.store.CallHistoryRow
import com.voiid.app.store.LocalStore
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.VoiidMenu
import com.voiid.app.ui.components.VoiidMenuItem
import com.voiid.app.ui.components.VoiidSearchField
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * The Calls tab — every call, newest first. Port of iOS `CallLogView.swift`; design reference
 * `Voiid Ui/Chat/CallsScreen.swift`.
 *
 * WHY THIS EXISTS. Call history was written to `call_history` from the first call the app
 * ever placed, but the only way to SEE it was to open the chat it happened in, or that
 * person's profile. So "who called me while I was out?" — the one question a call log answers
 * — had no answer anywhere in the app. The data was there; the screen was not.
 *
 * WHAT THIS IS NOT. There is no server-side call history: `call_history` is a LOCAL table,
 * written when THIS device places or receives a call. A call answered on another device does
 * not appear, and reinstalling loses the log.
 *
 * NO KEYPAD. Voiid calls Voiid ACCOUNTS, not phone numbers; a dial pad would invite typing a
 * number Voiid cannot ring. "New call" picks a person instead.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CallsTab(
    chat: ChatStore,
    onOpenConversation: (VConversation) -> Unit,
    onStartCall: (CallRequest) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var entries by remember { mutableStateOf<List<CallHistoryRow>>(emptyList()) }
    var missedOnly by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<CallHistoryRow?>(null) }
    var newCall by remember { mutableStateOf(false) }

    // Reload on entry and whenever a call ends — that is the moment a new row is written.
    val callActive = com.voiid.app.net.CallManager.state.collectAsState().value != null
    LaunchedEffect(callActive) { if (!callActive) entries = LocalStore.recentCalls(context, limit = 500) }
    fun reload() = scope.launch { entries = LocalStore.recentCalls(context, limit = 500) }

    val conversations = chat.directConversations + chat.groupConversations
    fun conversationFor(row: CallHistoryRow) = row.conversationId?.let { cid -> conversations.firstOrNull { it.id == cid } }
    fun nameFor(row: CallHistoryRow) = callerName(row, conversationFor(row))

    fun place(conv: VConversation, video: Boolean) {
        scope.launch { onStartCall(callRequestFor(context, conv, if (video) CallKind.VIDEO else CallKind.VOICE)) }
    }
    fun callBack(row: CallHistoryRow, video: Boolean = row.kind == "video") {
        // No chat on this phone to resolve the peer or group from — place nothing rather than
        // a call the call screen cannot route.
        val conv = conversationFor(row) ?: run { haptics.error(); return }
        haptics.tap(); place(conv, video)
    }
    fun delete(row: CallHistoryRow) {
        scope.launch { LocalStore.deleteCall(context, row.id); reload() }
    }

    val visible = entries.filter { row ->
        (!missedOnly || row.isMissed()) && (query.isBlank() || nameFor(row).contains(query.trim(), ignoreCase = true))
    }

    if (confirmClear) {
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { confirmClear = false },
            title = "Clear all calls?",
            // Say what is actually lost. This is device-local, so "on this phone" is the whole truth.
            body = "Your call history is removed from this phone. It doesn't affect the other person's log.",
            confirmLabel = "Clear All Calls",
            onConfirm = {
                confirmClear = false
                scope.launch { LocalStore.clearCallHistory(context); entries = emptyList() }
            },
            confirmDestructive = true,
        )
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        // Toolbar: ••• · All/Missed · New call — the iOS nav bar, item for item.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box {
                ToolbarCircle(Icons.Default.MoreHoriz, "More") { menuOpen = true }
                VoiidMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, alignEnd = false) {
                    VoiidMenuItem("Clear All Calls", Icons.Default.Delete, destructive = true, enabled = entries.isNotEmpty()) {
                        menuOpen = false; haptics.rigid(); confirmClear = true
                    }
                }
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                Segmented(listOf("All", "Missed"), if (missedOnly) 1 else 0) {
                    haptics.selection(); missedOnly = it == 1
                }
            }
            ToolbarCircle(Icons.Default.AddIcCall, "New call") { newCall = true }
        }

        Text(
            "Calls",
            style = VoiidFont.rounded(34, FontWeight.Bold),
            color = VoiidColor.textPrimary,
            modifier = Modifier.padding(start = 16.dp, top = 6.dp),
        )
        VoiidSearchField(
            query = query,
            onQueryChange = { query = it },
            placeholder = "Search calls",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )

        Box(Modifier.weight(1f)) {
            when {
                visible.isEmpty() && query.isNotBlank() ->
                    EmptyState(Icons.Default.Search, "No Results for “${query.trim()}”", "Check the spelling or try a new search.")
                // A filter matching nothing is NOT an empty history — "No calls yet" would read as broken.
                visible.isEmpty() && missedOnly && entries.isNotEmpty() ->
                    EmptyState(Icons.AutoMirrored.Filled.CallMissed, "No Missed Calls", null)
                visible.isEmpty() ->
                    EmptyState(Icons.Default.Call, "No Calls Yet", "Voice and video calls on Voiid are end-to-end encrypted.",
                        action = "Start a Call" to { newCall = true })
                else -> {
                    val grouped = visible.groupBy { dayTitle(it.startedAt * 1000) }
                    // Clears the tab bar, which is painted over this page.
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 104.dp)) {
                        grouped.forEach { (day, rows) ->
                            stickyHeader(key = "hdr_$day") {
                                Text(
                                    day,
                                    style = VoiidFont.rounded(15, FontWeight.Bold),
                                    color = VoiidColor.textPrimary,
                                    modifier = Modifier.fillMaxWidth().background(VoiidColor.background)
                                        .padding(start = 16.dp, top = 12.dp, bottom = 4.dp),
                                )
                            }
                            items(rows, key = { it.id }) { row ->
                                val conv = conversationFor(row)
                                CallRowSwipe(
                                    canMessage = conv != null,
                                    onMessage = { conv?.let(onOpenConversation) },
                                    onDelete = { delete(row) },
                                ) {
                                    CallRow(
                                        row = row,
                                        name = nameFor(row),
                                        photoUrl = row.peerUserId?.let { UserDirectory.photoUrl(it) } ?: conv?.photoURL,
                                        canMessage = conv != null,
                                        onTap = { callBack(row) },
                                        onInfo = { haptics.tap(); detail = row },
                                        onVoice = { callBack(row, video = false) },
                                        onVideo = { callBack(row, video = true) },
                                        onMessage = { conv?.let(onOpenConversation) },
                                        onDelete = { delete(row) },
                                    )
                                }
                                HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 72.dp))
                            }
                        }
                    }
                }
            }
        }
    }

    detail?.let { row ->
        val conv = conversationFor(row)
        FullScreen(onDismiss = { detail = null }) {
            CallDetail(
                row = row,
                name = nameFor(row),
                history = entries.filter { other ->
                    if (row.conversationId != null) other.conversationId == row.conversationId
                    else row.peerUserId != null && other.peerUserId == row.peerUserId
                },
                onBack = { detail = null },
                onCall = { video -> detail = null; callBack(row, video) },
                onMessage = conv?.let { c -> { detail = null; onOpenConversation(c) } },
            )
        }
    }

    if (newCall) {
        FullScreen(onDismiss = { newCall = false }) {
            NewCall(
                conversations = conversations,
                onCancel = { newCall = false },
                onCall = { conv, video -> newCall = false; haptics.tap(); place(conv, video) },
            )
        }
    }
}

/**
 * The request a call started OUTSIDE a chat needs — the Calls tab and the Chats list. Mirrors
 * `ChatDetailView.startCall` (and iOS `CallLauncher`): real group members for the tiles, never
 * DummyData, and the conversation id on every call so the callee's wake push is sent.
 */
suspend fun callRequestFor(context: Context, c: VConversation, kind: CallKind): CallRequest {
    val isGroup = c.type == ConversationType.GROUP
    val members = if (isGroup) {
        runCatching { com.voiid.app.net.ChatService(context).fetchMembers(c.id) }
            .getOrDefault(emptyList())
            .map { com.voiid.app.model.VMember(id = it.userId, name = it.name, phone = "", role = com.voiid.app.model.MemberRole.MEMBER, isYou = it.isYou) }
    } else emptyList()
    return CallRequest(
        title = c.title, isGroup = isGroup, members = members,
        photoName = c.photoName, kind = kind,
        conversationId = c.id, peerUserId = c.peerUserId,
    )
}

// MARK: - Copy

private fun CallHistoryRow.isRinging(): Boolean =
    com.voiid.app.model.isCallRinging(outcome, startedAt * 1000L, endedAt, connectedAt)   // stored in SECONDS

private fun CallHistoryRow.isMissed(): Boolean =
    direction == "incoming" && outcome != "answered" && outcome != "declined" && !isRinging()

private fun CallHistoryRow.durationSeconds(): Long? =
    if (outcome == "answered") endedAt?.let { (it - (connectedAt ?: startedAt)).coerceAtLeast(0) } else null

/** State is carried by the words AND the icon, never by red alone. Matches iOS `CallLogText`. */
private fun callSummary(row: CallHistoryRow): String {
    val medium = if (row.kind == "video") "video" else "voice"
    val incoming = row.direction == "incoming"
    // Still ringing: not missed yet.
    if (row.isRinging()) return (if (incoming) "Incoming $medium" else "Outgoing $medium") + " · now"
    return when (row.outcome) {
        "answered" -> (if (incoming) "Incoming $medium" else "Outgoing $medium") +
            (row.durationSeconds()?.let { " · " + durationText(it) } ?: "")
        "busy" -> "Outgoing $medium · Busy"
        "declined" -> if (incoming) "Declined $medium call" else "${medium.replaceFirstChar { it.uppercase() }} call declined"
        "failed" -> "Failed $medium call"
        else -> if (incoming) "Missed $medium call" else "Outgoing $medium · No answer"
    }
}

private fun callIcon(row: CallHistoryRow): ImageVector = when {
    row.kind == "video" -> Icons.Default.Videocam
    row.isMissed() || row.outcome == "declined" -> Icons.Default.CallEnd
    row.direction == "incoming" -> Icons.AutoMirrored.Filled.CallReceived
    else -> Icons.AutoMirrored.Filled.CallMade
}

private fun durationText(s: Long): String {
    if (s < 60) return "$s sec"
    val m = s / 60
    return if (m < 60) "$m min" else "${m / 60} hr ${m % 60} min"
}

/** Today / Yesterday / weekday / date — how the Phone app groups, so a glance answers "when". */
private fun dayTitle(millis: Long): String {
    val day = Calendar.getInstance().apply { timeInMillis = millis; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
    val today = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
    val days = ((today.timeInMillis - day.timeInMillis) / 86_400_000L).toInt()
    return when {
        days <= 0 -> "Today"
        days == 1 -> "Yesterday"
        days < 6 -> SimpleDateFormat("EEEE", Locale.getDefault()).format(Date(millis))
        else -> SimpleDateFormat("d MMMM", Locale.getDefault()).format(Date(millis))
    }
}

private fun timeText(millis: Long) = SimpleDateFormat("h:mm a", Locale.getDefault()).format(Date(millis))

private fun callerName(row: CallHistoryRow, conv: VConversation?): String {
    row.peerUserId?.let { peer ->
        val resolved = UserDirectory.displayName(peer, fallback = "")
        if (resolved.isNotBlank()) return resolved
    }
    // A group call has no single peer, and an unknown 1:1 still has a chat with a name on it.
    return conv?.title ?: "Unknown"
}

// MARK: - Row

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CallRow(
    row: CallHistoryRow,
    name: String,
    photoUrl: String?,
    canMessage: Boolean,
    onTap: () -> Unit,
    onInfo: () -> Unit,
    onVoice: () -> Unit,
    onVideo: () -> Unit,
    onMessage: () -> Unit,
    onDelete: () -> Unit,
) {
    val missed = row.isMissed()
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalVoiidHaptics.current
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .background(VoiidColor.background)
                // Tap calls back the same way, as in Phone; long-press is the context menu.
                .combinedClickable(onClick = onTap, onLongClick = { haptics.rigid(); menu = true })
                .padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 10.dp)
                .semantics { contentDescription = "$name, ${callSummary(row)}. Calls back" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ProfileAvatar(photoUrl = photoUrl, name = name, size = 44.dp, modifier = Modifier.clip(CircleShape))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    name,
                    // MISSED IS RED IN THE NAME; the words and glyph carry it too.
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = if (missed) VoiidColor.error else VoiidColor.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Icon(callIcon(row), null, tint = VoiidColor.textSecondary, modifier = Modifier.size(13.dp))
                    Text(callSummary(row), style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Text(timeText(row.startedAt * 1000), style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            Box(
                Modifier.size(width = 36.dp, height = 44.dp).clip(CircleShape).softClickable(onClick = onInfo),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Info, "Details for $name", tint = VoiidColor.accentInk, modifier = Modifier.size(22.dp))
            }
        }
        VoiidMenu(expanded = menu, onDismissRequest = { menu = false }, alignEnd = false) {
            VoiidMenuItem("Voice Call", Icons.Default.Call) { menu = false; onVoice() }
            VoiidMenuItem("Video Call", Icons.Default.Videocam) { menu = false; onVideo() }
            if (canMessage) VoiidMenuItem("Message", Icons.Default.ChatBubble) { menu = false; onMessage() }
            VoiidMenuItem("Delete from Recents", Icons.Default.Delete, destructive = true) { menu = false; onDelete() }
        }
    }
}

/**
 * Swipe right → Message, swipe left → Delete, matching the iOS leading/trailing actions. A full
 * swipe only REVEALS the action — the user still taps it, as in the Chats list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CallRowSwipe(
    canMessage: Boolean,
    onMessage: () -> Unit,
    onDelete: () -> Unit,
    content: @Composable () -> Unit,
) {
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { false })
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = canMessage,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            val toStart = state.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            Row(
                Modifier.fillMaxSize(),
                horizontalArrangement = if (toStart) Arrangement.Start else Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (toStart) SwipeAction(Icons.Default.ChatBubble, "Message", VoiidColor.primary, onMessage)
                else SwipeAction(Icons.Default.Delete, "Delete", VoiidColor.error, onDelete)
            }
        },
    ) { content() }
}

@Composable
private fun SwipeAction(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Box(
        Modifier.width(80.dp).fillMaxHeight().background(tint).softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, contentDescription = null, tint = Color.White)
            Text(label, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White)
        }
    }
}

// MARK: - Pieces

@Composable
private fun ToolbarCircle(icon: ImageVector, label: String, onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Box(
        Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.surfaceCard)
            .softClickable { haptics.tap(); onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, tint = VoiidColor.accentInk, modifier = Modifier.size(20.dp))
    }
}

/** The iOS segmented control: a raised thumb on a recessed track. */
@Composable
private fun Segmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Row(
        Modifier.width(200.dp).clip(RoundedCornerShape(9.dp)).background(VoiidColor.fieldFill).padding(2.dp),
    ) {
        options.forEachIndexed { i, label ->
            val on = i == selected
            Box(
                Modifier
                    .weight(1f)
                    .then(if (on) Modifier.shadow(1.dp, RoundedCornerShape(7.dp)) else Modifier)
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (on) VoiidColor.surfaceRaised else Color.Transparent)
                    .softClickable(scale = 1f) { if (!on) onSelect(i) }
                    .padding(vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(label, style = VoiidFont.rounded(13, if (on) FontWeight.SemiBold else FontWeight.Medium),
                    color = VoiidColor.textPrimary)
            }
        }
    }
}

/** iOS `ContentUnavailableView`, in Voiid type. */
@Composable
private fun EmptyState(icon: ImageVector, title: String, body: String?, action: Pair<String, () -> Unit>? = null) {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 32.dp).padding(bottom = 104.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(44.dp))
        Spacer(Modifier.height(14.dp))
        Text(title, style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary, textAlign = TextAlign.Center)
        body?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary, textAlign = TextAlign.Center)
        }
        action?.let { (label, onClick) ->
            Spacer(Modifier.height(18.dp))
            PrimaryPill(label, onClick = onClick)
        }
    }
}

/** The screen's one primary button — Tide capsule, white label (iOS `prominentAction`). */
@Composable
internal fun PrimaryPill(label: String, modifier: Modifier = Modifier, enabled: Boolean = true, icon: ImageVector? = null, onClick: () -> Unit) {
    Row(
        modifier
            .clip(RoundedCornerShape(50))
            .background(if (enabled) VoiidColor.primary else VoiidColor.primary.copy(alpha = 0.4f))
            .softClickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 24.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let { Icon(it, null, tint = Color.White, modifier = Modifier.size(20.dp)) }
        Text(label, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = Color.White)
    }
}

@Composable
private fun FullScreen(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BackHandler { onDismiss() }
        Box(Modifier.fillMaxSize().background(VoiidColor.background)) { content() }
    }
}

/** An inset-grouped card, iOS style: small caps header, rounded card, optional footer. */
@Composable
internal fun GroupedSection(header: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        header?.let {
            Text(it.uppercase(), style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(start = 16.dp, bottom = 6.dp))
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(VoiidColor.surfaceCard), content = content)
        footer?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

// MARK: - Detail

@Composable
private fun CallDetail(
    row: CallHistoryRow,
    name: String,
    history: List<CallHistoryRow>,
    onBack: () -> Unit,
    onCall: (Boolean) -> Unit,
    onMessage: (() -> Unit)?,
) {
    val phone = row.peerUserId?.let { UserDirectory.phoneE164(it) }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState())) {
        VoiidCircleBack(onBack = onBack)
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            ProfileAvatar(photoUrl = row.peerUserId?.let { UserDirectory.photoUrl(it) }, name = name, size = 88.dp,
                modifier = Modifier.clip(CircleShape))
            Spacer(Modifier.height(12.dp))
            Text(name, style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary, textAlign = TextAlign.Center)
            phone?.let { Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary) }
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                onMessage?.let { ActionTile("Message", Icons.Default.ChatBubble, Modifier.weight(1f), it) }
                ActionTile("Voice", Icons.Default.Call, Modifier.weight(1f)) { onCall(false) }
                ActionTile("Video", Icons.Default.Videocam, Modifier.weight(1f)) { onCall(true) }
            }
        }
        Spacer(Modifier.height(16.dp))
        GroupedSection("Calls") {
            history.forEachIndexed { i, call ->
                val missed = call.isMissed()
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(callIcon(call), null, tint = if (missed) VoiidColor.error else VoiidColor.textSecondary, modifier = Modifier.size(16.dp))
                    Text(callSummary(call), style = VoiidFont.rounded(15),
                        color = if (missed) VoiidColor.error else VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                    Text(SimpleDateFormat("d MMM, h:mm a", Locale.getDefault()).format(Date(call.startedAt * 1000)),
                        style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                }
                if (i < history.lastIndex) HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 42.dp))
            }
        }
        Row(
            Modifier.padding(horizontal = 32.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
            Text("Calls with $name are end-to-end encrypted.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }
    }
}

@Composable
private fun ActionTile(title: String, icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Column(
        modifier.clip(RoundedCornerShape(14.dp)).background(VoiidColor.surfaceCard)
            .softClickable { haptics.tap(); onClick() }.padding(vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, null, tint = VoiidColor.accentInk, modifier = Modifier.size(20.dp))
        Text(title, style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.accentInk)
    }
}

// MARK: - New call

/** People and groups you can ring. A picker, not a keypad — see the file note. */
@Composable
private fun NewCall(
    conversations: List<VConversation>,
    onCancel: () -> Unit,
    onCall: (VConversation, Boolean) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val matches = conversations.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) }
    val people = matches.filter { it.type != ConversationType.GROUP }
    val groups = matches.filter { it.type == ConversationType.GROUP }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 16.dp)) {
            Text("Cancel", style = VoiidFont.rounded(17), color = VoiidColor.accentInk,
                modifier = Modifier.align(Alignment.CenterStart).softClickable(onClick = onCancel))
            Text("New Call", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.Center))
        }
        VoiidSearchField(query = query, onQueryChange = { query = it }, placeholder = "Name",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        when {
            matches.isEmpty() && query.isNotBlank() ->
                EmptyState(Icons.Default.Search, "No Results for “${query.trim()}”", "Check the spelling or try a new search.")
            matches.isEmpty() ->
                EmptyState(Icons.Default.Call, "No Chats Yet", "Start a chat with someone to call them.")
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
                if (people.isNotEmpty()) item { GroupedSection("Contacts") { people.forEachIndexed { i, c -> NewCallRow(c, i < people.lastIndex, onCall) } } }
                if (groups.isNotEmpty()) item { GroupedSection("Groups") { groups.forEachIndexed { i, c -> NewCallRow(c, i < groups.lastIndex, onCall) } } }
            }
        }
    }
}

@Composable
private fun NewCallRow(c: VConversation, divider: Boolean, onCall: (VConversation, Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ProfileAvatar(photoUrl = c.photoURL, name = c.title, size = 40.dp, modifier = Modifier.clip(CircleShape))
        Text(c.title, style = VoiidFont.rounded(17, FontWeight.Medium), color = VoiidColor.textPrimary,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        CallCircle(Icons.Default.Call, "Voice call ${c.title}") { onCall(c, false) }
        CallCircle(Icons.Default.Videocam, "Video call ${c.title}") { onCall(c, true) }
    }
    if (divider) HorizontalDivider(color = VoiidColor.divider, modifier = Modifier.padding(start = 68.dp))
}

@Composable
private fun CallCircle(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(38.dp).clip(CircleShape).background(VoiidColor.accentTint).softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, tint = VoiidColor.accentInk, modifier = Modifier.size(18.dp))
    }
}
