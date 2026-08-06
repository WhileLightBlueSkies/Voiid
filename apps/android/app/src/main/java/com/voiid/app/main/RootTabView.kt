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
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.runtime.Composable
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
    var pendingCricket by remember {
        mutableStateOf<Triple<String, String, Pair<String, String>>?>(null)
    }
    // The offline practice board: which game, at what difficulty. Needs no match id because
    // a bot game never touches the server.
    var botGame by remember {
        mutableStateOf<Triple<String, com.voiid.app.main.games.BotDifficulty, Float>?>(null)
    }
    var showLeaderboard by remember { mutableStateOf(false) }
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
                    Tab.GAMES -> com.voiid.app.main.games.GamesHomeScreen(
                        onPickGame = { setupGame = it },
                        onLeaderboard = { showLeaderboard = true },
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
        AnimatedVisibility(
            visible = openClip != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
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
                onPlayFriend = {
                    setupGame = null
                    pendingGame = game
                },
                onPlayBot = { level, skill ->
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
                                com.voiid.app.main.games.BotDifficulty.EASY -> 3
                                com.voiid.app.main.games.BotDifficulty.MODERATE -> 5
                                com.voiid.app.main.games.BotDifficulty.HARD -> 8
                            }
                            com.voiid.app.net.GamesEngine.get(context)
                                .createSolo(game.slug, mapOf("bots" to bots))
                                ?.let { openGameMatch = it to game.slug }
                        }
                    } else {
                        botGame = Triple(game.slug, level, skill)
                    }
                },
                onDismiss = { setupGame = null },
            )
        }

        // Practice board — full-screen cover, same treatment as the online board. Which
        // renderer runs is chosen by slug, the same key the server's rules modules use.
        AnimatedVisibility(
            visible = botGame != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            botGame?.let { (slug, level, skill) ->
                when (slug) {
                    "rps" -> com.voiid.app.main.games.RpsBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
                    "cricket" -> com.voiid.app.main.games.CricketBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
                    else -> com.voiid.app.main.games.TicTacToeBotScreen(
                        level = level, skill = skill, onClose = { botGame = null })
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
                    "rps" -> com.voiid.app.main.games.RpsMatchScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                    )
                    "cricket" -> com.voiid.app.main.games.CricketMatchScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                    )
                    "snake" -> com.voiid.app.main.games.SnakeArenaScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
                        onRestart = {
                            // A fresh match rather than reusing the finished one: the server
                            // drops a match's state when it ends, so there is nothing to
                            // rejoin.
                            gamesScope.launch {
                                com.voiid.app.net.GamesEngine.get(context)
                                    .createSolo("snake", mapOf("bots" to 5))
                                    ?.let { openGameMatch = it to "snake" }
                            }
                        },
                    )
                    else -> com.voiid.app.main.games.TicTacToeScreen(
                        matchId = matchId,
                        onClose = { openGameMatch = null },
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
    // PRESS RESPONSE, on touch-down. `indication = null` gave no feedback at all until the
    // finger lifted, so on a slow tap the bar did nothing — the acknowledgement has to arrive
    // WITH the press, which is most of what "feels interactive" means. Deliberately subtle: a
    // tab bar is pressed constantly, and a large or slow press animation stops reading as
    // responsiveness and starts reading as lag.
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed) 0.92f else 1f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow),
        label = "tabPress",
    )

    // A SMALL overshoot when a tab BECOMES active — 1.10, critically damped.
    //
    // An earlier version had a 1.12 pop that was removed for wobbling on every tap (the note
    // below is still right). This stays under it: damped at 0.85 so it settles rather than
    // oscillates, and driven off `active` so it fires on selection, not on every recomposition.
    val activeScale by animateFloatAsState(
        targetValue = if (active) 1f else 0.94f,
        animationSpec = spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessMedium),
        label = "tabActive",
    )

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
            Icon(
                imageVector = if (active) t.iconFilled else t.icon,
                contentDescription = t.label,
                modifier = Modifier
                    .size(24.dp)
                    .graphicsLayer { scaleX = activeScale; scaleY = activeScale },
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
