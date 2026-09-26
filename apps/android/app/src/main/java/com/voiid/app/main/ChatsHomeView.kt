package com.voiid.app.main

import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.gestures.awaitTouchSlopOrCancellation
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.material.icons.filled.Apps
import com.voiid.app.ui.theme.VoiidSpacing
import androidx.compose.ui.focus.focusRequester
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.GridView
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
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import com.voiid.app.main.walkthrough.SpotlightShapeType
import com.voiid.app.main.walkthrough.spotlightTarget
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
import androidx.compose.material.icons.filled.QrCode2
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
import androidx.compose.material.icons.filled.PushPin
import com.voiid.app.ui.components.VoiidMenuItem
import androidx.compose.material.icons.filled.Star
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
    onOpenSocialProfile: () -> Unit,
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
    var showScanner by remember { mutableStateOf(false) }
    /** Handle carried from a scan into Find by username, cleared when that screen closes. */
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

    androidx.compose.runtime.LaunchedEffect(Unit) {
        com.voiid.app.main.walkthrough.WalkthroughNavigationBus.openSettingsEvents.collect { shouldOpen ->
            if (shouldOpen) {
                if (settingsNav.current == null) {
                    settingsNav.push("settings")
                }
            } else {
                if (settingsNav.current != null) {
                    settingsNav.closeAll()
                }
            }
        }
    }
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
            title = tab.label,
            search = search,
            onSearchChange = { search = it },
            onNewChat = { forceGroup = false; showNewChat = true },
            // Set on OPEN, both ways. Resetting on close would mean covering four separate
            // dismiss paths (dismiss, two onClose, two onOpen) and one of them will always be
            // missed — a stale `true` would then turn the next "New chat" into a group.
            onNewGroup = { forceGroup = true; showNewChat = true },
            onFindByUsername = { showFindByUsername = true },
            onScanCode = { showScanner = true },
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
                    onNewChat = { haptics.tap(); forceGroup = false; showNewChat = true },
                    onNewGroup = { haptics.tap(); forceGroup = true; showNewChat = true },
                    onFindByUsername = { haptics.tap(); showFindByUsername = true },
                    onScanCode = { haptics.tap(); showScanner = true },
                    noteToSelf = if (tab == ChatTab.CHATS) chat.directConversations.firstOrNull { it.type == ConversationType.SELF } else null,
                    onOpenNoteToSelf = { note -> haptics.tap(); onOpenConversation(note) },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
                ChatLayoutPreference.layout == ChatLayout.GRID -> DraggableChatGrid(
                    items = list,
                    onOpen = { haptics.tap(); onOpenConversation(it) },
                    onCall = { callTarget = it },
                    onDelete = { deleteTarget = it },
                    onPin = { chat.setPinned(it.id, it.pinnedAt == null) },
                    onStar = { chat.setStarred(it.id, !it.isStarred) },
                    onReorder = { chat.setSortOrder(it) },
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
    // Same activity-scoped instance RootTabView hoists for the Clips gate.
    val creators: com.voiid.app.model.SocialStore = androidx.lifecycle.viewmodel.compose.viewModel()
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
                onEditProfile = { settingsNav.push("editProfile") },
                onShareProfile = { settingsNav.push("shareProfile") },
                onMyQrCode = { settingsNav.push("myQrCode") },
                // The banner STATES a fact rather than opening a door. iOS's
                // EncryptionStatusScreen lives in PreviewSettingsScreens and is marked
                // unwired there, so porting it would ship a screen neither platform has
                // finished. Per-conversation verification is where the real artefact lives
                // (SafetyNumberScreen, reached from a chat, which needs a peer).
                onSafetyNumber = {},
                onHelp = { settingsNav.push("help") },
                onChatSettings = { settingsNav.push("chatSettings") },
                onAccountCentre = { settingsNav.push("accountCentre") },
                onSocialProfile = { settingsNav.closeAll(); onOpenSocialProfile() },
            )
            "accountCentre" -> AccountCenterScreen(
                creators = creators,
                onBack = settingsNav::pop,
                onChatProfile = { settingsNav.push("editProfile") },
                onViewSocialProfile = { settingsNav.closeAll(); onOpenSocialProfile() },
                onProfileSettings = { settingsNav.push("socialPrivacy") },
            )
            "socialPrivacy" -> com.voiid.app.main.clips.SocialPrivacyScreen(creators = creators, onBack = settingsNav::pop)
            "chatSettings" -> ChatSettingsScreen(onBack = settingsNav::pop)
            "editProfile" -> EditProfileScreen(session = session, onBack = settingsNav::pop)
            "shareProfile" -> ShareProfileScreen(session = session, onBack = settingsNav::pop)
            "myQrCode" -> MyQrCodeScreen(session = session, onBack = settingsNav::pop)
            "help" -> HelpAndSupportScreen(
                onBack = settingsNav::pop,
                onReplayWalkthrough = {
                    com.voiid.app.main.walkthrough.WalkthroughReplayBus.request()
                    settingsNav.closeAll()
                },
                onLinkedDevices = { settingsNav.push("devices") },
                onBackupRecovery = { settingsNav.push("backup") },
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
    if (showScanner) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showScanner = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = false, dismissOnClickOutside = false),
        ) {
            ScanQrCodeScreen(
                onBack = { showScanner = false },
                onOpen = { conversationId, pending ->
                    showScanner = false
                    reachScope.launch {
                        chat.loadConversations()
                        if (!pending) chat.directConversations.firstOrNull { it.id == conversationId }?.let(onOpenConversation)
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

/** How long a stationary press takes to open the grid's dropdown. Matches iOS. */
private const val HOLD_SECONDS = 3f

@Composable
private fun DraggableChatGrid(
    items: SnapshotStateList<VConversation>,
    onOpen: (VConversation) -> Unit,
    onCall: (VConversation) -> Unit,
    onDelete: (VConversation) -> Unit,
    onPin: (VConversation) -> Unit = {},
    onStar: (VConversation) -> Unit = {},
    onReorder: (List<String>) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    val centers = remember { mutableStateMapOfCenters() }
    // Each tile's real bounds. A touch picks a tile only when it lands ON that tile — the
    // nearest-centre search used to grab one from anywhere on the grid, gaps included.
    val tileRects = remember { mutableStateMapOf<String, androidx.compose.ui.geometry.Rect>() }
    fun tileAt(p: Offset): VConversation? =
        items.firstOrNull { tileRects[it.id]?.contains(p) == true }   // only tiles still on screen
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    var containerWidthPx by remember { mutableStateOf(0f) }

    var dragItem by remember { mutableStateOf<VConversation?>(null) }
    var dragStart by remember { mutableStateOf(Offset.Zero) }
    var dragTranslation by remember { mutableStateOf(Offset.Zero) }
    var hoverZone by remember { mutableStateOf<DropZone?>(null) }
    var armedId by remember { mutableStateOf<String?>(null) }
    // A stationary press in progress, and how far through it is (0..1). At 1 the dropdown
    // opens. Distinct from a drag: a press that MOVES becomes a drag, one that stays put
    // becomes the menu. Mirrors iOS.
    var holdingId by remember { mutableStateOf<String?>(null) }
    var holdProgress by remember { mutableStateOf(0f) }
    // The tile whose dropdown is open.
    var menuItem by remember { mutableStateOf<VConversation?>(null) }
    // Where the two zone circles actually are, measured from the rendered view. Hit-testing
    // against these rather than against an edge STRIP is what makes "drop on the icon" mean
    // what it says — the old `p.x < gutterPx` fired anywhere down the whole margin.
    val zoneCenters = remember { mutableStateMapOf<DropZone, Offset>() }

    val gutterPx = with(density) { 70.dp.toPx() }
    // 34dp, not 60. On a three-column grid 60 is true almost everywhere, so tiles reshuffled
    // continuously as the finger crossed the board. 34 is roughly the inner third of a tile:
    // you have to be ON a neighbour to displace it. Mirrors iOS.
    val reorderPx = with(density) { 34.dp.toPx() }
    // How close to a zone CIRCLE counts as dropping on it.
    val zoneHitPx = with(density) { 52.dp.toPx() }
    // How far the finger may stray before the press stops counting as stationary.
    val holdSlopPx = with(density) { 12.dp.toPx() }

    // THE HOLD CLOCK. Runs only while a finger is down and stationary, and is cancelled by
    // the drag above the moment it moves. At full duration the dropdown opens and the tile
    // is released, so the card is not left scaled up behind an open menu.
    LaunchedEffect(holdingId) {
        val id = holdingId ?: return@LaunchedEffect
        val started = System.currentTimeMillis()
        while (holdingId == id) {
            val elapsed = (System.currentTimeMillis() - started) / 1000f
            holdProgress = (elapsed / HOLD_SECONDS).coerceAtMost(1f)
            if (elapsed >= HOLD_SECONDS) {
                haptics.success()
                menuItem = items.firstOrNull { it.id == id }
                holdingId = null
                holdProgress = 0f
                dragItem = null
                dragTranslation = Offset.Zero
                armedId = null
                break
            }
            kotlinx.coroutines.delay(33)
        }
    }
    val cardPx = with(density) { 96.dp.toPx() }

    Box(
        modifier
            .onGloballyPositioned {
                rootOrigin = it.positionInRoot()
                containerWidthPx = it.size.width.toFloat()
            }
            // Container-level long-press drag: independent of item composables, so live reorder
            // never cancels the gesture (mirrors iOS DraggableChatGrid pick-up + drag).
            // TOUCH-DOWN, which detectDragGestures below never reports: onDragStart only
            // fires once Compose has RECOGNISED a drag, i.e. after the finger has already
            // moved. A press that stays perfectly still therefore never reached it, the
            // three-second clock never started, and the dropdown could not open at all.
            //
            // awaitFirstDown sees the touch itself, so the clock starts the instant a finger
            // lands. The drag below cancels it on real movement; releasing cancels it too.
            // ONE gesture per touch, claimed ONLY when it starts on a tile — iOS attaches the
            // drag to each tile, so a swipe anywhere else reaches the tab pager. The old
            // container detector took every drag on the grid, gaps included, so swiping
            // between tabs from the Chats screen did nothing.
            .pointerInput(items.size) {
                fun startDrag(offset: Offset) {
                        val picked = tileAt(offset)
                        if (picked != null) {
                            haptics.rigid()
                            armedId = picked.id
                            dragItem = picked
                            dragStart = centers[picked.id] ?: offset
                            dragTranslation = Offset.Zero
                        }
                }
                fun moveDrag(change: androidx.compose.ui.input.pointer.PointerInputChange, amount: Offset) {
                        // No tile under the finger: leave the gesture to the scroll.
                        val conv = dragItem ?: return
                        change.consume()
                        dragTranslation += amount
                        // Moved too far to be a hold: this is a drag.
                        if (hypot(dragTranslation.x.toDouble(), dragTranslation.y.toDouble()) > holdSlopPx) {
                            holdingId = null
                            holdProgress = 0f
                        }
                        val p = dragStart + dragTranslation
                        // DROP ON THE ICON, not merely on that side of the screen. The old
                        // test was the entire left/right strip top to bottom, so a tile
                        // dragged anywhere near a margin called or deleted whether or not
                        // the icon was near the finger.
                        val zone = zoneCenters.entries.firstOrNull {
                            hypot((it.value.x - p.x).toDouble(), (it.value.y - p.y).toDouble()) < zoneHitPx
                        }?.key
                        if (zone != hoverZone) {
                            hoverZone = zone
                            if (zone != null) haptics.tap()   // the edge announces itself
                        }
                        if (hoverZone == null) {
                            // A tile only swaps with its OWN KIND — pinned with pinned,
                            // unpinned with unpinned. Move a pinned chat and it rearranges
                            // among the other pins; move an unpinned one past a pin and the
                            // pin stays put, because a neighbour's drag is not permission to
                            // move it. Crossing the boundary is refused because the query
                            // sorts pinned above unpinned, so the tile would spring back on
                            // the next read.
                            val draggedIsPinned = conv.pinnedAt != null
                            val sameBlock = items.filter { (it.pinnedAt != null) == draggedIsPinned }
                                .map { it.id }.toSet()
                            val target = centers.entries
                                .filter { it.key != conv.id && sameBlock.contains(it.key) }
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
                }
                fun endDrag() {
                        val d = dragItem
                        val zone = hoverZone
                        dragItem = null; dragTranslation = Offset.Zero; hoverZone = null; armedId = null; holdingId = null; holdProgress = 0f
                        if (d != null) when (zone) {
                            DropZone.CALL -> { haptics.success(); onCall(d) }
                            DropZone.DELETE -> { haptics.rigid(); onDelete(d) }
                            // PERSIST ON DROP. This branch used to be empty, so an
                            // arrangement lived only in the in-memory list and was discarded
                            // the moment anything refreshed — the same bug iOS had before
                            // sort_index existed. One write per arrangement, not per swap.
                            null -> onReorder(items.map { it.id })
                        }
                }
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val picked = tileAt(down.position) ?: return@awaitEachGesture   // not on a tile: leave it to the pager/scroll
                    // TOUCH-DOWN starts the hold clock; releasing or moving stops it.
                    holdingId = picked.id
                    holdProgress = 0f
                    val slop = awaitTouchSlopOrCancellation(down.id) { change, _ -> change.consume() }
                    if (slop == null) {   // a tap (the tile's clickable opens it) or a cancel
                        holdingId = null; holdProgress = 0f
                        return@awaitEachGesture
                    }
                    startDrag(down.position)
                    moveDrag(slop, slop.position - down.position)
                    val completed = drag(slop.id) { change -> moveDrag(change, change.positionChange()) }
                    if (completed) endDrag() else {
                        dragItem = null; dragTranslation = Offset.Zero; hoverZone = null; armedId = null; holdingId = null; holdProgress = 0f
                    }
                }
            },
    ) {
        // Grid (3 columns) inside a scroll container; scroll locks while dragging.
        val scroll = rememberScrollState()
        Column(
            Modifier
                .fillMaxSize()
                .then(if (dragItem == null) Modifier.verticalScroll(scroll) else Modifier)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            items.chunked(3).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
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
                                    tileRects[conv.id] = androidx.compose.ui.geometry.Rect(
                                        p.x - rootOrigin.x, p.y - rootOrigin.y,
                                        p.x - rootOrigin.x + coords.size.width,
                                        p.y - rootOrigin.y + coords.size.height,
                                    )
                                }
                                .scale(if (armedId == conv.id) 1.08f else 1f)
                                .alpha(if (dragItem?.id == conv.id) 0.001f else 1f)
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                ) { if (dragItem == null) onOpen(conv) },
                        ) {
                            GridCard(conv, Modifier.fillMaxWidth(),
                                holdProgress = if (holdingId == conv.id) holdProgress else 0f)
                            // VoiidMenu, the app's own dropdown — same surface, elevation,
                            // corner and row metrics as the toolbar overflow and the
                            // composer's attach menu, so this matches by construction
                            // instead of by my approximation of it.
                            com.voiid.app.ui.components.VoiidMenu(
                                expanded = menuItem?.id == conv.id,
                                onDismissRequest = { menuItem = null },
                                alignEnd = false,
                            ) {
                                VoiidMenuItem(
                                    if (conv.pinnedAt == null) "Pin" else "Unpin",
                                    Icons.Default.PushPin,
                                ) { menuItem = null; onPin(conv) }
                                VoiidMenuItem(
                                    if (conv.isStarred) "Remove Star" else "Star",
                                    Icons.Default.Star,
                                ) { menuItem = null; onStar(conv) }
                                VoiidMenuItem(
                                    "Call", Icons.Default.Call,
                                ) { menuItem = null; onCall(conv) }
                                VoiidMenuItem(
                                    "Delete Chat", Icons.Default.Delete, destructive = true,
                                ) { menuItem = null; onDelete(conv) }
                            }
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
                DropZoneView(DropZone.CALL, Icons.Default.Call, "Call", VoiidColor.primary,
                    hoverZone == DropZone.CALL, rootOrigin) { z, c -> zoneCenters[z] = c }
                Spacer(Modifier.weight(1f))
                DropZoneView(DropZone.DELETE, Icons.Default.Delete, "Delete", VoiidColor.error,
                    hoverZone == DropZone.DELETE, rootOrigin) { z, c -> zoneCenters[z] = c }
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
private fun DropZoneView(
    zone: DropZone,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    color: Color,
    active: Boolean,
    rootOrigin: Offset = Offset.Zero,
    onCentre: (DropZone, Offset) -> Unit = { _, _ -> },
) {
    val scale by animateFloatAsState(if (active) 1.2f else 1f, label = "zoneScale")
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.scale(scale).alpha(if (active) 1f else 0.85f),
    ) {
        Box(
            Modifier
                .size(60.dp)
                .onGloballyPositioned {
                    // positionInRoot + half the size, matching how the tiles are measured
                    // a few hundred lines up — one convention, so the drag point and the
                    // circles are directly comparable.
                    val p = it.positionInRoot()
                    onCentre(zone, Offset(p.x + it.size.width / 2f, p.y + it.size.height / 2f) - rootOrigin)
                }
                .shadow(if (active) 14.dp else 8.dp, CircleShape).clip(CircleShape).background(color),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, label, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(24.dp)) }
        // White, like the glyph above it, rather than the zone's own colour. The circle
        // already carries the colour; repeating it in the label made the word compete with
        // the target instead of naming it. Mirrors iOS.
        Text(label, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White)
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
 * iOS ChatsHomeView `referenceHeader` + `titleRow` + `searchField`, measurement for measurement:
 *   row 1 — avatar (38, green presence dot) · centred wordmark (26) · search · ⋯   (36 circles)
 *   row 2 — "Chats"/"Groups" (26 bold rounded) · "+ New chat" accent pill (38 tall) · layout toggle
 *   search field (40, capsule) only while searching.
 */
@Composable
private fun Header(
    haptics: com.voiid.app.ui.components.VoiidHaptics,
    photoUrl: String?,
    myName: String?,
    title: String,
    search: String,
    onSearchChange: (String) -> Unit,
    onNewChat: () -> Unit,
    onNewGroup: () -> Unit,
    onFindByUsername: () -> Unit,
    onScanCode: () -> Unit,
    onOpenCallLog: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val context = LocalContext.current
    var searching by remember { mutableStateOf(search.isNotEmpty()) }
    Column {
        // ── Row 1: identity · wordmark · controls ──
        Box(Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md, vertical = VoiidSpacing.sm)) {
            Box(
                Modifier.align(Alignment.CenterStart)
                    .spotlightTarget(id = "nav_header_profile", shape = SpotlightShapeType.CIRCLE, padding = 6.dp)
                    .softClickable(scale = 0.92f) { haptics.tap(); onOpenSettings() }
                    .semantics { contentDescription = "Your profile" },
            ) {
                ProfileAvatar(photoUrl = photoUrl, name = myName, size = 38.dp)
                Box(
                    Modifier.align(Alignment.BottomEnd).size(12.dp).clip(CircleShape)
                        .background(VoiidColor.background).padding(2.dp).clip(CircleShape)
                        .background(VoiidColor.success),
                )
            }
            com.voiid.app.onboarding.BrandWordmark(
                size = 26, color = VoiidColor.textPrimary, dotColor = VoiidColor.primary,
                modifier = Modifier.align(Alignment.Center),
            )
            Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                HeaderControl(Icons.Default.Search, if (searching) "Close search" else "Search") {
                    haptics.tap(); searching = !searching; if (!searching) onSearchChange("")
                }
                Box {
                    var menuOpen by remember { mutableStateOf(false) }
                    HeaderControl(Icons.Default.MoreHoriz, "More") { haptics.tap(); menuOpen = true }
                    VoiidMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        VoiidMenuItem("Find by username", Icons.Default.AlternateEmail) {
                            menuOpen = false; haptics.tap(); onFindByUsername()
                        }
                        VoiidMenuItem("Scan code", Icons.Default.QrCode2) {
                            menuOpen = false; haptics.tap(); onScanCode()
                        }
                        VoiidMenuItem("New group", Icons.Default.Groups) {
                            menuOpen = false; haptics.tap(); onNewGroup()
                        }
                        VoiidMenuDivider()
                        VoiidMenuItem("Calls", Icons.Default.Call) {
                            menuOpen = false; haptics.tap(); onOpenCallLog()
                        }
                        VoiidMenuItem("Settings", Icons.Default.Settings) {
                            menuOpen = false; haptics.tap(); onOpenSettings()
                        }
                    }
                }
            }
        }

        // ── Row 2: title · New chat pill · layout toggle ──
        Row(
            Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md).padding(bottom = VoiidSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Text(title, style = VoiidFont.rounded(26, FontWeight.Bold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Row(
                Modifier.height(38.dp).clip(CircleShape).background(VoiidColor.accent)
                    .softClickable { haptics.tap(); onNewChat() }.padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(Icons.Default.Add, null, Modifier.size(17.dp), tint = VoiidColor.textOnAccent)
                Text("New chat", style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textOnAccent)
            }
            val isGrid = ChatLayoutPreference.layout == ChatLayout.GRID
            HeaderControl(
                if (isGrid) Icons.Default.Apps else Icons.AutoMirrored.Filled.List,   // iOS square.grid.3x3.fill
                if (isGrid) "Switch to list view" else "Switch to grid view",
            ) { haptics.selection(); ChatLayoutPreference.set(context, if (isGrid) ChatLayout.LIST else ChatLayout.GRID) }
        }

        // ── Search field, only while searching ──
        androidx.compose.animation.AnimatedVisibility(visible = searching) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md).padding(bottom = VoiidSpacing.sm)
                    .height(40.dp).clip(RoundedCornerShape(VoiidRadius.pill)).background(VoiidColor.fieldFill)
                    .padding(horizontal = VoiidSpacing.md),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.size(16.dp))
                val focus = remember { androidx.compose.ui.focus.FocusRequester() }
                LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
                BasicTextField(
                    value = search, onValueChange = onSearchChange, singleLine = true,
                    textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    modifier = Modifier.weight(1f).focusRequester(focus),
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (search.isEmpty()) Text("Search", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                            inner()
                        }
                    },
                )
                if (search.isNotEmpty()) Icon(
                    Icons.Default.Cancel, "Clear search", tint = VoiidColor.placeholder,
                    modifier = Modifier.size(16.dp).clip(CircleShape).clickable { haptics.tap(); onSearchChange("") },
                )
            }
        }
    }
}

