package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.DummyData
import com.voiid.app.model.VConversation
import com.voiid.app.net.AvatarCache
import com.voiid.app.net.ContactPinService
import com.voiid.app.net.ContactsService
import com.voiid.app.net.VContact
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidMenu
import com.voiid.app.ui.components.VoiidMenuDivider
import com.voiid.app.ui.components.VoiidMenuItem
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.components.reduceMotionEnabled
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.ChatLayout
import com.voiid.app.ui.theme.ChatLayoutPreference
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlin.math.hypot
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

private enum class ChatTab(val label: String) { CHATS("Chats"), GROUPS("Groups") }

/** Chat home (Figma Screen-6/7) — port of `ChatsHomeView.swift` + `DraggableChatGrid.swift`. */
@Composable
fun ChatsHomeView(
    chat: ChatStore,
    onOpenConversation: (VConversation) -> Unit,
    onStartCall: (CallRequest) -> Unit,
) {
    val reduceMotion = reduceMotionEnabled()
    val haptics = LocalVoiidHaptics.current
    val context = androidx.compose.ui.platform.LocalContext.current
    // Same activity-scoped AppSession as VoiidRoot — signOut() flips route to onboarding.
    val session: com.voiid.app.model.AppSession = androidx.lifecycle.viewmodel.compose.viewModel()
    // Ensure E2E identity/prekeys are published (idempotent), then load conversations.
    androidx.compose.runtime.LaunchedEffect(Unit) {
        runCatching { com.voiid.app.net.E2EManager.get(context).bootstrap() }
        // Wire the location relay seam early + reconcile live shares (docs/LOCATION.md).
        runCatching { com.voiid.app.net.LocationShareEngine.refresh(context) }
        chat.loadConversations()
        // Register this device's FCM push token on login (onNewToken may not fire if a
        // token already exists, e.g. returning user), so wake pushes reach this device.
        runCatching {
            val token = com.google.firebase.messaging.FirebaseMessaging.getInstance().token.await()
            com.voiid.app.net.E2EManager.get(context).registerPushToken(token)
        }
    }
    var search by remember { mutableStateOf("") }
    var tab by remember { mutableStateOf(ChatTab.CHATS) }
    var deleteTarget by remember { mutableStateOf<VConversation?>(null) }
    var callTarget by remember { mutableStateOf<VConversation?>(null) }
    var showCallLog by remember { mutableStateOf(false) }
    var showNewChat by remember { mutableStateOf(false) }
    /** Set by the menu so the sheet knows whether to build a GROUP, independent of the tab. */
    var forceGroup by remember { mutableStateOf(false) }
    var showFindByUsername by remember { mutableStateOf(false) }
    var showRequests by remember { mutableStateOf(false) }
    /** Inbound requests waiting to be accepted. Zero hides the banner entirely rather than
     *  showing an affordance to an empty screen. */
    var pendingRequestCount by remember { mutableStateOf(0) }
    val reachScope = androidx.compose.runtime.rememberCoroutineScope()

    suspend fun refreshRequestCount() {
        pendingRequestCount = runCatching { ContactPinService(context).pending().size }.getOrDefault(0)
    }
    androidx.compose.runtime.LaunchedEffect(Unit) { refreshRequestCount() }
    // Settings + its children live in ONE modal stack, so Back from Backup/Privacy/Storage/
    // Devices/About/Legal returns to the screen underneath — never straight to this list.
    val settingsNav = com.voiid.app.ui.components.rememberVoiidModalNavigator()
    var allContacts by remember { mutableStateOf<List<VContact>>(emptyList()) }
    val scope = rememberCoroutineScope()

    val list: SnapshotStateList<VConversation> = if (tab == ChatTab.CHATS) chat.directConversations else chat.groupConversations
    val filtered = if (search.isBlank()) list.toList() else list.filter { it.title.contains(search, ignoreCase = true) }

    // Load discovered VOIID contacts once when search starts, so "not started" chats
    // (contacts you haven't messaged) also show in search.
    androidx.compose.runtime.LaunchedEffect(search.isNotBlank()) {
        if (search.isNotBlank() && allContacts.isEmpty()) {
            runCatching { ContactsService(context).discover().matches }.getOrNull()?.let { allContacts = it }
        }
    }
    val existingPeers = chat.directConversations.mapNotNull { it.peerUserId }.toHashSet()
    val contactResults = if (tab == ChatTab.CHATS && search.isNotBlank()) {
        allContacts.filter { it.userId !in existingPeers && it.displayName.contains(search, ignoreCase = true) }
    } else emptyList()

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding(),
    ) {
        Header(
            haptics,
            photoUrl = session.profile.photoURL,
            myName = session.profile.fullName,
            search = search,
            onSearchChange = { search = it },
            onNewChat = { forceGroup = false; showNewChat = true },
            // Set on OPEN, both ways. Resetting on close would mean covering four separate
            // dismiss paths (dismiss, two onClose, two onOpen) and one of them will always be
            // missed — a stale `true` would then turn the next "New chat" into a group.
            onNewGroup = { forceGroup = true; showNewChat = true },
            onFindByUsername = { showFindByUsername = true },
            onOpenCallLog = { showCallLog = true },
            onOpenSettings = { settingsNav.push("settings") },
        )
        Tabs(tab) { haptics.selection(); tab = it }
        // "N message requests" — the ONLY surface for them. GET /conversations filters pending
        // ones out, so without this a stranger's held-back message would be invisible until
        // they gave up.
        if (pendingRequestCount > 0) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp)
                    .padding(top = 12.dp)
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.surfaceCard)
                    .clickable { haptics.tap(); showRequests = true }
                    .padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Inbox, null, tint = VoiidColor.primary, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(10.dp))
                Text(
                    if (pendingRequestCount == 1) "1 message request" else "$pendingRequestCount message requests",
                    style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.textPrimary,
                )
                Spacer(Modifier.weight(1f))
                Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(16.dp))
            }
        }
        // The OS is stopping calls from ringing, and nothing else would ever say so.
        CallRingBanner()
        // Persistent "sharing live location" banner across all chats (docs/LOCATION.md §8.A).
        LocationBanner()
        if (search.isBlank()) {
            // THREE STATES, not one. The grid used to render for all of them, so a fresh
            // install and a still-loading list both showed the same blank screen — the first
            // thing a new user ever sees, indistinguishable from the app being broken.
            //
            // "Empty" means no REAL conversations: Note to Self always exists, so a plain
            // isEmpty check would never fire and a brand-new user would see one lonely tile
            // with no explanation of what to do next. Mirrors iOS.
            val realItems = list.filter { it.type != ConversationType.SELF }
            // A sync that FAILED with nothing cached must not read as "No chats yet" — that
            // claims the inbox is empty when the truth is we don't know. Full retry state.
            val loadFailedWithNoCache =
                chat.loadError != null && chat.didLoadConversations && realItems.isEmpty()
            // A failure WITH cache shows a non-destructive banner ABOVE the cached content,
            // so the user keeps their list and learns the refresh didn't land. Mirrors iOS.
            if (chat.loadError != null && !loadFailedWithNoCache) {
                ChatsErrorBanner(
                    message = chat.loadError!!,
                    onRetry = { haptics.tap(); chat.loadConversations() },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp),
                )
            }
            when {
                loadFailedWithNoCache -> ChatsRetryState(
                    message = chat.loadError ?: "Couldn't load chats.",
                    onRetry = { haptics.tap(); chat.loadConversations() },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
                !chat.didLoadConversations && realItems.isEmpty() -> {
                    ChatsLoadingState(Modifier.fillMaxWidth().weight(1f))
                }
                realItems.isEmpty() -> ChatsEmptyState(
                    isGroups = tab == ChatTab.GROUPS,
                    onNewChat = { haptics.tap(); showNewChat = true },
                    onFindByUsername = { haptics.tap(); showFindByUsername = true },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
                ChatLayoutPreference.layout == ChatLayout.GRID -> DraggableChatGrid(
                    items = list,
                    onOpen = { haptics.tap(); onOpenConversation(it) },
                    onCall = { callTarget = it },
                    onDelete = { deleteTarget = it },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
                else ->
                // The classic list. See ChatLayoutPreference for why this exists alongside
                // the grid, and ChatListRows for the per-row design decisions.
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp),
                ) {
                    items(list, key = { "l_" + it.id }) { conv ->
                        // ROWS REORDER, THEY DO NOT TELEPORT.
                        //
                        // A chat jumps to the top the moment a message lands, and every row
                        // below shifts down by one — the most frequent state change on this
                        // screen, and it happened in a single frame with nothing connecting
                        // before and after. `animateItem` needs the stable `key` above to
                        // know which row MOVED rather than crossfading the whole list.
                        //
                        // A spring, matching iOS: messages arrive in bursts, so a second
                        // arrival mid-reflow retargets from where rows currently are instead
                        // of restarting from a stale position. Critically damped — nothing
                        // was thrown by the user, so nothing has earned overshoot.
                        Column(
                            Modifier.animateItem(
                                // null = no placement animation, which is what Reduce Motion
                                // asks for: every row on screen shifting at once is exactly
                                // the vestibular motion that setting exists to suppress. The
                                // badge and press states stay — small elements, and removing
                                // them would cost information.
                                placementSpec = if (reduceMotion) null else spring(
                                    dampingRatio = 0.9f,
                                    stiffness = Spring.StiffnessMediumLow,
                                ),
                            ),
                        ) {
                        ChatListRow(
                            conversation = conv,
                            // Same two actions the grid exposes via drag-to-zone, and the
                            // same two iOS puts on a swipe. Without these the list layout had
                            // no way to delete a chat at all.
                            // The swipe actions keep their haptics — they are revealed
                            // controls, not the row, so nothing has fired for them yet.
                            // Delete gets the heavier one: it opens a destructive dialog.
                            onCall = { haptics.tap(); callTarget = conv },
                            onDelete = { haptics.rigid(); deleteTarget = conv },
                            // No haptic on TAP: softClickable inside the row already fires one
                            // on press-DOWN, which is earlier and is the causal moment. Firing
                            // again on release buzzed twice for a single tap — over-feedback,
                            // which trains people to ignore all of it. iOS fires once here.
                            onTap = { onOpenConversation(conv) },
                        )
                        // Inset to start at the TEXT, not the screen edge — the avatar column
                        // reads as a gutter and a full-width rule cuts through it.
                         HorizontalDivider(
                             color = VoiidColor.divider.copy(alpha = 0.5f),
                             modifier = Modifier.padding(start = 86.dp),
                         )
                        }
                    }
                }
            }
        } else {
            // Search results — existing chats + contacts you can start a new chat with.
            LazyColumn(
                modifier = Modifier.fillMaxWidth().weight(1f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 24.dp, vertical = 16.dp),
            ) {
                if (filtered.isNotEmpty()) {
                    item { SearchSectionLabel("Chats") }
                    items(filtered, key = { "c_" + it.id }) { conv ->
                        // No haptic: softClickable inside the row fires one on press-DOWN.
                        SearchChatRow(conv) { onOpenConversation(conv) }
                    }
                }
                if (contactResults.isNotEmpty()) {
                    item { SearchSectionLabel("Start new chat") }
                    items(contactResults, key = { "u_" + it.userId }) { c ->
                        SearchContactRow(c) {
                            // No haptic: softClickable fires one on press-DOWN.
                            scope.launch {
                                val conv = chat.startDirectChat(c)
                                if (conv != null) { search = ""; onOpenConversation(conv) }
                            }
                        }
                    }
                }
                if (filtered.isEmpty() && contactResults.isEmpty()) {
                    item {
                        Text(
                            "No chats or contacts found.",
                            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                            modifier = Modifier.padding(top = 40.dp),
                        )
                    }
                }
            }
        }
    }

    // Calls — fullscreen dialog, same pattern as Settings below.
    if (showCallLog) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showCallLog = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            CallLogScreen(
                chat = chat,
                onBack = { showCallLog = false },
                // Close FIRST, then open the chat — leaving the dialog up would push the
                // conversation behind it.
                onOpenConversation = { conv -> showCallLog = false; onOpenConversation(conv) },
            )
        }
    }

    // ONE window for the whole settings cluster: pushes preserve hierarchy (Storage can
    // open Backup ON TOP of itself and Back returns to Storage), and Back from the root
    // route is what closes back to Chats.
    com.voiid.app.ui.components.VoiidModalHost(navigator = settingsNav) { route ->
        when (route) {
            "settings" -> SettingsScreen(
                session = session,
                onClose = settingsNav::closeAll,
                onBackupRecovery = { settingsNav.push("backup") },
                onPrivacy = { settingsNav.push("privacy") },
                onStorage = { settingsNav.push("storage") },
                onLinkedDevices = { settingsNav.push("devices") },
                onAbout = { settingsNav.push("about") },
                onLegal = { settingsNav.push("legal") },
            )
            "backup" -> BackupRecoveryScreen(onBack = settingsNav::pop)
            "blocked" -> BlockedContactsScreen(onBack = settingsNav::pop)
            "privacy" -> PrivacySettingsScreen(
                onBack = settingsNav::pop,
                onBlockedContacts = { settingsNav.push("blocked") },
            )
            "storage" -> StorageSettingsScreen(
                onBack = settingsNav::pop,
                // Backup opens ON TOP of Storage now — Back returns here, not to Chats.
                onOpenBackupRecovery = { settingsNav.push("backup") },
            )
            "devices" -> LinkedDevicesScreen(onBack = settingsNav::pop)
            "about" -> AboutScreen(onBack = settingsNav::pop)
            "legal" -> LegalScreen(onBack = settingsNav::pop)
        }
    }

    // New chat (contact discovery) — fullscreen dialog
    if (showFindByUsername) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showFindByUsername = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            FindByUsernameScreen(
                onClose = { showFindByUsername = false },
                onOpen = { conversationId, pending ->
                    showFindByUsername = false
                    reachScope.launch {
                        chat.loadConversations()
                        // A PENDING request has no chat to open yet — navigating in would show
                        // an empty transcript that looks broken.
                        if (!pending) {
                            chat.directConversations.firstOrNull { it.id == conversationId }
                                ?.let(onOpenConversation)
                        }
                    }
                },
            )
        }
    }
    if (showRequests) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showRequests = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            MessageRequestsScreen(
                onClose = { showRequests = false; reachScope.launch { refreshRequestCount() } },
                onAccepted = { conversationId ->
                    showRequests = false
                    reachScope.launch {
                        chat.loadConversations()
                        refreshRequestCount()
                        chat.directConversations.firstOrNull { it.id == conversationId }
                            ?.let(onOpenConversation)
                    }
                },
            )
        }
    }
    if (showNewChat) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showNewChat = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            // WHICH sheet is now explicit, not inferred from the tab. The old rule — "+ means
            // group on the Groups tab, 1:1 on Chats" — made one control mean two things
            // depending on a selection two rows away. The menu names both, so `forceGroup`
            // carries the choice and the tab is only the fallback for any older entry point.
            if (forceGroup || tab == ChatTab.GROUPS) {
                NewGroupScreen(
                    chat = chat,
                    onClose = { showNewChat = false },
                    onOpen = { conv -> showNewChat = false; onOpenConversation(conv) },
                )
            } else {
                NewChatScreen(
                    chat = chat,
                    onClose = { showNewChat = false },
                    onOpen = { conv -> showNewChat = false; onOpenConversation(conv) },
                )
            }
        }
    }

    // Delete confirmation
    deleteTarget?.let { c ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { deleteTarget = null },
            title = "Delete chat?",
            body = "This chat will be deleted from your list.",
            confirmLabel = "Delete",
            onConfirm = { chat.deleteConversation(c.id); deleteTarget = null },
            confirmDestructive = true,
        )
    }

    // Call type picker
    callTarget?.let { c ->
        CallTypeSheet(
            title = c.title,
            onPick = { kind ->
                val isGroup = c.type == ConversationType.GROUP
                // Load REAL members for the group-call tiles (never DummyData), then start.
                scope.launch {
                    val members = if (isGroup) {
                        runCatching { com.voiid.app.net.ChatService(context).fetchMembers(c.id) }
                            .getOrDefault(emptyList())
                            .map { com.voiid.app.model.VMember(id = it.userId, name = it.name, phone = "", role = com.voiid.app.model.MemberRole.MEMBER, isYou = it.isYou) }
                    } else emptyList()
                    onStartCall(
                        CallRequest(
                            title = c.title, isGroup = isGroup, members = members,
                            photoName = c.photoName, kind = kind,
                            conversationId = c.id, peerUserId = c.peerUserId,
                        ),
                    )
                }
                callTarget = null
            },
            onDismiss = { callTarget = null },
        )
    }
}

