package com.voiid.app.main

import androidx.compose.material3.Text
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.statusBars
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
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
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
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import com.voiid.app.main.walkthrough.LocalSpotlightRegistry
import com.voiid.app.main.walkthrough.SpotlightRegistry
import com.voiid.app.main.walkthrough.SpotlightShapeType
import com.voiid.app.main.walkthrough.spotlightTarget
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.foundation.border
import androidx.compose.ui.graphics.Color
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
import com.voiid.app.ui.components.voiidGlass
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * A bottom-nav destination.
 *
 * ADDING A TAB IS ONE LINE — a new entry here plus its screen in the `when` below. The bar
 * renders `Tab.visible`, so nothing in the layout needs touching. A tab left out of `visible`
 * is unreachable by every route.
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
    ;

    companion object {
        // Keep declaration before visible: companion properties initialize in order.
        private val SHIPPED = setOf(CHAT, STORIES, COMMUNITIES, GAMES, CLIPS)

        /**
         * The tabs the bar actually shows, and the order it steps through.
         *
         * `AI` is HIDDEN, matching iOS `Tab.visible` in RootTabView.swift. Its screen is not
         * wired to anything: `AIStore.send` waits 1.2s and appends a hardcoded reply, and no
         * AI route exists on the server. A tab that answers every question with the same
         * sentence is worse than an absent one — it advertises a feature that does not exist
         * and cannot be made to work by the user.
         *
         * Kept as an entry rather than deleted so `AIChatView` and `AIStore` still compile and
         * re-enabling it is one line, exactly as on iOS.
         *
         * Everything reads this instead of `entries`: the bar renders it, the indicator
         * measures it, and the default tab is `CHAT` — so a hidden tab cannot be reached by
         * any route.
         */
        val visible: List<Tab> = entries.filter { it in SHIPPED }

    }

    /**
     * This tab's position in the BAR, which is not its `ordinal` once a tab is hidden.
     *
     * The scroll-into-view maths and the indicator both place a tab at `slotWidth * index`.
     * Using `ordinal` there counts AI, so with AI hidden every tab would be measured one slot
     * to the right of where it is actually drawn — the indicator would sit under the wrong
     * label, and the last tab would scroll a slot past the end of the row.
     */
    val slot: Int get() = visible.indexOf(this).coerceAtLeast(0)
}

/** Past this many tabs the bar drops labels and goes icon-only. Mirrors iOS `labelLimit`. */
private const val TAB_LABEL_LIMIT = 5

/**
 * Main app surface — the custom bottom nav (Chats · Moments · Communities · Map · Games ·
 * Clips) plus the overlays that cover it (chat detail, clip fullscreen). Port of `RootTabView.swift` + iOS navigation behaviour.
 */
