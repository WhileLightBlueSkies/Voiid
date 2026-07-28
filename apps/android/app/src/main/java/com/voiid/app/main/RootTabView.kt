package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.R
import com.voiid.app.model.AIStore
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

private enum class Tab(val asset: Int, val label: String) {
    AI(R.drawable.tab_ai, "AI"),
    CHAT(R.drawable.tab_chats, "Chats"),
    STORIES(R.drawable.tab_stories, "Stories"),   // right of Chats — chat-adjacent (replies land in chats)
    // Order MUST match iOS RootTabView.swift (AI · Chats · Stories · Map · Clips) so the two apps
    // feel like one product — Map sits between Stories and Clips, not tacked on after Clips.
    MAP(R.drawable.tab_map, "Map"),   // Feature (B) — the Map (docs/LOCATION.md §7)
    CLIPS(R.drawable.tab_clips, "Clips"),
}

/**
 * Main app surface — the custom bottom nav (AI · Chats · Clips) plus the overlays that cover it
 * (chat detail, clip fullscreen). Port of `RootTabView.swift` + iOS navigation behaviour.
 */
@Composable
fun MainScreen(chat: ChatStore, ai: AIStore, clips: ClipsStore, stories: com.voiid.app.model.StoriesStore) {
    var tab by remember { mutableStateOf(Tab.CHAT) }
    var openConversation by remember { mutableStateOf<VConversation?>(null) }
    var openClip by remember { mutableStateOf<VClip?>(null) }
    var showNewClip by remember { mutableStateOf(false) }
    // Stories viewer + composer are full-screen overlay siblings (they must cover the tab bar),
    // driven by nullable state exactly like the clip overlay above.
    var openStoryContext by remember { mutableStateOf<Int?>(null) }
    var showStoryComposer by remember { mutableStateOf(false) }

    // Feature (B) — the Map. Its store (allow-list, ghost state, subjects) is a ViewModel so
    // the Map surface can observe it the Compose way; the underlying engine is a singleton.
    val map: com.voiid.app.model.MapStore = androidx.lifecycle.viewmodel.compose.viewModel()
    // The Map tab icon carries a filled accent dot whenever you are VISIBLE — a persistent
    // indicator reachable from every screen (§8). Long-pressing the tab is the kill switch.
    val mapVisibility by map.visibility.collectAsState()

    // Real 1:1 WebRTC calls: init the engine once, observe live call state.
    val context = androidx.compose.ui.platform.LocalContext.current
    androidx.compose.runtime.LaunchedEffect(Unit) { com.voiid.app.net.CallManager.init(context) }
    val callState by com.voiid.app.net.CallManager.state.collectAsState()
    // Group calls run on the LiveKit SFU (GroupCallManager); 1:1 stays peer-to-peer.
    val groupCallState by com.voiid.app.net.GroupCallManager.state.collectAsState()
    // A tapped "join group call" notification → join the room.
    val pendingGroupCall by com.voiid.app.net.DeepLinkRouter.pendingGroupCall.collectAsState()
    androidx.compose.runtime.LaunchedEffect(pendingGroupCall) {
        pendingGroupCall?.let {
            com.voiid.app.net.GroupCallManager.join(
                context, it.conversationId, "Group call",
                if (it.video) CallKind.VIDEO else CallKind.VOICE,
            )
            com.voiid.app.net.DeepLinkRouter.consumeGroupCall()
        }
    }
    val startCall: (CallRequest) -> Unit = { req ->
        if (req.isGroup) {
            com.voiid.app.net.GroupCallManager.join(context, req.conversationId, req.title, req.kind)
        } else if (!req.peerUserId.isNullOrBlank()) {
            com.voiid.app.net.CallManager.startOutgoing(req.conversationId, req.peerUserId, req.title, req.kind)
        }
    }

    // Notification deep-link: when MainActivity publishes a conversation id, switch to the
    // Chats tab and open that conversation (resolving/reloading it from the server if needed).
    val pendingConversationId by com.voiid.app.net.DeepLinkRouter.pendingConversationId.collectAsState()
    androidx.compose.runtime.LaunchedEffect(pendingConversationId) {
        val cid = pendingConversationId ?: return@LaunchedEffect
        val conv = chat.conversationById(cid)
        if (conv != null) { tab = Tab.CHAT; openConversation = conv }
        com.voiid.app.net.DeepLinkRouter.consume()
    }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {

        Column(Modifier.fillMaxSize().imePadding()) {
            Box(Modifier.fillMaxWidth().weight(1f)) {
                when (tab) {
                    Tab.CHAT -> ChatsHomeView(chat, onOpenConversation = { openConversation = it }, onStartCall = startCall)
                    Tab.AI -> AIChatView(ai)
                    Tab.STORIES -> com.voiid.app.main.stories.StoriesHomeView(
                        stories,
                        onOpenContext = { openStoryContext = it },
                        onCompose = { showStoryComposer = true },
                    )
                    Tab.CLIPS -> ClipsFeedView(clips, onOpenClip = { openClip = it }, onNewClip = { showNewClip = true })
                    // "Open chat" on a map contact card jumps straight into that conversation,
                    // the same push the chat list performs.
                    Tab.MAP -> MapTabView(
                        map, chat,
                        onOpenChatWithUser = { uid ->
                            chat.directConversations.firstOrNull { it.peerUserId == uid }
                                ?.let { tab = Tab.CHAT; openConversation = it }
                        },
                    )
                }
            }
            TabBar(
                selected = tab,
                mapVisible = mapVisibility == com.voiid.app.model.MapVisibility.VISIBLE,
                storiesUnread = stories.hasUnread,
                onLongPressMap = { map.killSwitch() },
                onSelect = { tab = it },
            )
        }

        // Chat detail — slides in over everything (covers the tab bar), like the iOS push.
        AnimatedVisibility(
            visible = openConversation != null,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = slideOutHorizontally { it } + fadeOut(),
        ) {
            openConversation?.let { conv ->
                ChatDetailView(
                    conversation = conv, chat = chat,
                    onBack = { openConversation = null },
                    onStartCall = startCall,
                )
            }
        }

        // Clip fullscreen — full-screen cover.
        AnimatedVisibility(
            visible = openClip != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            openClip?.let { clip ->
                ClipFullscreenView(clip = clip, clips = clips, onClose = { openClip = null })
            }
        }

        // Story viewer — full-screen cover (must sit over the tab bar), matching openClip.
        AnimatedVisibility(
            visible = openStoryContext != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            openStoryContext?.let { start ->
                com.voiid.app.main.stories.StoryViewerView(
                    contexts = stories.contexts.toList(),
                    startContextIndex = start,
                    stories = stories,
                    onClose = { openStoryContext = null },
                )
            }
        }

        // Call surface — real WebRTC call, full-screen cover on top of everything.
        AnimatedVisibility(
            visible = callState != null,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            callState?.let { CallOverlay(it) }
        }

        // Group call surface — LiveKit SFU. Mutually exclusive with the 1:1 overlay above
        // (GroupCallManager/CallManager refuse to start while the other holds a call).
        AnimatedVisibility(
            visible = groupCallState != null,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            groupCallState?.let { GroupCallOverlay(it) }
        }
    }

    if (showNewClip) {
        NewClipSheet(onDismiss = { showNewClip = false })
    }
    if (showStoryComposer) {
        com.voiid.app.main.stories.StoryComposerSheet(stories = stories, onDismiss = { showStoryComposer = false })
    }
}