// MARK: - Draggable, home-screen-style grid

private enum class DropZone { CALL, DELETE }

@Composable
private fun DraggableChatGrid(
    items: SnapshotStateList<VConversation>,
    onOpen: (VConversation) -> Unit,
    onCall: (VConversation) -> Unit,
    onDelete: (VConversation) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    val centers = remember { mutableStateMapOfCenters() }
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    var containerWidthPx by remember { mutableStateOf(0f) }

    var dragItem by remember { mutableStateOf<VConversation?>(null) }
    var dragStart by remember { mutableStateOf(Offset.Zero) }
    var dragTranslation by remember { mutableStateOf(Offset.Zero) }
    var hoverZone by remember { mutableStateOf<DropZone?>(null) }
    var armedId by remember { mutableStateOf<String?>(null) }

    val gutterPx = with(density) { 70.dp.toPx() }
    val reorderPx = with(density) { 60.dp.toPx() }
    val cardPx = with(density) { 96.dp.toPx() }

    Box(
        modifier
            .onGloballyPositioned {
                rootOrigin = it.positionInRoot()
                containerWidthPx = it.size.width.toFloat()
            }
            // Container-level long-press drag: independent of item composables, so live reorder
            // never cancels the gesture (mirrors iOS DraggableChatGrid pick-up + drag).
            .pointerInput(items.size) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { offset ->
                        val picked = centers.entries.minByOrNull {
                            hypot((it.value.x - offset.x).toDouble(), (it.value.y - offset.y).toDouble())
                        }?.key?.let { id -> items.firstOrNull { it.id == id } }
                        if (picked != null) {
                            haptics.rigid()
                            armedId = picked.id
                            dragItem = picked
                            dragStart = centers[picked.id] ?: offset
                            dragTranslation = Offset.Zero
                        }
                    },
                    onDrag = { change, amount ->
                        change.consume()
                        val conv = dragItem ?: return@detectDragGesturesAfterLongPress
                        dragTranslation += amount
                        val p = dragStart + dragTranslation
                        hoverZone = when {
                            p.x < gutterPx -> DropZone.CALL
                            p.x > containerWidthPx - gutterPx -> DropZone.DELETE
                            else -> null
                        }
                        if (hoverZone == null) {
                            val target = centers.entries
                                .filter { it.key != conv.id }
                                .minByOrNull { hypot((it.value.x - p.x).toDouble(), (it.value.y - p.y).toDouble()) }
                            if (target != null &&
                                hypot((target.value.x - p.x).toDouble(), (target.value.y - p.y).toDouble()) < reorderPx
                            ) {
                                val from = items.indexOfFirst { it.id == conv.id }
                                val to = items.indexOfFirst { it.id == target.key }
                                if (from >= 0 && to >= 0 && from != to) {
                                    val m = items.removeAt(from)
                                    items.add(to, m)
                                    dragStart = centers[conv.id] ?: dragStart
                                    dragTranslation = p - dragStart
                                }
                            }
                        }
                    },
                    onDragEnd = {
                        val d = dragItem
                        val zone = hoverZone
                        dragItem = null; dragTranslation = Offset.Zero; hoverZone = null; armedId = null
                        if (d != null) when (zone) {
                            DropZone.CALL -> { haptics.success(); onCall(d) }
                            DropZone.DELETE -> { haptics.rigid(); onDelete(d) }
                            null -> {}
                        }
                    },
                    onDragCancel = {
                        dragItem = null; dragTranslation = Offset.Zero; hoverZone = null; armedId = null
                    },
                )
            },
    ) {
        // Grid (3 columns) inside a scroll container; scroll locks while dragging.
        val scroll = rememberScrollState()
        Column(
            Modifier
                .fillMaxSize()
                .then(if (dragItem == null) Modifier.verticalScroll(scroll) else Modifier)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            items.chunked(3).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    row.forEach { conv ->
                        Box(
                            Modifier
                                .weight(1f)
                                .onGloballyPositioned { coords ->
                                    val p = coords.positionInRoot()
                                    centers[conv.id] = Offset(
                                        p.x - rootOrigin.x + coords.size.width / 2f,
                                        p.y - rootOrigin.y + coords.size.height / 2f,
                                    )
                                }
                                .scale(if (armedId == conv.id) 1.08f else 1f)
                                .alpha(if (dragItem?.id == conv.id) 0.001f else 1f)
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                ) { if (dragItem == null) onOpen(conv) },
                        ) {
                            GridCard(conv, Modifier.fillMaxWidth())
                        }
                    }
                    // pad incomplete rows so cards keep their column width
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            Spacer(Modifier.height(90.dp))
        }

        // Side drop zones (only while dragging)
        AnimatedVisibility(
            visible = dragItem != null,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier.fillMaxSize(),
        ) {
            Row(
                Modifier.fillMaxSize().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DropZoneView(DropZone.CALL, Icons.Default.Call, "Call", VoiidColor.primary, hoverZone == DropZone.CALL)
                Spacer(Modifier.weight(1f))
                DropZoneView(DropZone.DELETE, Icons.Default.Delete, "Delete", VoiidColor.error, hoverZone == DropZone.DELETE)
            }
        }

        // Floating dragged card
        dragItem?.let { d ->
            val p = dragStart + dragTranslation
            Box(
                Modifier
                    .zIndex(10f)
                    .offset {
                        androidx.compose.ui.unit.IntOffset(
                            (p.x - cardPx / 2f).toInt(),
                            (p.y - cardPx * 1.1f / 2f).toInt(),
                        )
                    }
                    .width(96.dp)
                    .scale(1.12f)
                    .shadow(14.dp, RoundedCornerShape(VoiidRadius.lg)),
            ) {
                GridCard(d, Modifier.fillMaxWidth())
            }
        }
    }
}