@Composable
fun MainScreen(session: com.voiid.app.model.AppSession, chat: ChatStore, ai: AIStore, clips: ClipsStore, stories: com.voiid.app.model.StoriesStore) {
    val storyLifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(storyLifecycleOwner, stories) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME && com.voiid.app.net.CallManager.state.value == null) stories.refresh()
        }
        storyLifecycleOwner.lifecycle.addObserver(observer)
        onDispose { storyLifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var tab by remember { mutableStateOf(Tab.CHAT) }
    val spotlightRegistry = remember { SpotlightRegistry() }
    val walkthrough = com.voiid.app.main.walkthrough.rememberAppWalkthroughState(session.userId)
    LaunchedEffect(walkthrough.currentIndex, walkthrough.presented) {
        if (!walkthrough.presented) {
            com.voiid.app.main.walkthrough.WalkthroughNavigationBus.setSettingsOpen(false)
            return@LaunchedEffect
        }
        val dest = walkthrough.step.destination
        if (dest == com.voiid.app.main.walkthrough.TourDestination.SETTINGS) {
            tab = Tab.CHAT
            com.voiid.app.main.walkthrough.WalkthroughNavigationBus.setSettingsOpen(true)
        } else {
            com.voiid.app.main.walkthrough.WalkthroughNavigationBus.setSettingsOpen(false)
            tab = when (dest) {
                com.voiid.app.main.walkthrough.TourDestination.CHATS -> Tab.CHAT
                com.voiid.app.main.walkthrough.TourDestination.MOMENTS -> Tab.STORIES
                com.voiid.app.main.walkthrough.TourDestination.COMMUNITIES -> Tab.COMMUNITIES
                com.voiid.app.main.walkthrough.TourDestination.GAMES -> Tab.GAMES
                else -> tab
            }
        }
    }
    // Read here rather than at the later `context`: that one is declared further down, and
    // the open-thread effect below runs before it exists.
    val notificationContext = androidx.compose.ui.platform.LocalContext.current
    var openConversation by remember { mutableStateOf<VConversation?>(null) }
    // Mirror the open thread into process-global state so VoiidMessagingService — a
    // background service that cannot read Compose — can skip notifying about a message the
    // user is already looking at. One source of truth: this effect follows every route that
    // opens or closes a thread, so no call site has to remember to update it.
    LaunchedEffect(openConversation?.id) {
        com.voiid.app.net.AppPresence.setOpenConversation(openConversation?.id)
        // Opening a thread answers every banner that was pointing at it, so they go now
        // rather than waiting for the next foreground transition — the user is already
        // reading the thing they were being notified about.
        openConversation?.id?.let {
            com.voiid.app.net.ChatEngine
                .get(notificationContext.applicationContext)
                .clearMessageNotifications(it)
        }
    }
    // WHICH grid was tapped and where in it. The fullscreen player is a pager over a list,
    // and there are three lists that can produce one (explore, following, a creator's page),
    // so a bare index would not say what it indexes.
    var openClip by remember {
        mutableStateOf<com.voiid.app.main.clips.ClipPagerSource?>(null)
    }
    var showNewClip by remember { mutableStateOf(false) }
    var showMyClips by remember { mutableStateOf(false) }
    // The creator-profile gate. `creators` is hoisted here rather than inside the Clips tab
    // so the handle sheet survives a tab switch mid-flow.
    val creators: com.voiid.app.model.CreatorStore =
        androidx.lifecycle.viewmodel.compose.viewModel()
    var showHandleSheet by remember { mutableStateOf(false) }
    /** The creator page open on top of the grid, by handle. */
    var openCreator by remember { mutableStateOf<String?>(null) }
    // Stories viewer + composer are full-screen overlay siblings (they must cover the tab bar),
    // driven by nullable state exactly like the clip overlay above.
    var openStoryContext by remember { mutableStateOf<Int?>(null) }
    var showStoryComposer by remember { mutableStateOf(false) }
    /** Snake's appearance picker. Snake-only, so it is not part of the shared setup sheet. */
    var showSkinPicker by remember { mutableStateOf(false) }
    // The open game match, as (matchId, slug). Full-screen overlay sibling of the clip/story
    // viewers — a board must cover the tab bar, or a mis-tap during a game switches tabs.
    //
    // The SLUG is carried alongside the id because it chooses the renderer. Holding only the
    // id is what made every online match draw a tic-tac-toe grid, RPS included.
    var openGameMatch by remember { mutableStateOf<Pair<String, String>?>(null) }
    // The game whose setup sheet is open ("who are you playing?"). A catalog card is a
    // GAME; nothing exists yet until an opponent is chosen.
    var setupGame by remember { mutableStateOf<com.voiid.app.net.GamesService.CatalogGame?>(null) }
    // The game awaiting a FRIEND. A match row only exists once the opponent is picked, so
    // this holds the gap between the two. The whole catalog row, not just the slug: the
    // invite message names the game ("Let's play Tic Tac Toe"), which needs the display name.
    var pendingGame by remember {
        mutableStateOf<com.voiid.app.net.GamesService.CatalogGame?>(null)
    }
    // The lobby the CREATOR waits in after sending an invite, until the opponent joins or the
    // invite expires. Holds what the lobby needs to describe itself without re-fetching.
    var lobby by remember { mutableStateOf<com.voiid.app.main.games.LobbyArgs?>(null) }
    // An online cricket match waiting on its over count: (slug, display name, (convoId, peer)).
    // Held because the length must be chosen BEFORE the match row exists — the server builds
    // the innings from it.
    // An online Snake match waiting on its bot count, for the same reason cricket waits on its
    // overs: the server populates the arena when the row is created, so it cannot be chosen
    // afterwards.
    var pendingDuel by remember {
        mutableStateOf<Triple<String, String, Pair<String, String>>?>(null)
    }
    var pendingCricket by remember {
        mutableStateOf<Triple<String, String, Pair<String, String>>?>(null)
    }
    // The offline practice board: which game, at what difficulty. Needs no match id because
    // a bot game never touches the server.
    var botGame by remember {
        mutableStateOf<Triple<String, com.voiid.app.main.games.BotDifficulty, Float>?>(null)
    }
    var showLeaderboard by remember { mutableStateOf(false) }
    /** Today's seeded Snake arena. Full-screen, same treatment as the leaderboard. */
    var showDaily by remember { mutableStateOf(false) }
    // Creating a match is a suspend call made from a click, so it needs a scope.
    val gamesScope = androidx.compose.runtime.rememberCoroutineScope()
    val appContext = androidx.compose.ui.platform.LocalContext.current.applicationContext

    /**
     * Opens the composer, or the handle picker first if this account has no creator profile.
     *
     * Checked HERE rather than at the end of the upload on purpose. `POST /clips` answers 428
     * only after the video is already in R2 — the composer exports a 480/720/1080 ladder and
     * PUTs every rung before the row is committed — so gating on the response would mean
     * asking for a handle after a 100 MB upload the user could still lose. Asking first costs
     * one cached GET. The 428 path remains as a backstop for the race.
     */
    fun startCompose() {
        gamesScope.launch {
            val profile = creators.ensureMeLoaded()
            // A failed lookup falls through to the composer rather than blocking: the server
            // still enforces the gate, and refusing to open on a network blip would be a
            // worse failure than the rare parked upload.
            if (profile == null && creators.hasLoadedMe) showHandleSheet = true
            else showNewClip = true
        }
    }

    // The store raises this when a commit came back `profile_required` — the backstop for an
    // upload that started before the profile went away.
    androidx.compose.runtime.LaunchedEffect(clips.needsCreatorProfile) {
        if (clips.needsCreatorProfile) {
            showHandleSheet = true
            clips.needsCreatorProfile = false
        }
    }

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

    // Join tapped on a game-invite bubble. Joining is authorized server-side (the caller
    // must be in player_ids), so this only has to open the board and let the opening
    // `game_state` frame populate it.
    val pendingGameMatch by com.voiid.app.net.DeepLinkRouter.pendingGameMatch.collectAsState()
    androidx.compose.runtime.LaunchedEffect(pendingGameMatch) {
        val tap = pendingGameMatch ?: return@LaunchedEffect
        com.voiid.app.net.GamesEngine.get(appContext).open(tap.matchId)
        openGameMatch = tap.matchId to tap.slug
        com.voiid.app.net.DeepLinkRouter.consumeGameMatch()
    }

    // Notification deep-link: when MainActivity publishes a conversation id, switch to the
    // Chats tab and open that conversation (resolving/reloading it from the server if needed).
    val pendingConversation by com.voiid.app.net.DeepLinkRouter.pendingConversation.collectAsState()
    androidx.compose.runtime.LaunchedEffect(pendingConversation, chat.directConversations.map { it.id }, chat.groupConversations.map { it.id }) {
        val destination = pendingConversation ?: return@LaunchedEffect
        val conv = chat.conversationById(destination.conversationId)
        if (com.voiid.app.net.DeepLinkRouter.pendingConversation.value != destination) return@LaunchedEffect
        if (conv != null) {
            tab = Tab.CHAT
            openStoryContext = null
            openConversation = conv
            com.voiid.app.net.DeepLinkRouter.consume(destination)
        }
    }

    val messageBanner by com.voiid.app.net.InAppMessageNotifications.current.collectAsState()
    androidx.compose.runtime.LaunchedEffect(messageBanner?.id) {
        val banner = messageBanner ?: return@LaunchedEffect
        kotlinx.coroutines.delay(6000)
        com.voiid.app.net.InAppMessageNotifications.dismiss(banner)
    }

    CompositionLocalProvider(
        LocalSpotlightRegistry provides spotlightRegistry,
        com.voiid.app.main.walkthrough.LocalWalkthroughState provides walkthrough,
    ) {
        Box(Modifier.fillMaxSize().background(VoiidColor.background)) {

        Column(Modifier.fillMaxSize().imePadding()) {
            Box(Modifier.fillMaxWidth().weight(1f)) {
                // TAB SWIPE NAVIGATION — port of iOS `TabSwipeNavigation.swift`.
                //
                // The original crossfade was correct about taps: tapping a distant tab jumps
                // an arbitrary distance and a slide would have to invent a direction. But a
                // SWIPE moves exactly one step, and the direction IS the gesture — not
                // invented. Two transitions for two different intentions, each honest about
                // what it is describing.
                //
                // The pager syncs bidirectionally with `tab`:
                //   • A tap on the TabBar sets `tab`, which scrolls the pager (animated).
                //   • A user swipe settles the pager, which updates `tab`.
                //
                // CONFLICT WITH INNER HORIZONTAL SCROLLS: HorizontalPager's nested scroll
                // connection correctly defers to inner horizontal ScrollViews (community
                // rails, highlight rails, filter rails) by default in Compose — the inner
                // scroll consumes horizontal delta first, and only overflow reaches the pager.
                // This is the Compose equivalent of iOS's UIPanGestureRecognizer delegate
                // that fails when the touch begins inside a scrollable.
                val pagerState = rememberPagerState(
                    initialPage = Tab.visible.indexOf(tab).coerceAtLeast(0),
                    pageCount = { Tab.visible.size },
                )

                // TAB → PAGER: a programmatic tab change (tap, deep link, walkthrough)
                // scrolls the pager to the new page.
                LaunchedEffect(tab) {
                    val targetPage = Tab.visible.indexOf(tab).coerceAtLeast(0)
                    if (pagerState.currentPage != targetPage) {
                        pagerState.animateScrollToPage(targetPage)
                    }
                }

                // PAGER → TAB: when the user swipes and the pager settles on a new page,
                // update the tab state. `settledPage` only changes when the pager is at
                // rest, so intermediate drag positions do not fire tab changes.
                LaunchedEffect(pagerState.settledPage) {
                    val settled = Tab.visible.getOrNull(pagerState.settledPage)
                    if (settled != null && settled != tab) {
                        tab = settled
                    }
                }

                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize(),
                    // beyondViewportPageCount keeps one neighbour alive so the swipe reveals
                    // content immediately rather than composing it mid-drag.
                    beyondViewportPageCount = 1,
                    key = { Tab.visible[it] },
                ) { page ->
                    val shownTab = Tab.visible[page]
                    when (shownTab) {
                        Tab.COMMUNITIES -> CommunitiesHomeView(
                            onOpenConversation = { conversationId ->
                                // Host-inbox taps land in the Chats tab like any other
                                // conversation — the inbox only ever hands back an id.
                                gamesScope.launch {
                                    chat.conversationById(conversationId)?.let {
                                        tab = Tab.CHAT; openConversation = it
                                    }
                                }
                            },
                        )
                        Tab.GAMES -> com.voiid.app.main.games.GamesHomeScreen(
                            onPickGame = { setupGame = it },
                            onLeaderboard = { showLeaderboard = true },
                            onDaily = { showDaily = true },
                            onAcceptInvite = { inv ->
                                // Accepting from a banner is the same act as tapping the invite bubble
                                // in chat, so it goes through the same seam.
                                com.voiid.app.net.DeepLinkRouter.openGameMatch(inv.match_id, inv.slug)
                            },
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
                            creators = creators,
                            onOpenClip = {
                                openClip = com.voiid.app.main.clips.ClipPagerSource.Explore(it)
                            },
                            onOpenFollowingClip = {
                                openClip = com.voiid.app.main.clips.ClipPagerSource.Following(it)
                            },
                            onNewClip = { startCompose() },
                            onMyClips = { showMyClips = true },
                            onOpenCreator = { openCreator = it },
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
            }
            TabBar(
                selected = tab,
                mapVisible = mapVisibility == com.voiid.app.model.MapVisibility.VISIBLE,
                // Ghosted shows a PERSISTENT hollow badge on the Map tab — the state must
                // never disappear from view just because the dot's condition ended.
                mapGhosted = mapVisibility == com.voiid.app.model.MapVisibility.GHOST,
                storiesUnread = stories.hasUnread,
                onLongPressMap = { map.killSwitch() },
                onSelect = { tab = it },
            )
        }

        if (walkthrough.presented && walkthrough.step.destination != com.voiid.app.main.walkthrough.TourDestination.SETTINGS) {
            com.voiid.app.main.walkthrough.AppWalkthroughOverlay(walkthrough)
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

        // Creator page — full-screen cover; it must clear the tab bar.
        //
        // ORDER MATTERS: this sits BELOW the clip player that follows it, because a tile on
        // a creator's page now opens that player. Drawn after it, the profile would cover
        // the very clip it was asked to play.
        openCreator?.let { handle ->
            com.voiid.app.main.clips.CreatorProfileView(
                handle = handle,
                creators = creators,
                onBack = { openCreator = null },
                onOpenClip = {
                    openClip = com.voiid.app.main.clips.ClipPagerSource.Creator(handle, it)
                },
            )
        }

        // Clip fullscreen — full-screen cover.
        //
        // It ZOOMS out of the thumbnail that was tapped rather than sliding up from the bottom
        // edge like every other overlay here. The tile and the player are the same clip, and a
        // slide from an unrelated edge read as "some other screen has appeared". The origin is
        // recorded by the tile itself — three different grids can open this.
        val clipZoom = com.voiid.app.main.clips.ClipZoomOrigin.value
        AnimatedVisibility(
            visible = openClip != null,
            enter = scaleIn(tween(240), initialScale = 0.4f, transformOrigin = clipZoom) +
                fadeIn(tween(140)),
            exit = scaleOut(tween(200), targetScale = 0.4f, transformOrigin = clipZoom) +
                fadeOut(tween(200)),
        ) {
            openClip?.let { source ->
                com.voiid.app.main.clips.ClipPagerHost(
                    source = source,
                    clips = clips,
                    creators = creators,
                    onOpenCreator = { openCreator = it },
                    onClose = { openClip = null },
                )
            }
        }

        // Opponent picker. A catalog row picks a GAME; the match is created once an
        // opponent is chosen, which is what turns a slug into the match id the board needs.
        pendingGame?.let { game ->
            // MORE THAN TWO SEATS GETS THE MULTI-SELECT PICKER (README §2.4). Keyed on the
            // CATALOG ROW rather than a list of slugs: the row is already the authority on how
            // many seats a game takes, and a second copy here is how the two disagree after the
            // next game ships.
            if (game.max_players > 2) {
                com.voiid.app.main.games.SeatPickerSheet(
                    conversations = chat.directConversations.toList(),
                    maxOpponents = game.max_players - 1,
                    minOpponents = maxOf(1, game.min_players - 1),
                    onDismiss = { pendingGame = null },
                    onConfirm = { convos ->
                        pendingGame = null
                        val opponents = convos.mapNotNull { c ->
                            c.peerUserId?.takeIf { it.isNotBlank() }?.let { it to c.id }
                        }
                        if (opponents.isNotEmpty()) {
                            // §10: the FIRST ludo create shows the seven-step walkthrough once;
                            // experienced players proceed without a pause.
                            if (game.slug == "ludo" &&
                                !com.voiid.app.net.GamesEngine.get(appContext)
                                    .ludoWalkthroughSeen(appContext)
                            ) {
                                com.voiid.app.net.GamesEngine.get(appContext)
                                    .markLudoWalkthroughSeen(appContext)
                            }
                            gamesScope.launch {
                                com.voiid.app.net.GamesEngine.get(appContext)
                                    .createMulti(game.slug, opponents, game.name)
                                    ?.let {
                                        lobby = com.voiid.app.main.games.LobbyArgs(
                                            matchId = it,
                                            slug = game.slug,
                                            gameName = game.name,
                                            // Every name, not just the first: "waiting for Priya"
                                            // when three were invited misleads about who is missing.
                                            opponentName = convos.joinToString(", ") { c -> c.title },
                                            detailLine = "${opponents.size + 1} players",
                                            seatCount = opponents.size + 1,
                                        )
                                    }
                            }
                        }
                    },
                )
                return@let
            }
            com.voiid.app.main.games.OpponentPickerSheet(
                conversations = chat.directConversations.toList(),
                onPick = { convo ->
                    pendingGame = null
                    android.util.Log.i(
                        "GamesInvite",
                        "picked convo=${convo.id} title=${convo.title} peer=${convo.peerUserId}",
                    )
                    // NOTE the label: this returns from `onPick`, not from the composable. Written
                    // as `return@OpponentPickerSheet` it returned from the wrong scope and silently
                    // did nothing at all — no invite, no lobby, no error — which is exactly what
                    // "the invite doesn't work" looked like from outside.
                    val peer = convo.peerUserId
                    if (peer.isNullOrBlank()) {
                        android.util.Log.e("GamesInvite", "no peerUserId on ${convo.id}; cannot invite")
                        return@OpponentPickerSheet
                    }
                    // Hand cricket needs its match length before the row is minted (the
                    // server builds the innings from it), so it takes one more step. Every
                    // other game has nothing left to ask.
                    if (game.slug == "cricket") {
                        pendingCricket = Triple(game.slug, game.name, convo.id to peer)
                    } else if (game.slug == "snake") {
                        pendingDuel = Triple(game.slug, game.name, convo.id to peer)
                    } else {
                        gamesScope.launch {
                            // Creating the match SENDS THE INVITE into this conversation. The
                            // creator then WAITS IN THE LOBBY — opening the board here is what made
                            // it look like nothing happened: no opponent means no opening frame, so
                            // the board sat on "Setting up…" forever.
                            com.voiid.app.net.GamesEngine.get(appContext)
                                .create(game.slug, peer, convo.id, game.name)
                                ?.let {
                                    lobby = com.voiid.app.main.games.LobbyArgs(
                                        matchId = it,
                                        slug = game.slug,
                                        gameName = game.name,
                                        opponentName = convo.title,
                                        detailLine = if (game.slug == "rps") "first to 3" else "",
                                    )
                                }
                        }
                    }
                },
                onDismiss = { pendingGame = null },
            )
        }

        // How busy the arena is, for an online Snake match. Zero bots is a duel, which is what a
        // friend match silently was before it was ever a choice.
        pendingDuel?.let { (slug, name, who) ->
            val (convoId, peer) = who
            com.voiid.app.main.games.DuelSheet(
                onPick = { bots ->
                    pendingDuel = null
                    gamesScope.launch {
                        val choice = com.voiid.app.main.games.SnakeChoiceStore(appContext)
                        com.voiid.app.net.GamesEngine.get(appContext)
                            .create(
                                slug, peer, convoId, name,
                                mapOf("bots" to bots) + choice.matchOptions(),
                                // A friend match sent NO skin until duels — so a player who had
                                // picked one got the default snake in the only mode anybody
                                // else could see it.
                                choice.skinId,
                            )
                            ?.let {
                                lobby = com.voiid.app.main.games.LobbyArgs(
                                    matchId = it,
                                    slug = slug,
                                    gameName = name,
                                    opponentName = chat.directConversations
                                        .firstOrNull { c -> c.id == convoId }?.title ?: "them",
                                    // Names the choice back to the creator while they wait, so
                                    // the lobby confirms what they picked rather than leaving
                                    // them to find out when the arena opens.
                                    detailLine = if (bots == 0) "duel — no bots" else "$bots bots",
                                )
                            }
                    }
                },
                onDismiss = { pendingDuel = null },
            )
        }

        // Match length for an online hand cricket game. Chosen by the CREATOR and then fixed
        // for both players, because it is a property of the match, not of a player.
        pendingCricket?.let { (slug, name, who) ->
            val (convoId, peer) = who
            com.voiid.app.main.games.OversSheet(
                onPick = { overs ->
                    pendingCricket = null
                    gamesScope.launch {
                        com.voiid.app.net.GamesEngine.get(appContext)
                            .create(slug, peer, convoId, name, mapOf("overs" to overs))
                            ?.let {
                                lobby = com.voiid.app.main.games.LobbyArgs(
                                    matchId = it,
                                    slug = slug,
                                    gameName = name,
                                    opponentName = chat.directConversations
                                        .firstOrNull { c -> c.id == convoId }?.title ?: "them",
                                    detailLine = "$overs ${if (overs == 1) "over" else "overs"}",
                                )
                            }
                    }
                },
                onDismiss = { pendingCricket = null },
            )
        }

        // Today's daily challenge — full-screen, same treatment as the leaderboard.
        AnimatedVisibility(
            visible = showDaily,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.voiid.app.main.games.DailyChallengeScreen(
                onPlay = { id ->
                    // Leave the daily screen behind: coming back from the arena should land on
                    // the games tab, not on a board showing a run that is now over.
                    showDaily = false
                    openGameMatch = id to "snake"
                },
                onClose = { showDaily = false },
            )
        }

        // Leaderboard — full-screen cover, same treatment as the boards.
        AnimatedVisibility(
            visible = showLeaderboard,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.voiid.app.main.games.LeaderboardScreen(onClose = { showLeaderboard = false })
        }

        // "Who are you playing?" — one entry point per game, opponent chosen second.
        setupGame?.let { game ->
            com.voiid.app.main.games.GameSetupSheet(
                gameName = game.name,
                slug = game.slug,
                onPlayFriend = {
                    setupGame = null
                    pendingGame = game
                },
                // NULL FOR A GAME WITH NO BOT. The bot destination below switches on slug and
                // falls through to Tic Tac Toe, so a game without a case does not merely show a
                // dead button — it opens a DIFFERENT GAME. Sea Battle and Ludo are exactly that
                // today: engines and renderers, no client-side bot yet.
                //
                // AN ALLOWLIST, NOT A DENYLIST, and it must stay in step with that switch.
                // The same six slugs iOS offers (GamesHomeView.hasLocalBot). Sea Battle and Ludo
                // were missing here, so both games were online-only on Android — unplayable
                // without a friend already online. Every slug in this list MUST have a branch in
                // the practice router below.
                onPlayBot = if (game.slug !in
                    listOf("tictactoe", "rps", "cricket", "snake", "seabattle", "ludo")
                ) null
                else { level, skill ->
                    setupGame = null
                    if (game.slug == "snake") {
                        // Snake's bots live on the SERVER, so "play a bot" mints a real
                        // one-seat match rather than opening a local simulation. Every other
                        // game here is turn-based and simulates its opponent on-device.
                        gamesScope.launch {
                            // Difficulty maps to how many bots share the arena. Bots use
                            // identical physics to the player — no speed or turning advantage
                            // — so a busier arena IS the difficulty: less open space, more
                            // bodies to cut across.
                            val bots = when (level) {
                                com.voiid.app.main.games.BotDifficulty.EASY -> 4
                                com.voiid.app.main.games.BotDifficulty.MODERATE -> 8
                                com.voiid.app.main.games.BotDifficulty.HARD -> 14
                            }
                            val engine = com.voiid.app.net.GamesEngine.get(context)
                            val matchId = engine.createSolo(game.slug, mapOf("bots" to bots))
                            matchId
                                ?.let { openGameMatch = it to game.slug }
                        }
                    } else {
                        botGame = Triple(game.slug, level, skill)
                    }
                },
                onCustomise =
                    if (game.slug == "snake") {
                        { setupGame = null; showSkinPicker = true }
                    } else null,
                onDismiss = { setupGame = null },
            )
        }

        AnimatedVisibility(
            visible = showSkinPicker,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(VoiidColor.background)
                    .navigationBarsPadding(),
            ) {
                com.voiid.app.main.games.SnakeSkinPicker { showSkinPicker = false }
            }
        }

        // Practice board — full-screen cover, same treatment as the online board. Which
        // renderer runs is chosen by slug, the same key the server's rules modules use.
        AnimatedVisibility(
            visible = botGame != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            botGame?.let { (slug, level, skill) ->
                // EVERY SLUG IS NAMED, and the fallback is Tic Tac Toe ONLY for the slug that
                // actually is Tic Tac Toe. This used to be a bare `else ->` catch-all, which
                // meant the day a slug was added to the allow-list above without a branch here,
                // tapping Practice on that game silently opened a different game — a failure
                // that looks like a working screen. An unknown slug now closes instead.
                when (slug) {
                    "rps" -> com.voiid.app.main.games.RpsBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
                    "cricket" -> com.voiid.app.main.games.CricketBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
                    "seabattle" -> com.voiid.app.main.games.SeaBattleBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
                    "tictactoe" -> com.voiid.app.main.games.TicTacToeBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
                    // Offline, local rules — no server round trip for a game played against
                    // bots on this device. Online Ludo returns after a stable release.
                    "ludo" -> com.voiid.app.main.games.ludobot.LudoBotScreen(
                        difficulty = when (level) {
                            com.voiid.app.main.games.BotDifficulty.EASY -> "easy"
                            com.voiid.app.main.games.BotDifficulty.MODERATE -> "moderate"
                            com.voiid.app.main.games.BotDifficulty.HARD -> "hard"
                        },
                        onClose = { botGame = null },
                    )
                    else -> LaunchedEffect(slug) { botGame = null }
                }
            }
        }

        // Lobby — full-screen cover. Sits between "invite sent" and the board: it hands off to the
        // board the moment the opponent's join produces an opening frame.
        AnimatedVisibility(
            visible = lobby != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            lobby?.let { args ->
                com.voiid.app.main.games.GameLobbyScreen(
                    matchId = args.matchId,
                    slug = args.slug,
                    gameName = args.gameName,
                    opponentName = args.opponentName,
                    detailLine = args.detailLine,
                    seatCount = args.seatCount,
                    onStart = {
                        openGameMatch = args.matchId to args.slug
                        lobby = null
                    },
                    onClose = { lobby = null },
                )
            }
        }

        // Game board — full-screen cover (must sit over the tab bar), matching openClip.
        AnimatedVisibility(
            visible = openGameMatch != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            openGameMatch?.let { (matchId, slug) ->
                // Renderer per game, keyed by the same slug the server's rules modules use.
                when (slug) {
                    // ONE HANDLER SHAPE FOR EVERY REMATCH. The server has already minted the
                    // new match by the time this runs, so opening it is ordinary navigation —
                    // reassigning `openGameMatch` swaps the destination in place rather than
                    // stacking a second board on top of the finished one.
                    "rps" -> com.voiid.app.main.games.RpsMatchScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                        onRematch = { openGameMatch = it to "rps" },
                    )
                    "cricket" -> com.voiid.app.main.games.CricketMatchScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                        onRematch = { openGameMatch = it to "cricket" },
                    )
                    "seabattle" -> com.voiid.app.main.games.SeaBattleScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                        onRematch = { openGameMatch = it to "seabattle" },
                    )
                    "ludo" -> com.voiid.app.main.games.ludo.LudoScreen(
                        matchId = matchId,
                        conversationId = null,   // deep link: chat sheet hidden until opened from chat
                        onClose = { openGameMatch = null },
                        onRematch = { openGameMatch = it to "ludo" },
                    )
                    "snake" -> com.voiid.app.main.games.SnakeArenaScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                        onRestart = {
                            // A fresh match rather than reusing the finished one: the server
                            // drops a match's state when it ends, so there is nothing to
                            // rejoin.
                            gamesScope.launch {
                                val choice = com.voiid.app.main.games
                                    .SnakeChoiceStore(context)
                                com.voiid.app.net.GamesEngine.get(context)
                                    .createSolo(
                                        "snake",
                                        mapOf("bots" to 5) + choice.matchOptions(),
                                        choice.skinId)
                                    ?.let { openGameMatch = it to "snake" }
                            }
                        },
                    )
                    else -> com.voiid.app.main.games.TicTacToeScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                        onRematch = { openGameMatch = it to "tictactoe" },
                    )
                }
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

        val bannerQueue by com.voiid.app.net.InAppMessageNotifications.banners.collectAsState()
        var retainedBanner by remember { mutableStateOf(messageBanner) }
        androidx.compose.runtime.LaunchedEffect(messageBanner) { if (messageBanner != null) retainedBanner = messageBanner }
        AnimatedVisibility(
            visible = messageBanner != null,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = with(androidx.compose.ui.platform.LocalDensity.current) {
                androidx.compose.foundation.layout.WindowInsets.statusBars.getTop(this).toDp()
            }).padding(horizontal = 24.dp),
            enter = slideInVertically(tween(250, easing = androidx.compose.animation.core.CubicBezierEasing(0.23f, 1f, 0.32f, 1f))) { -it / 3 } + fadeIn(tween(150)) + scaleIn(tween(250), initialScale = 0.97f),
            exit = slideOutVertically(tween(150)) { -it / 3 } + fadeOut(tween(150)),
        ) {
            (messageBanner ?: retainedBanner)?.let { banner ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    androidx.compose.material3.Surface(
                        onClick = {
                            com.voiid.app.net.InAppMessageNotifications.dismiss(banner)
                            if (banner.communityHandle != null) {
                                com.voiid.app.net.DeepLinkRouter.openCommunityInvite(com.voiid.app.net.CommunityLink(banner.communityHandle, null))
                            } else com.voiid.app.net.DeepLinkRouter.open(banner.conversationId, banner.messageId)
                        },
                        shape = RoundedCornerShape(50), color = VoiidColor.surfaceCard.copy(alpha = 0.97f),
                        border = androidx.compose.foundation.BorderStroke(0.5.dp, VoiidColor.divider), shadowElevation = 8.dp,
                    ) {
                        Row(Modifier.padding(start = 13.dp, top = 13.dp, bottom = 13.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Box(Modifier.size(34.dp).background(VoiidColor.primary, androidx.compose.foundation.shape.CircleShape),
                                contentAlignment = Alignment.Center) {
                                Text(banner.title.split(" ").filter { it.isNotEmpty() }.take(2).map { it.first() }.joinToString(""),
                                    style = VoiidFont.rounded(12, FontWeight.Bold), color = androidx.compose.ui.graphics.Color.White)
                            }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(banner.title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1)
                                Text(if (banner.count > 1) "${banner.count} messages · ${banner.body}" else banner.body,
                                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, maxLines = 2)
                            }
                            androidx.compose.material3.IconButton(onClick = { com.voiid.app.net.InAppMessageNotifications.dismiss(banner) }) {
                                Text("×", color = VoiidColor.textSecondary,
                                    modifier = Modifier.semantics { contentDescription = "Dismiss notification" })
                            }
                        }
                    }
                    if (bannerQueue.size > 1) {
                        Text("+${bannerQueue.size - 1} more chats", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary,
                            modifier = Modifier.background(VoiidColor.surfaceCard, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 5.dp))
                    }
                }
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
    if (showHandleSheet) {
        com.voiid.app.main.clips.CreatorHandleSheet(
            creators = creators,
            onCreated = {
                // Whatever raised the gate can now proceed: either finish an upload parked at
                // the commit step, or open the composer that was blocked.
                if (clips.hasPendingCommits) clips.retryPendingCommits() else showNewClip = true
            },
            onDismiss = { showHandleSheet = false },
        )
    }
    if (showMyClips) {
        com.voiid.app.main.clips.MyClipsView(
            clips = clips,
            onBack = { showMyClips = false },
        )
    }
    if (showStoryComposer) {
        com.voiid.app.main.stories.StoryComposerSheet(stories = stories, onDismiss = { showStoryComposer = false })
    }
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
    mapGhosted: Boolean,
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
            // iOS native `.bar` material glass blur feel with specular rim highlight
            .voiidGlass(
                shape = RoundedCornerShape(0.dp),
                tint = VoiidColor.background.copy(alpha = 0.82f),
                specularBorderWidth = 0.5.dp,
                blurRadius = 24f,
            )
            .navigationBarsPadding(),
    ) {
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(VoiidColor.divider.copy(alpha = 0.6f)))

        BoxWithConstraints(Modifier.fillMaxWidth()) {
            // Exactly five slots visible; everything past that is reachable by scrolling.
            val slotW = maxWidth / VISIBLE_TABS

            // SCROLL ONLY WHEN THE TAB IS ACTUALLY OFF-SCREEN, and only far enough.
            LaunchedEffect(selected) {
                val slotPx = with(density) { slotW.toPx() }
                val leading = slotPx * selected.slot
                val trailing = leading + slotPx
                val viewportPx = with(density) { maxWidth.toPx() }
                val visibleStart = scroll.value.toFloat()
                val visibleEnd = visibleStart + viewportPx

                val tolerance = with(density) { 8.dp.toPx() }
                val offScreen = leading < visibleStart + tolerance ||
                    trailing > visibleEnd - tolerance

                if (offScreen) {
                    val centred = leading - (viewportPx - slotPx) / 2f
                    scroll.animateScrollTo(centred.toInt().coerceAtLeast(0))
                }
            }

            Box(Modifier.horizontalScroll(scroll)) {
                Box(Modifier.width(slotW * Tab.visible.size)) {
                    // ELASTIC indicator — stretch scales with distance travelled, matching iOS slideStretch formula
                    val barW = 22.dp
                    var prevIndex by remember { mutableStateOf(selected.slot) }
                    val distance = kotlin.math.abs(selected.slot - prevIndex).coerceAtLeast(1)
                    val movingRight = selected.slot >= prevIndex
                    SideEffect { prevIndex = selected.slot }

                    val stretchFactor = (1f + (distance - 1) * 0.32f).coerceAtMost(2.2f)
                    val targetW = barW * stretchFactor
                    val leftTarget = slotW * selected.slot + (slotW - barW) / 2
                    val rightTarget = leftTarget + targetW

                    val fast = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.85f, stiffness = Spring.StiffnessMedium)
                    val slow = spring<androidx.compose.ui.unit.Dp>(dampingRatio = 0.85f, stiffness = Spring.StiffnessLow)
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
                        Tab.visible.forEach { t ->
                            val spotlightId = when (t) {
                                Tab.CHAT -> "nav_tab_chats"
                                Tab.STORIES -> "nav_tab_moments"
                                Tab.COMMUNITIES -> "nav_tab_communities"
                                Tab.GAMES -> "nav_tab_games"
                                else -> null
                            }
                            val tabModifier = if (spotlightId != null) {
                                Modifier
                                    .width(slotW)
                                    .spotlightTarget(
                                        id = spotlightId,
                                        shape = SpotlightShapeType.CIRCLE,
                                        padding = 8.dp,
                                        interactive = true,
                                    )
                            } else {
                                Modifier.width(slotW)
                            }
                            TabItem(
                                t,
                                active = selected == t,
                                // Labels always show now: a fixed slot is wide enough for
                                // them, which is the point of scrolling rather than squeezing.
                                showLabel = true,
                                showBadge = (t == Tab.MAP && mapVisible) ||
                                    (t == Tab.MAP && mapGhosted) ||
                                    (t == Tab.STORIES && storiesUnread),
                                badgeHollow = t == Tab.MAP && mapGhosted,
                                onLongPress = if (t == Tab.MAP) onLongPressMap else null,
                                modifier = tabModifier,
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

/**
 * The tab bar's translucent scrim over the content it covers. iOS uses a `.bar` material
 * blur, which specifies no number — this is a centralised, calibration-required constant,
 * NOT claimed numeric parity.
 */
private const val TAB_SURFACE_ALPHA = 0.86f

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun TabItem(
    t: Tab,
    active: Boolean,
    showLabel: Boolean,
    showBadge: Boolean,
    /** Hollow badge (ghosted state) instead of the filled dot. */
    badgeHollow: Boolean,
    onLongPress: (() -> Unit)?,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    // PRESS RESPONSE, on touch-down. `indication = null` gave no feedback at all until the
    // finger lifted, so on a slow tap the bar did nothing — the acknowledgement has to arrive
    // WITH the press, which is most of what "feels interactive" means. Deliberately subtle: a
    // tab bar is pressed constantly, and a large or slow press animation stops reading as
    // responsiveness and starts reading as lag.
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed) 0.92f else 1f,
        animationSpec = com.voiid.app.ui.components.VoiidMotion.tabPress,
        label = "tabPress",
    )

    // A SMALL overshoot when a tab BECOMES active — a transient 1.10 phase, then settle to
    // 1.0. iOS drives the glyph UP to 1.10 while the indicator is sliding and lets it land;
    // the previous Android code animated inactive icons DOWN to 0.94 and active to 1.0 with
    // no 1.10 phase at all, so the "pop" the comment promised never happened.
    val scale = remember { androidx.compose.animation.core.Animatable(0.94f) }
    LaunchedEffect(active) {
        if (active) {
            // Snap up, then settle — the landing reads as the tab accepting the tap.
            scale.snapTo(1.10f)
            scale.animateTo(1f, spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessMedium))
        } else {
            scale.animateTo(0.94f, spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessMedium))
        }
    }

    Column(
        modifier = modifier
            .height(64.dp)   // 48dp min touch target + label + the indicator's 3dp track
            .graphicsLayer { scaleX = pressScale; scaleY = pressScale }
            .combinedClickable(
            interactionSource = interaction,
            indication = null,
            onClick = onClick,
            onLongClick = onLongPress,
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.height(28.dp), contentAlignment = Alignment.Center) {
            // Outline → filled on selection, so the state reads without depending on colour
            // alone. The scale is the tamed version described above, not the old 1.12 wobble.
            // The outline→filled swap CROSSFADES rather than cutting. iOS gets this from
            // `.contentTransition(.symbolEffect(.replace))`, where the fill grows out of the
            // outline; Compose has no symbol interpolation, so a short crossfade is the
            // closest honest equivalent — and it is the difference between the glyph
            // "becoming" selected and being replaced by a different glyph.
            //
            // Short (120ms): this rides on top of the scale and the indicator, and a slow
            // fade here would leave a visible double-image of two icons at once.
            androidx.compose.animation.Crossfade(
                targetState = active,
                animationSpec = tween(120),
                label = "tabIcon",
            ) { isActive ->
                Icon(
                    imageVector = if (isActive) t.iconFilled else t.icon,
                    contentDescription = t.label,
                    modifier = Modifier
                        .size(22.dp)
                        .graphicsLayer { scaleX = scale.value; scaleY = scale.value },
                    tint = if (isActive) VoiidColor.primary else VoiidColor.textSecondary,
                )
            }
            // Persistent badge: filled dot when VISIBLE on the Map (or an unviewed story),
            // HOLLOW ring while ghosted — the ghost state must stay visible somewhere, and a
            // hollow badge is the iOS convention for "this is on, but suppressed".
            if (showBadge) {
                if (badgeHollow) {
                    Box(
                        Modifier
                            .align(Alignment.TopEnd)
                            .offset(x = 5.dp, y = (-2).dp)
                            .size(9.dp)
                            .clip(androidx.compose.foundation.shape.CircleShape)
                            .background(Color.Transparent)
                            .border(1.5.dp, VoiidColor.accent, androidx.compose.foundation.shape.CircleShape),
                    )
                } else {
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