@Composable
private fun TabBar(
    selected: Tab,
    mapVisible: Boolean,
    storiesUnread: Boolean,
    onLongPressMap: () -> Unit,
    onSelect: (Tab) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(VoiidColor.background.copy(alpha = 0.98f))
            .navigationBarsPadding(),
    ) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        BoxWithConstraints(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 4.dp),
        ) {
            // Divide by the ACTUAL tab count — the Row below lays tabs out with weight(1f), so a
            // hardcoded /3 silently misaligns the sliding pill the moment a 4th tab (Map) exists.
            val slot = maxWidth / Tab.entries.size
            val pillW = 54.dp
            val activeIndex = selected.ordinal
            val leftTarget = slot * activeIndex + (slot - pillW) / 2
            val rightTarget = leftTarget + pillW

            // Direction of travel (computed before SideEffect updates the previous index).
            var prevIndex by remember { mutableStateOf(activeIndex) }
            val movingRight = activeIndex >= prevIndex
            SideEffect { prevIndex = activeIndex }

            // Elastic pill: the LEADING edge springs faster than the trailing edge, so
            // the pill STRETCHES in the direction of travel then snaps back — matching
            // the iOS matchedGeometry capsule (RootTabView.swift).
            val fast = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.7f, stiffness = Spring.StiffnessMedium)
            val slow = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.7f, stiffness = Spring.StiffnessLow)
            val leftX by animateDpAsState(leftTarget, if (movingRight) slow else fast, label = "tabPillLeft")
            val rightX by animateDpAsState(rightTarget, if (movingRight) fast else slow, label = "tabPillRight")
            Box(
                Modifier
                    .offset(x = leftX)
                    .size(width = (rightX - leftX).coerceAtLeast(pillW), height = 40.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(VoiidColor.accent.copy(alpha = 0.55f)),
            )
            Row(Modifier.fillMaxWidth()) {
                Tab.entries.forEach { t ->
                    TabItem(
                        t,
                        active = selected == t,
                        // Reuse the generic tab dot: accent when you're visible on the Map, or when
                        // any unexpired unviewed story exists (one home, one unread truth — no rail).
                        showVisibleDot = (t == Tab.MAP && mapVisible) || (t == Tab.STORIES && storiesUnread),
                        onLongPress = if (t == Tab.MAP) onLongPressMap else null,
                        modifier = Modifier.weight(1f),
                    ) { haptics.selection(); onSelect(t) }
                }
            }
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun TabItem(
    t: Tab,
    active: Boolean,
    showVisibleDot: Boolean,
    onLongPress: (() -> Unit)?,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val iconScale by animateFloatAsState(if (active) 1.12f else 1f, spring(dampingRatio = 0.55f), label = "tabIcon")
    Column(
        modifier = modifier.combinedClickable(
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            onClick = onClick,
            onLongClick = onLongPress,
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.height(40.dp), contentAlignment = Alignment.Center) {
            Image(
                painter = painterResource(t.asset),
                contentDescription = t.label,
                modifier = Modifier.size(24.dp).scale(iconScale),
                contentScale = ContentScale.Fit,
                colorFilter = ColorFilter.tint(if (active) VoiidColor.primary else VoiidColor.textSecondary),
            )
            // Persistent visibility indicator: a filled accent dot whenever you appear on the
            // Map. Visible from every screen, so being visible is never something you forget.
            if (showVisibleDot) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 4.dp, y = (-2).dp)
                        .size(9.dp)
                        .clip(androidx.compose.foundation.shape.CircleShape)
                        .background(VoiidColor.primary),
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        androidx.compose.material3.Text(
            t.label,
            style = VoiidFont.rounded(11, FontWeight.Medium),
            color = if (active) VoiidColor.primary else VoiidColor.textSecondary,
        )
    }
}