private fun mutableStateMapOfCenters() = androidx.compose.runtime.mutableStateMapOf<String, Offset>()

@Composable
private fun DropZoneView(zone: DropZone, icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, color: Color, active: Boolean) {
    val scale by animateFloatAsState(if (active) 1.2f else 1f, label = "zoneScale")
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.scale(scale).alpha(if (active) 1f else 0.85f),
    ) {
        Box(
            Modifier.size(60.dp).shadow(if (active) 14.dp else 8.dp, CircleShape).clip(CircleShape).background(color),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, label, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(24.dp)) }
        Text(label, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = color)
    }
}

@Composable
private fun SearchSectionLabel(text: String) {
    Text(
        text, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary,
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 8.dp),
    )
}

@Composable
private fun SearchChatRow(conv: VConversation, onClick: () -> Unit) {
    Row(
        // softClickable, not clickable: these rows had NO press feedback at all, so a search
        // result felt dead next to a chat row that responds on press-down. It also carries the
        // haptic, which is why the call sites no longer fire their own.
        Modifier.fillMaxWidth().softClickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(VoiidColor.fieldFill), Alignment.Center) {
            Text(conv.title.take(1).uppercase(), style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.primary)
        }
        Spacer(Modifier.width(12.dp))
        Text(conv.title, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

@Composable
private fun SearchContactRow(c: VContact, onClick: () -> Unit) {
    Row(
        // See SearchChatRow — same missing press feedback, same fix.
        Modifier.fillMaxWidth().softClickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(VoiidColor.fieldFill), Alignment.Center) {
            Text(c.displayName.take(1).uppercase(), style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.primary)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(c.displayName, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary)
            Text("Tap to start chat", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
    }
}

/**
 * Two rows, not one: your own avatar sits alone at the TOP-LEFT and the "Chats" title sits
 * BELOW it. The avatar is the way into Settings — everything that used to hide behind the
 * overflow menu (backup, log out) plus the things that had no home at all (profile photo,
 * display name), so the menu is gone.
 */
@Composable
private fun Header(
    haptics: com.voiid.app.ui.components.VoiidHaptics,
    photoUrl: String?,
    myName: String?,
    search: String,
    onSearchChange: (String) -> Unit,
    onNewChat: () -> Unit,
    onNewGroup: () -> Unit,
    onFindByUsername: () -> Unit,
    onOpenCallLog: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    // Avatar - search - actions, on ONE row.
    //
    // The screen used to spend three stacked bands before the first chat: an avatar row, a
    // 28sp "Chats" title, then a 52dp search field. Roughly a third of the display was chrome
    // telling you that you were in the app you had just opened.
    //
    // The title goes first — it named the tab already selected in the bar at the bottom of
    // the screen, in the app whose icon you just tapped. Then the search field slots between
    // the controls that were already on that row, putting the most-used control on a chat
    // list at thumb height rather than under a title. Mirrors iOS `compactHeader`.
    val shape = RoundedCornerShape(VoiidRadius.pill)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ProfileAvatar(
            photoUrl = photoUrl,
            name = myName,
            // 40, matching the glyph buttons opposite it.
            size = 40.dp,
            modifier = Modifier.softClickable(scale = 0.92f) { haptics.tap(); onOpenSettings() },
        )

        Row(
            Modifier
                .weight(1f)
                // 40dp, down from 52 — it no longer has a whole band to itself, so it can
                // match the height of the controls beside it instead of towering over them.
                .height(40.dp)
                .clip(shape)
                .background(VoiidColor.fieldFill)
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.size(18.dp))
            BasicTextField(
                value = search,
                onValueChange = onSearchChange,
                singleLine = true,
                textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                cursorBrush = SolidColor(VoiidColor.primary),
                modifier = Modifier.weight(1f),
                decorationBox = { inner ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (search.isEmpty()) {
                            Text("Search", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                        }
                        inner()
                    }
                },
            )
            if (search.isNotEmpty()) {
                Icon(
                    Icons.Default.Close, "Clear search", tint = VoiidColor.placeholder,
                    modifier = Modifier.size(16.dp).clip(CircleShape)
                        .clickable { haptics.tap(); onSearchChange("") },
                )
            }
        }

        // ONE menu, not two glyphs. Every way to start a conversation lives in one list, and
        // an ellipsis promises exactly what it delivers: more options. Mirrors iOS.
        Box {
            var menuOpen by remember { mutableStateOf(false) }
            HeaderGlyph(Icons.Default.MoreVert, "More") { haptics.tap(); menuOpen = true }
            VoiidMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                VoiidMenuItem("New chat", Icons.Default.PersonAdd) {
                    menuOpen = false; haptics.tap(); onNewChat()
                }
                VoiidMenuItem("Find by username", Icons.Default.AlternateEmail) {
                    menuOpen = false; haptics.tap(); onFindByUsername()
                }
                VoiidMenuItem("New group", Icons.Default.Groups) {
                    menuOpen = false; haptics.tap(); onNewGroup()
                }
                // The divider separates "start something" from "go somewhere" — the two
                // groups this menu actually contains.
                VoiidMenuDivider()
                VoiidMenuItem("Calls", Icons.Default.Call) {
                    menuOpen = false; haptics.tap(); onOpenCallLog()
                }
                // SETTINGS IS HERE TOO, not only behind the avatar. Tapping your own face to
                // reach app settings is a convention people learn, not one they guess — this
                // is the discoverable path, and the avatar stays as the shortcut.
                VoiidMenuItem("Settings", Icons.Default.Settings) {
                    menuOpen = false; haptics.tap(); onOpenSettings()
                }
            }
        }
    }
}

