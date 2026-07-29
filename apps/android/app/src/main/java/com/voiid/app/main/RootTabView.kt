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
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.PlayCircleOutline
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material3.Icon
import androidx.compose.ui.graphics.vector.ImageVector
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

/**
 * A bottom-nav destination.
 *
 * ADDING A TAB IS ONE LINE — a new entry here plus its screen in the `when` below. The bar
 * renders `Tab.entries`, so nothing in the layout needs touching.
 *
 * Icons are Material vector icons, OUTLINED when inactive and FILLED when selected. They
 * replaced bundled PNG drawables (tab_ai/chats/stories/map/clips), which is why the bar looked
 * unfinished: the PNGs were drawn at different detail levels, did not share a stroke weight,
 * and — being bitmaps — could not tint cleanly for dark mode. Order MUST match iOS
 * RootTabView.swift so the two apps feel like one product.
 */
private enum class Tab(
    val icon: ImageVector,
    val iconFilled: ImageVector,
    val label: String,
) {
    AI(Icons.Outlined.AutoAwesome, Icons.Filled.AutoAwesome, "AI"),
    CHAT(Icons.Outlined.ChatBubbleOutline, Icons.Filled.ChatBubble, "Chats"),
    STORIES(Icons.Outlined.Circle, Icons.Filled.Album, "Moments"),   // chat-adjacent: replies land in chats
    COMMUNITIES(Icons.Outlined.Groups, Icons.Filled.Groups, "Communities"),
    MAP(Icons.Outlined.Map, Icons.Filled.Map, "Map"),                // Feature (B) — docs/LOCATION.md §7
    GAMES(Icons.Outlined.SportsEsports, Icons.Filled.SportsEsports, "Games"),
    CLIPS(Icons.Outlined.PlayCircleOutline, Icons.Filled.PlayCircle, "Clips"),
}

/** Past this many tabs the bar drops labels and goes icon-only. Mirrors iOS `labelLimit`. */
private const val TAB_LABEL_LIMIT = 5

/**
 * Main app surface — the custom bottom nav (AI · Chats · Clips) plus the overlays that cover it
 * (chat detail, clip fullscreen). Port of `RootTabView.swift` + iOS navigation behaviour.
 */
@Composable
fun MainScreen(chat: ChatStore, ai: AIStore, clips: ClipsStore, stories: com.voiid.app.model.StoriesStore) {
    var tab by remember { mutableStateOf(Tab.CHAT) }
    var openConversation by remember { mutableStateOf<VConversation?>(null) }
    // The INDEX into the loaded feed page, not a clip: the fullscreen player is a pager
    // over the whole page, so it has to know where to start.
    var openClip by remember { mutableStateOf<Int?>(null) }
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
                    Tab.COMMUNITIES -> ComingSoonView(
                        icon = Icons.Outlined.Groups,
                        title = "Communities",
                        blurb = "Group spaces for the people, teams and interests you care about — announcements, sub-groups and shared media in one place.",
                    )
                    Tab.GAMES -> ComingSoonView(
                        icon = Icons.Outlined.SportsEsports,
                        title = "Games",
                        blurb = "Quick games you can start straight from a chat and play with anyone in your conversations.",
                    )
                    Tab.CHAT -> ChatsHomeView(chat, onOpenConversation = { openConversation = it }, onStartCall = startCall)
                    Tab.AI -> AIChatView(ai)
                    Tab.STORIES -> com.voiid.app.main.stories.StoriesHomeView(
                        stories,
                        onOpenContext = { openStoryContext = it },
                        onCompose = { showStoryComposer = true },
                    )
                    Tab.CLIPS -> com.voiid.app.main.clips.ClipsFeedView(
                        clips,
                        onOpenClip = { openClip = it },
                        onNewClip = { showNewClip = true },
                    )
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
            openClip?.let { index ->
                com.voiid.app.main.clips.ClipFullscreenView(
                    clips = clips,
                    startIndex = index,
                    myUserId = clips.myUserId,
                    myName = clips.myName,
                    onClose = { openClip = null },
                )
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
        com.voiid.app.main.clips.ClipComposerFlow(
            clips = clips,
            myUserId = clips.myUserId,
            myName = clips.myName,
            onClose = { showNewClip = false },
        )
    }
    if (showStoryComposer) {
        com.voiid.app.main.stories.StoryComposerSheet(stories = stories, onDismiss = { showStoryComposer = false })
    }
}

/**
 * The bottom nav.
 *
 * FIVE TABS FIT, THE REST SCROLL. With seven destinations a fixed `weight(1f)` row squeezed
 * every item to ~52dp, which is what made the bar feel cluttered and put the icons closer
 * together than a thumb can reliably separate. Each slot is now a FIXED fifth of the screen
 * and the row scrolls horizontally, so item size stays constant no matter how many tabs exist
 * — adding an eighth costs nothing but a scroll.
 *
 * The bar is also taller (64dp of content vs 46dp): a 48dp minimum touch target plus the
 * label needs the room, and the extra breathing space is most of what "cluttered" meant.
 */