/** iOS `headerControl`: 36 circle, surfaceCard + hairline, 15 glyph in ink, 44 target. */
@Composable
private fun HeaderControl(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(44.dp).clip(CircleShape).clickable(onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(36.dp).clip(CircleShape).background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, CircleShape),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(17.dp)) }
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
            animationSpec = spring(dampingRatio = 0.86f, stiffness = 450f),
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
private fun GridCard(conv: VConversation, modifier: Modifier, holdProgress: Float = 0f) {
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
        // The WHOLE tile is clipped, not just the photo: the name gradient below is a sibling
        // of the photo box, and unclipped it painted square corners over the rounded bottom.
        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(VoiidRadius.lg))) {
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
            // THE COUNTDOWN RING, inside the SQUARE photo box.
            //
            // It used to be a sibling of this whole card, where matchParentSize() spanned the
            // cell rather than the artwork — so the ring was drawn over a taller box than the
            // tile and its bottom edge fell outside the visible square. Drawing it here makes
            // "match the parent" mean the photo, which is what it is tracing.
            if (holdProgress > 0f) {
                val ringColor = VoiidColor.primary
                androidx.compose.foundation.Canvas(Modifier.matchParentSize()) {
                    val r = VoiidRadius.lg.toPx()
                    val stroke = 3.dp.toPx()
                    val inset = stroke / 2f
                    val w = size.width - stroke
                    val h = size.height - stroke
                    // A dim wash so the fill reads against a bright photo.
                    drawRoundRect(
                        color = Color.Black.copy(alpha = 0.28f * holdProgress),
                        topLeft = Offset(inset, inset),
                        size = androidx.compose.ui.geometry.Size(w, h),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(r, r),
                    )
                    // The track, so the ring reads as FILLING rather than as a line that
                    // simply appeared.
                    drawRoundRect(
                        color = Color.White.copy(alpha = 0.25f),
                        topLeft = Offset(inset, inset),
                        size = androidx.compose.ui.geometry.Size(w, h),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(r, r),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                    )
                    // The progress arc. Compose has no "trim a rounded rect" primitive, so
                    // the ring is approximated with a sweep — the same information, and at
                    // 3dp the difference is not visible on a 96dp tile.
                    drawArc(
                        color = ringColor,
                        startAngle = -90f,
                        sweepAngle = 360f * holdProgress,
                        useCenter = false,
                        topLeft = Offset(inset, inset),
                        size = androidx.compose.ui.geometry.Size(w, h),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(
                            stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round
                        ),
                    )
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

            // ── THE LABEL LIVES ON THE PHOTO ────────────────────────────────────
            //
            // Android drew the name BELOW the tile in textPrimary at 13sp regular, one
            // line, and showed no time at all. iOS renders it over the artwork in white
            // semibold across up to two lines with the timestamp top-right, so the same
            // conversation read as two different designs depending on the phone.
            //
            // The gradient is what makes white legible: without it the name sits on
            // whatever the photo happens to be and disappears on a light frame. Bottom
            // weighted so it darkens the label area without dimming the face above it.
            Box(
                Modifier
                    .matchParentSize()
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.55f to Color.Black.copy(alpha = 0.15f),
                            1f to Color.Black.copy(alpha = 0.82f),
                        )
                    )
            )
            Row(
                Modifier
                    .align(Alignment.BottomStart)
                    .padding(horizontal = 9.dp, vertical = 9.dp)
                    // Clears the unread badge in the opposite corner.
                    .padding(end = if (conv.unreadCount > 0) 26.dp else 0.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    conv.title,
                    style = VoiidFont.rounded(13.5f, FontWeight.SemiBold),
                    color = Color.White,
                    maxLines = 2,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
            }
            // The SAME formatter the list row uses, so one conversation reads identically
            // in either layout.
            conv.lastMessageAt?.let { at ->
                Text(
                    VoiidDate.listPreview(at),
                    style = VoiidFont.rounded(11, FontWeight.Medium),
                    color = Color.White.copy(alpha = 0.9f),
                    modifier = Modifier.align(Alignment.TopEnd).padding(9.dp),
                )
            }
            // Pin and star share the one free corner — the time owns top-end and the unread
            // badge owns bottom-end. Small on purpose: states you set deliberately and then
            // recognise at a glance, not signals competing with unread for attention.
            if (conv.pinnedAt != null || conv.isStarred) {
                Row(
                    Modifier.align(Alignment.TopStart).padding(9.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (conv.pinnedAt != null) {
                        Icon(
                            Icons.Default.PushPin, null,
                            tint = Color.White.copy(alpha = 0.95f),
                            modifier = Modifier.size(11.dp),
                        )
                    }
                    if (conv.isStarred) {
                        Icon(
                            Icons.Default.Star, null,
                            tint = Color.White.copy(alpha = 0.95f),
                            modifier = Modifier.size(11.dp),
                        )
                    }
                }
            }
        }
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
    onNewGroup: () -> Unit = {},
    onFindByUsername: () -> Unit,
    onScanCode: () -> Unit,
    noteToSelf: VConversation? = null,
    onOpenNoteToSelf: (VConversation) -> Unit = {},
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
        Spacer(Modifier.height(20.dp))
        if (isGroups) {
            Box(
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(VoiidColor.primary)
                    .clickable(onClick = onNewGroup)
                    .padding(horizontal = 24.dp, vertical = 12.dp),
            ) {
                Text("New group", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textOnPrimary)
            }
        } else {
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

            if (noteToSelf != null) {
                Spacer(Modifier.height(12.dp))
                Row(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .clickable { onOpenNoteToSelf(noteToSelf) }
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        Icons.Default.Bookmark,
                        contentDescription = null,
                        tint = VoiidColor.textSecondary,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        "Open Note to Self",
                        style = VoiidFont.rounded(14, FontWeight.Medium),
                        color = VoiidColor.textSecondary,
                    )
                }
            }
        }
    }
}