/** A 38dp tinted disc, matching the avatar's size so the row reads as one set of controls. */
@Composable
private fun HeaderGlyph(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    onClick: () -> Unit,
) {
    // 40dp, matching the avatar beside it — mismatched sizes on one row read as a
    // misalignment rather than as a smaller element.
    //
    // NO GLASS EQUIVALENT ON ANDROID. iOS gets `.glassEffect` on 26 and `.ultraThinMaterial`
    // below it; Compose has neither, and a backdrop blur here would need a RenderEffect pass
    // that costs more than it is worth on mid-tier hardware for a 40dp button. A tinted disc
    // with the same lit hairline is the honest equivalent — it reads as a raised control
    // without pretending to a material the platform cannot draw.
    Box(
        Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(VoiidColor.primary.copy(alpha = 0.10f))
            .border(1.dp, VoiidColor.textPrimary.copy(alpha = 0.08f), CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, description, tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun Tabs(selected: ChatTab, onSelect: (ChatTab) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 24.dp)) {
        val slot = maxWidth / 2
        val underlineX by animateDpAsState(
            targetValue = slot * selected.ordinal,
            animationSpec = spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMedium),
            label = "underlineX",
        )
        Column {
            Row(Modifier.fillMaxWidth()) {
                ChatTab.entries.forEach { t ->
                    Box(
                        Modifier
                            .weight(1f)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { onSelect(t) }
                            .padding(bottom = 8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            t.label,
                            style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = if (selected == t) VoiidColor.primary else VoiidColor.textSecondary,
                        )
                    }
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        }
        Box(
            Modifier
                .offset(x = underlineX)
                .align(Alignment.BottomStart)
                .size(width = slot, height = 3.dp)
                .background(Brush.horizontalGradient(listOf(VoiidColor.primary, VoiidColor.accent))),
        )
    }
}

@Composable
private fun GridCard(conv: VConversation, modifier: Modifier) {
    val context = LocalContext.current
    // The peer's real face. Directory first (authoritative + recomposes on a contacts sync),
    // then the members payload carried on the conversation. Groups have no peer, so they keep
    // the wordmark until group photos exist as a feature.
    val photoRef = conv.peerUserId?.let { UserDirectory.photoUrl(it) } ?: conv.photoURL
    // Memory hit paints on the FIRST frame (no flash of wordmark on a cached face); the
    // LaunchedEffect only runs for a genuine miss, and AvatarCache single-flights it.
    var avatar by remember(photoRef) { mutableStateOf(AvatarCache.cached(photoRef)) }
    LaunchedEffect(photoRef) {
        if (avatar == null) avatar = AvatarCache.resolve(context, photoRef)
    }

    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f)) {
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.fieldFill),
                contentAlignment = Alignment.Center,
            ) {
                val bmp = avatar
                if (conv.type == ConversationType.SELF) {
                    // NOTE TO SELF gets its own mark, not a profile photo. It is the one chat
                    // with no other person in it, and rendering your own face there reads as
                    // a conversation with someone else. A bookmark on brand tint says "saved"
                    // at a glance. Mirrors iOS.
                    Box(
                        Modifier.fillMaxSize().background(VoiidColor.primary.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Default.Bookmark, null,
                            tint = VoiidColor.primary,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                } else if (bmp != null) {
                    Image(
                        bitmap = bmp,
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                } else {
                    // iOS renders the wordmark image at width 56pt (~52% of card), very faint.
                    VoiidWordmark(fontSize = 23, alpha = 0.15f)
                }
            }
            // Badges sit INSIDE the tile. They used to be pushed OUT past its edge (offset
            // x 6, y -6), which broke the grid's alignment and let a badge overlap the tile
            // beside it. Matches iOS ChatsHomeView.gridCard.
            if (conv.isOnline) {
                Box(
                    Modifier
                        .align(Alignment.BottomStart)
                        .padding(6.dp)
                        .size(12.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.background)
                        .padding(2.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.success),
                )
            }
            // Same arrival and same rolling digit as the list row's badge — the two layouts
            // must teach ONE vocabulary, so the badge behaves identically whichever you have
            // chosen. AnimatedVisibility rather than a bare `if` so the removal has an exit.
            androidx.compose.animation.AnimatedVisibility(
                visible = conv.unreadCount > 0,
                modifier = Modifier.align(Alignment.TopEnd),
                enter = androidx.compose.animation.scaleIn(
                    animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMedium),
                    initialScale = 0.5f,
                    transformOrigin = TransformOrigin(1f, 0f),
                ) + androidx.compose.animation.fadeIn(),
                exit = androidx.compose.animation.scaleOut(
                    targetScale = 0.5f,
                    transformOrigin = TransformOrigin(1f, 0f),
                ) + androidx.compose.animation.fadeOut(),
            ) {
                Box(
                    Modifier
                        .padding(5.dp)
                        .size(20.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.accent),
                    contentAlignment = Alignment.Center,
                ) {
                    androidx.compose.animation.AnimatedContent(
                        targetState = conv.unreadCount,
                        transitionSpec = {
                            (androidx.compose.animation.slideInVertically { h -> h } +
                                androidx.compose.animation.fadeIn()) togetherWith
                                (androidx.compose.animation.slideOutVertically { h -> -h } +
                                    androidx.compose.animation.fadeOut())
                        },
                        label = "gridUnread",
                    ) { count ->
                        Text(
                            "$count",
                            style = VoiidFont.rounded(11, FontWeight.Bold),
                            // textOnAccent, NOT textOnPrimary: amber is a light fill in both
                            // themes, and textOnPrimary flips to near-white in light mode,
                            // where it measured 3.31:1 here — the least legible text on this
                            // screen.
                            color = VoiidColor.textOnAccent,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(conv.title, style = VoiidFont.rounded(13), color = VoiidColor.textPrimary, maxLines = 1)
    }
}

// MARK: - Empty / loading states

/**
 * A failed refresh WITH cached content still on screen: a quiet banner above the list, not a
 * takeover. The cache is good — the user keeps their chats and learns the sync didn't land.
 * Mirrors iOS `loadError` banner.
 */
@Composable
private fun ChatsErrorBanner(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.fieldFill)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Default.Wifi, null, tint = VoiidColor.error, modifier = Modifier.size(16.dp))
        Text(
            message,
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            modifier = Modifier.weight(1f),
        )
        Text(
            "Retry",
            style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.primary,
            modifier = Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { onRetry() },
        )
    }
}

/**
 * A failed FIRST load with nothing cached: the honest full state. "No chats yet" would be a
 * claim we cannot make — the truth is that loading failed.
 */
@Composable
private fun ChatsRetryState(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    val haptics = LocalVoiidHaptics.current
    Column(
        modifier.padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Default.CloudOff, null,
            tint = VoiidColor.textSecondary, modifier = Modifier.size(44.dp),
        )
        Spacer(Modifier.height(14.dp))
        Text("Couldn't load your chats", style = VoiidFont.rounded(17, FontWeight.SemiBold),
             color = VoiidColor.textPrimary)
        Spacer(Modifier.height(6.dp))
        Text(
            message,
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(18.dp))
        Box(
            Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(VoiidColor.primary)
                .clickable { haptics.tap(); onRetry() }
                .padding(horizontal = 24.dp, vertical = 10.dp),
        ) {
            Text("Try again", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                 color = VoiidColor.textOnPrimary)
        }
    }
}