@Composable
private fun TabBar(
    selected: Tab,
    mapVisible: Boolean,
    storiesUnread: Boolean,
    onLongPressMap: () -> Unit,
    onSelect: (Tab) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scroll = rememberScrollState()
    val density = LocalDensity.current

    Column(
        Modifier
            .fillMaxWidth()
            .background(VoiidColor.background.copy(alpha = 0.98f))
            .navigationBarsPadding(),
    ) {
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(VoiidColor.divider.copy(alpha = 0.6f)))

        BoxWithConstraints(Modifier.fillMaxWidth()) {
            // Exactly five slots visible; everything past that is reachable by scrolling.
            val slotW = maxWidth / VISIBLE_TABS

            // Keep the selected tab on screen — a tab chosen by a deep link (a notification
            // opening Chats, say) must not sit silently off the edge.
            LaunchedEffect(selected) {
                val target = with(density) { (slotW * selected.ordinal).toPx() }
                val centred = target - with(density) { (slotW * (VISIBLE_TABS - 1) / 2).toPx() }
                scroll.animateScrollTo(centred.toInt().coerceAtLeast(0))
            }

            Box(Modifier.horizontalScroll(scroll)) {
                Box(Modifier.width(slotW * Tab.entries.size)) {
                    // ELASTIC indicator — an underline, not a filled pill (the pill covered
                    // the glyph it was meant to highlight). The stretch is preserved: the
                    // LEADING edge springs faster than the trailing one, so the bar elongates
                    // in the direction of travel and snaps back. Damping is 0.82, up from the
                    // original 0.55 that overshot and wobbled on every tap.
                    //
                    // It lives INSIDE the scrolling content, so it tracks the row rather than
                    // detaching from its tab when the bar is scrolled.
                    val barW = 20.dp
                    val leftTarget = slotW * selected.ordinal + (slotW - barW) / 2
                    val rightTarget = leftTarget + barW

                    var prevIndex by remember { mutableStateOf(selected.ordinal) }
                    val movingRight = selected.ordinal >= prevIndex
                    SideEffect { prevIndex = selected.ordinal }

                    val fast = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.82f, stiffness = Spring.StiffnessMedium)
                    val slow = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.82f, stiffness = Spring.StiffnessLow)
                    val leftX by animateDpAsState(leftTarget, if (movingRight) slow else fast, label = "tabIndicatorL")
                    val rightX by animateDpAsState(rightTarget, if (movingRight) fast else slow, label = "tabIndicatorR")

                    Box(
                        Modifier
                            .offset(x = leftX, y = 56.dp)
                            .size(width = (rightX - leftX).coerceAtLeast(barW), height = 3.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .background(VoiidColor.primary),
                    )

                    Row {
                        Tab.entries.forEach { t ->
                            TabItem(
                                t,
                                active = selected == t,
                                // Labels always show now: a fixed slot is wide enough for
                                // them, which is the point of scrolling rather than squeezing.
                                showLabel = true,
                                // Reuse the generic dot: you are visible on the Map, or an
                                // unviewed story exists (one home, one unread truth).
                                showVisibleDot = (t == Tab.MAP && mapVisible) || (t == Tab.STORIES && storiesUnread),
                                onLongPress = if (t == Tab.MAP) onLongPressMap else null,
                                modifier = Modifier.width(slotW),
                            ) { haptics.selection(); onSelect(t) }
                        }
                    }
                }
            }
        }
    }
}

/** How many tabs are visible at once; the rest scroll. */
private const val VISIBLE_TABS = 5

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun TabItem(
    t: Tab,
    active: Boolean,
    showLabel: Boolean,
    showVisibleDot: Boolean,
    onLongPress: (() -> Unit)?,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Column(
        modifier = modifier
            .height(64.dp)   // 48dp min touch target + label + the indicator's 3dp track
            .combinedClickable(
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            onClick = onClick,
            onLongClick = onLongPress,
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.height(28.dp), contentAlignment = Alignment.Center) {
            // Outline → filled on selection, so the state reads without depending on colour
            // alone. No scale-pop: the old 1.12 spring made every tap wobble.
            Icon(
                imageVector = if (active) t.iconFilled else t.icon,
                contentDescription = t.label,
                modifier = Modifier.size(24.dp),
                tint = if (active) VoiidColor.primary else VoiidColor.textSecondary,
            )
            // Persistent indicator: you are visible on the Map, or an unviewed story exists.
            // SPARK, not the brand teal — teal is the "selected tab" colour, and using it here
            // read as a second, contradictory selection state.
            if (showVisibleDot) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 5.dp, y = (-2).dp)
                        .size(8.dp)
                        .clip(androidx.compose.foundation.shape.CircleShape)
                        .background(VoiidColor.accent),
                )
            }
        }
        if (showLabel) {
            Spacer(Modifier.height(5.dp))
            androidx.compose.material3.Text(
                t.label,
                // Weight steps up when active, so selection survives for a colour-blind user.
                style = VoiidFont.rounded(10, if (active) FontWeight.SemiBold else FontWeight.Medium),
                color = if (active) VoiidColor.primary else VoiidColor.textSecondary,
                maxLines = 1,
            )
        }
    }
}