/**
 * Shown while the FIRST load is still in flight and nothing is cached.
 *
 * Deliberately not a bare spinner in a void: six dimmed tiles in the same grid shape the real
 * chats will occupy, so the layout does not jump when content lands and the screen reads as
 * "filling in" rather than "empty". The pulse is what separates LOADING from BROKEN — a
 * static grey grid reads as content that failed to render. Mirrors iOS `chatsLoadingState`.
 */
@Composable
private fun ChatsLoadingState(modifier: Modifier = Modifier) {
    val pulse = rememberInfiniteTransition(label = "skeleton")
    val alpha by pulse.animateFloat(
        0.45f, 0.85f,
        infiniteRepeatable(tween(1100), RepeatMode.Reverse),
        label = "skeletonAlpha",
    )
    Column(
        modifier.padding(horizontal = 24.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        repeat(3) {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.fillMaxWidth()) {
                repeat(2) {
                    Box(
                        Modifier
                            .weight(1f)
                            .height(104.dp)
                            .clip(RoundedCornerShape(VoiidRadius.lg))
                            .alpha(alpha)
                            .background(VoiidColor.surfaceCard),
                    )
                }
            }
        }
    }
}

/**
 * A genuinely empty list — a fresh account, or one that has never started a chat.
 *
 * AN EMPTY STATE MUST OFFER THE WAY OUT. Saying "no chats yet" and stopping leaves the user
 * to hunt for the button; both routes into a first conversation are right here.
 */
@Composable
private fun ChatsEmptyState(
    isGroups: Boolean,
    onNewChat: () -> Unit,
    onFindByUsername: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier.size(88.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (isGroups) Icons.Default.Groups else Icons.Default.ChatBubble,
                null, tint = VoiidColor.primary, modifier = Modifier.size(32.dp),
            )
        }
        Spacer(Modifier.height(16.dp))
        Text(
            if (isGroups) "No groups yet" else "No chats yet",
            style = VoiidFont.rounded(20, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            if (isGroups) "Groups you create or get added to will appear here."
            else "Start a conversation with someone in your contacts, or find them by @username.",
            style = VoiidFont.rounded(14),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
        )
        if (!isGroups) {
            Spacer(Modifier.height(20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(VoiidColor.primary)
                        .clickable(onClick = onNewChat)
                        .padding(horizontal = 18.dp, vertical = 12.dp),
                ) {
                    Text("New chat", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textOnPrimary)
                }
                Box(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(VoiidColor.primary.copy(alpha = 0.10f))
                        .clickable(onClick = onFindByUsername)
                        .padding(horizontal = 18.dp, vertical = 12.dp),
                ) {
                    Text("Find by @username", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.primary)
                }
            }
        }
    }
}
