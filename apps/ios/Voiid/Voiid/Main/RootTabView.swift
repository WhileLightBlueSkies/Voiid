//
//  RootTabView.swift
//  Voiid
//
//  Main app shell — the custom bottom nav.
//
//  The bar renders `Tab.allCases`: adding a tab is one enum case plus one line in the body's
//  switch. Five tabs are visible at a time and the row scrolls horizontally past that, so
//  every item keeps a constant width however many destinations exist — growth costs a scroll
//  rather than squeezing the glyphs together.
//
//  Icons are SF Symbols throughout, outline when inactive and filled when selected. They
//  replaced four bundled PNGs mixed with one symbol — a combination that could never look
//  consistent, since the PNGs differed in detail level, were single-resolution, and did not
//  share the symbol's stroke weight or optical sizing.
//
//  The Map tab carries a persistent visibility indicator (§8): a filled accent dot whenever
//  you are visible on the Map, a hollow ghost glyph when ghosted. It is drawn from every
//  screen, active or not, so your standing visibility is never something you have to open a
//  screen to discover.
//

import SwiftUI

/// Carries the custom tab bar's measured height up to RootTabView, which republishes it on
/// `AppSession` for pages that place their own bottom chrome. Defaults to 0 so a tree with
/// no tab bar (a full-screen child) reports no reserved space.
/// Carries the tab row's live horizontal scroll offset out of the scroll view.
struct TabScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct TabBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RootTabView: View {
    @EnvironmentObject var session: AppSession
    // Drives the Map tab's always-on visibility badge. `MapVisibilityState` is the same
    // source the Map surface and Settings read, so the dot can never disagree with them.
    @ObservedObject private var mapVisibility = MapVisibilityState.shared
    // Drives the Stories tab's unread dot: any unexpired unviewed story exists. One home,
    // one truth — there is no story tray above the chat grid (§8.1).
    @ObservedObject private var storyEngine = StoryEngine.shared
    @State private var tab: Tab = .chat
    /// True while a swipe is driving the tab change, so the crossfade stands down and the
    /// swipe's own slide is the only motion on screen.
    @State private var swipingTabs = false
    /// Live drag offset, published by the swipe modifier so the carousel can move both
    /// pages together rather than the modifier offsetting one from outside.
    @State private var tabDrag: CGFloat = 0
    /// The tab a drag is heading for, or nil when no drag is in flight. Non-nil is what
    /// mounts the second page.
    @State private var draggingToward: Tab?
    @Namespace private var indicator
    /// True for the moment the indicator is travelling between tabs — drives its stretch.
    @State private var isSliding = false
    /// How far the indicator stretches on the current move — proportional to the number of
    /// tabs crossed, so a neighbouring hop and a jump across the bar do not look identical.
    @State private var slideStretch: CGFloat = 1.9
    /// How far the tab row is scrolled, in points, measured from the scroll view itself.
    @State private var scrollX: CGFloat = 0

    // The asset/label ternaries were hardcoded for exactly three cases; with a 4th tab they
    // become switches so a future 5th tab is a compile error to omit, not a silent wrong icon.
    enum Tab: CaseIterable { case ai, chat, stories, communities, map, games, clips

        /// SF Symbols, OUTLINE weight — the inactive state.
        ///
        /// These replace four bundled PNGs (tab-ai/chats/stories/clips) that were mixed with
        /// one SF Symbol for Map. That mix was the reason the bar looked unfinished: the PNGs
        /// were drawn at different detail levels (3.2 KB vs 640 B), shipped at a single
        /// resolution so they softened on a 3× screen, and could not match the symbol's stroke
        /// weight or optical sizing. One family fixes all of it at once, and vector glyphs also
        /// tint correctly in dark mode for free.
        var icon: String {
            switch self {
            case .ai:      return "sparkles"
            case .chat:    return "bubble.left.and.bubble.right"
            case .stories:     return "circle.dashed"
            case .communities: return "person.3"
            case .map:         return "map"
            case .games:       return "gamecontroller"
            case .clips:       return "play.rectangle"
            }
        }

        /// FILLED counterpart — the active state. Apple's own tab bars swap outline→filled
        /// rather than only recolouring, which is what makes selection read at a glance
        /// instead of relying on a colour difference alone.
        var iconFilled: String {
            switch self {
            case .ai:      return "sparkles"          // no filled variant; weight carries it
            case .chat:    return "bubble.left.and.bubble.right.fill"
            case .stories:     return "circle.circle.fill"
            case .communities: return "person.3.fill"
            case .map:         return "map.fill"
            case .games:       return "gamecontroller.fill"
            case .clips:       return "play.rectangle.fill"
            }
        }

        var label: String {
            switch self {
            case .ai:      return "AI"
            case .chat:    return "Chats"
            case .stories:     return "Moments"
            case .communities: return "Communities"
            case .map:         return "Map"
            case .games:       return "Games"
            case .clips:       return "Clips"
            }
        }
    }

    /// One tab's screen. Extracted from `body` so a NEIGHBOUR can be rendered during a
    /// swipe: previously only the selected tab existed, so dragging the page aside revealed
    /// the window behind it — the black flash.
    ///
    /// Construction is unchanged for every tab; the switch is the same one that was inline.
    /// The cost of building a neighbour is low because every tab defers its real work to
    /// `.onAppear`/`.task`, which SwiftUI fires when the view actually appears rather than
    /// when it is constructed.
    @ViewBuilder
    func page(_ t: Tab) -> some View {
        Group {

                switch t {
                case .chat:    ChatsHomeView()
                case .ai:      AIChatView()
                case .stories: StoriesHomeView()
                case .map:     MapTabView()
                case .clips:   ClipsFeedView()
                case .communities: CommunitiesHomeView()
                // THE PORTED REFERENCE, NOW WIRED. Games/Reference/GamesScreen is the
                // reference arcade tab's layout running on the REAL backend: GamesAPI for the
                // catalog and invites, TournamentService for tournaments, GamesEngine and
                // GameLobbyView for the match lifecycle. `GamesHomeView` is the implementation
                // it reuses and is now unreferenced — kept until someone decides to retire it.
                case .games:   GamesScreen()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Both the current tab and, DURING A SWIPE, the one being dragged toward are
            // rendered — see `page(_:)`.
            //
            // THE BLACK FLASH WAS A MISSING PAGE, NOT A TIMING BUG. Only the selected tab
            // existed, so sliding it aside uncovered the window itself. No easing fixes
            // that: something has to be there. The neighbour is mounted only while a drag
            // is in flight, so the steady state is exactly one tab as before.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    page(tab)
                        .offset(x: tabDrag)

                    // The tab being dragged TOWARD, parked exactly one screen away on the
                    // side it will arrive from, so the pair moves as one strip.
                    if let neighbour = draggingToward {
                        page(neighbour)
                            .offset(x: tabDrag + (tabDrag < 0 ? w : -w))
                    }
                }
                .frame(width: w, height: geo.size.height)
                // The pair is clipped to the screen so a neighbour parked off-side cannot
                // extend the layout or paint over the tab bar.
                .clipped()
            }
            // THE GEOMETRYREADER MUST NOT EAT THE SAFE AREA.
            //
            // Before the carousel, the page was a direct child of the ZStack and could draw
            // into the top inset — which is how the profile cover bled under the status bar
            // and every header sat where it was designed to. A GeometryReader honours the
            // safe area by default, so wrapping the page in one silently inset every tab
            // from the top and the designed headers vanished behind a blank strip.
            //
            // Ignoring it here restores the previous geometry exactly: the pages own the
            // full screen again, and each one applies its own insets as it always did.
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // THE BAR ANIMATED AND THE PAGE TELEPORTED.
            //
            // The indicator slides, stretches and settles; the glyph swaps its symbol variant
            // — and then the thing all of that points AT changed in a single frame. The one
            // element the user is actually looking at was the only one that did not move, so
            // the polish on the bar was pointing at nothing.
            //
            // A CROSSFADE, NOT A SLIDE, and that is a real decision rather than the easy one.
            // These tabs are scrollable and reorderable, so there is no stable left-of/
            // right-of between them: a slide would have to invent a direction, and it would
            // be wrong the moment the order changed or a deep link jumped two tabs. A
            // crossfade makes no spatial claim it cannot keep.
            //
            // 0.18s, which is deliberately short. This runs on every tab tap — the most
            // frequent transition in the app — and anything slower turns navigation into
            // waiting. Under Reduce Motion it stays: an opacity fade is not vestibular, and
            // removing it would put the hard cut back.
            // The crossfade owns TAPS only. A swipe already carries the page bodily across
            // the screen, and fading one page out while another slides in reads as two
            // events describing one gesture. `swipingTabs` is set by the swipe modifier for
            // the duration of its own transition.
            .transition(.opacity)
            .animation(swipingTabs ? nil : .easeInOut(duration: 0.18), value: tab)
            // Swipe the CONTENT to move one tab. The crossfade above still owns taps: a tap
            // can jump an arbitrary distance and a direction would have to be invented for
            // it, whereas a swipe moves exactly one step in the direction of the gesture.
            //
            // The "reorderable" half of the note above is not actually true — the bar renders
            // `Tab.allCases` in a fixed compile-time order and nothing permutes it — so a
            // stable left-of/right-of does exist for a one-step move.
            .tabSwipeNavigation(selection: $tab, ordered: Tab.allCases,
                                swiping: $swipingTabs,
                                drag: $tabDrag, toward: $draggingToward)

            if !session.hideTabBar {
                tabBar
                    // Publish the bar's REAL height so pages can hold their own bottom
                    // chrome clear of it. The bar is painted over the page (ZStack), not
                    // inserted into its safe area, so without this a bottom-anchored
                    // overlay renders underneath the bar. Measured, not hardcoded: the
                    // height varies with the home-indicator inset across devices.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: TabBarHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // When the bar is hidden the height collapses to 0 — a full-screen child must not
        // inherit a phantom gap. (No `tabBar` in the tree means no preference is emitted,
        // so the key falls back to its 0 default.)
        .onPreferenceChange(TabBarHeightKey.self) { h in
            session.tabBarHeight = h
        }
        .ignoresSafeArea(.keyboard)
        // Join tapped on a game-invite bubble, which lives in the Chats tab. Switch to Games
        // so the board (owned by that tab's stack) can present; GamesScreen handles the rest.
        // Ordering is safe either way — the notification is re-broadcast to whoever is
        // listening, and GamesScreen is alive as soon as the tab renders.
        .onReceive(NotificationCenter.default.publisher(for: .voiidOpenGameMatch)) { _ in
            tab = .games
        }
        // SELF-HEAL. `hideTabBar` is opt-out — every pushed screen sets it true and every root
        // tab is supposed to set it back — so one screen forgetting either half strands the
        // user with a missing bar, or leaks the bar into a chat. Switching tabs always lands
        // on a ROOT screen, so the bar must be visible by definition; forcing it here means a
        // forgotten reset costs one tab tap instead of an app restart.
        // A tab change always lands on a root screen, so every outstanding hide request is
        // stale by definition. Clearing the COUNT (rather than assigning a Bool false) is what
        // stops a screen that failed to release from stranding the user with no navigation.
        .onChange(of: tab) { _, _ in session.resetChrome() }
        .animation(.easeInOut(duration: 0.2), value: session.hideTabBar)
        // Bring the Map engine to life at shell load so inbound encrypted fixes are received
        // and decrypted even when the Map tab is not the active one — otherwise a contact's
        // live position would only start updating once you happened to open the Map.
        .onAppear { _ = MapPresenceEngine.shared }
    }

    /// The bar renders `Tab.allCases`, so ADDING A TAB IS ONE LINE — a new case in the enum
    /// with its two symbols and a label, plus its screen in the switch above.
    ///
    /// FIVE TABS FIT, THE REST SCROLL. With seven destinations an equal-width row squeezed
    /// every item to ~52pt, which is what made the bar feel cluttered and put the glyphs
    /// closer together than a thumb can reliably separate. Each slot is now a FIXED fifth of
    /// the screen and the row scrolls horizontally, so item size stays constant however many
    /// tabs exist — an eighth costs nothing but a scroll, and labels never have to be dropped.
    private var tabBar: some View {
        GeometryReader { geo in
            let slotW = geo.size.width / CGFloat(Self.visibleTabs)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Tab.allCases, id: \.self) { t in
                            tabItem(t)
                                .frame(width: slotW)
                                .id(t)
                        }
                    }
                    // The REAL scroll offset, not a model of it.
                    //
                    // An earlier attempt tracked the leftmost visible tab in an @State index
                    // that only its own scroll function ever wrote — so the moment the user
                    // dragged the bar by hand, that index was stale and the bar stopped
                    // auto-scrolling to reveal off-screen tabs at all. Measuring the content's
                    // position in the scroll view's own coordinate space cannot drift,
                    // because it IS the scroll position.
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: TabScrollOffsetKey.self,
                                value: -inner.frame(in: .named("tabScroll")).minX
                            )
                        }
                    )
                }
                .coordinateSpace(name: "tabScroll")
                .onPreferenceChange(TabScrollOffsetKey.self) { scrollX = $0 }
                // SCROLL ONLY WHEN THE TAB IS ACTUALLY OFF-SCREEN, and only to the nearer
                // edge.
                //
                // THE BUG: this re-CENTRED the selection on every change, so tapping a tab
                // that was already plainly visible yanked the whole bar sideways — the item
                // you just hit slid out from under your thumb, and its four neighbours moved
                // with it. With seven tabs in a five-wide window that fired on most taps.
                //
                // "Keep the selected tab on screen" (the original goal, and the right one)
                // does not require centring. A tab already visible needs NO scroll; one off
                // the edge should travel just far enough to appear. `anchor` picks WHICH edge
                // it lands against, so scrolling to `.leading` or `.trailing` moves the
                // minimum distance instead of hauling it to the middle.
                // SCROLL ONLY WHEN THE TAB IS GENUINELY OFF-SCREEN.
                //
                // This used to re-CENTRE on every selection, so tapping a tab that was
                // already plainly visible yanked the whole row sideways — the item you just
                // hit slid out from under your thumb and its neighbours moved with it. With
                // seven tabs in a five-wide window that fired on most taps.
                //
                // But "never scroll" is equally wrong: a tab beyond the visible five, or one
                // opened by a deep link, must still be brought into view. So the test is
                // against the LIVE scroll offset — visible tabs do not move the bar, and one
                // off the edge is centred, which is the gentlest place to put something the
                // user has not seen yet.
                .onChange(of: tab) { _, t in
                    guard tabIsOffScreen(t, slotW: slotW, viewport: geo.size.width) else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(t, anchor: .center)
                    }
                }
                // First appearance has no scroll history to preserve, and a deep-linked tab
                // past the fifth slot still has to be reachable. Unanimated: there is nothing
                // to show a transition FROM.
                .onAppear { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        // 48pt minimum touch target + label + the indicator's track. The old bar gave the
        // content 46pt total, and the extra breathing room is most of what "cluttered" meant.
        .frame(height: Self.barContentHeight)
        .padding(.bottom, VoiidSpacing.xs)
        // `.bar` material rather than a flat fill: content scrolling underneath blurs through
        // it, which is what makes an iOS tab bar feel native instead of pasted on.
        .background(.bar)
        .overlay(VoiidColor.divider.opacity(0.6).frame(height: 0.5), alignment: .top)
    }

    /// Whether `t` sits outside the visible window right now.
    ///
    /// A small tolerance, because a tab flush against the edge is technically visible and
    /// practically not — half of it is under the curve of the screen or the neighbouring
    /// slot's padding, and leaving it there reads as "the bar refused to move".
    private func tabIsOffScreen(_ t: Tab, slotW: CGFloat, viewport: CGFloat) -> Bool {
        guard let index = Tab.allCases.firstIndex(of: t) else { return false }
        let leading = CGFloat(index) * slotW
        let trailing = leading + slotW
        let tolerance: CGFloat = 8
        return leading < scrollX + tolerance || trailing > scrollX + viewport - tolerance
    }

    /// How many tabs are visible at once; the rest scroll.
    private static let visibleTabs = 5
    /// Height of the bar's content, above the home-indicator inset.
    private static let barContentHeight: CGFloat = 64

    private func tabItem(_ t: Tab) -> some View {
        let active = tab == t
        return Button {
            Haptics.selection()
            // Critically damped, not bouncy. The old spring (dampingFraction 0.55) overshot
            // and wobbled on every tap, and a 1.12 icon scale-pop rode on top of it — motion
            // that draws attention to the chrome instead of the content, and the single
            // biggest reason the bar read as amateur. 0.9 settles without oscillating.
            // Stretch while travelling, then release — the squash-and-stretch is applied to
            // the indicator's scale, not to its damping, so it reads as elastic without
            // oscillating to a stop.
            guard tab != t else { return }
            // THE STRETCH SCALES WITH THE DISTANCE TRAVELLED.
            //
            // It was a flat 1.9x for every move, so hopping to the adjacent tab stretched the
            // indicator exactly as far as jumping across the whole bar — the elasticity was
            // decoration rather than a consequence of the motion. Android derives its stretch
            // from the travel direction; this derives it from the travel DISTANCE, which is
            // the same idea applied to the axis SwiftUI gives us.
            //
            // Clamped at 2.2 so a seven-tab jump does not smear into a line.
            let order = Tab.allCases
            let from = order.firstIndex(of: tab) ?? 0
            let to = order.firstIndex(of: t) ?? 0
            let distance = abs(to - from)
            slideStretch = min(1.25 + CGFloat(distance) * 0.28, 2.2)
            isSliding = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { tab = t }
            // Release the stretch when the indicator has actually arrived, not on a fixed
            // timer: the spring's settle time depends on the distance, so a hardcoded 160ms
            // snapped the stretch back mid-flight on a long jump and left it hanging after a
            // short one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10 + Double(distance) * 0.02) {
                isSliding = false
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    // A slim underline, not a filled pill behind the glyph. The pill competed
                    // with the icon it was meant to highlight; an underline states the
                    // selection without obscuring anything, and it slides between tabs via the
                    // same matchedGeometryEffect.
                    if active {
                        Capsule()
                            .fill(VoiidColor.primary)
                            .matchedGeometryEffect(id: "tabIndicator", in: indicator)
                            // ELASTIC, kept from the original bar but tamed. The indicator
                            // stretches along its travel axis while moving and settles back to
                            // 1 — the squash-and-stretch that made the old pill feel alive,
                            // without the wobble that came from under-damping it.
                            .frame(width: 22, height: 3)
                            .scaleEffect(x: isSliding ? slideStretch : 1, y: 1, anchor: .center)
                            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSliding)
                            .offset(y: 17)
                    }
                    Image(systemName: active ? t.iconFilled : t.icon)
                        // A fixed point size with a symbol weight, NOT a resizable image in a
                        // frame: SF Symbols are optically sized, and stretching them to a box
                        // is what made the old icons look inconsistently heavy next to
                        // each other.
                        .font(.system(size: 22, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? VoiidColor.primary : VoiidColor.textSecondary)
                        // THE ICON ITSELF NOW MOVES. The indicator slid and the glyph hard-cut
                        // from outline to filled — so the one thing the thumb was aimed at was
                        // the only thing that did not respond, and the bar felt inert even
                        // though something on it was animating.
                        //
                        // A SMALL overshoot: 1.10, settling to 1.0, critically damped.
                        //
                        // An earlier version of this bar had a 1.12 pop on a 0.55-damped
                        // spring and it was removed for wobbling on every tap — motion that
                        // draws attention to the chrome instead of the content. That note is
                        // still in the comment above and it is right, so this stays under it:
                        // slightly smaller, and damped at 0.85 so it settles rather than
                        // oscillates. The reaction is felt, not watched.
                        .scaleEffect(active && isSliding ? 1.10 : 1)
                        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isSliding)
                        // The outline→filled swap is a DIFFERENT view, so SwiftUI cross-fades
                        // it rather than morphing. `.contentTransition` makes SF Symbols
                        // interpolate between the two variants instead — the fill grows out of
                        // the outline, which is what Apple's own tab bars do.
                        .contentTransition(.symbolEffect(.replace))
                        // The Map badge sits at the icon's top-right, drawn whether or not the
                        // tab is active — visibility must be legible from every screen.
                        .overlay(alignment: .topTrailing) {
                            if t == .map { mapVisibilityBadge.offset(x: 7, y: -3) }
                            // Stories unread dot: any unexpired unviewed story exists (§8.1).
                            // Spark, not the brand teal — an unread marker must not be the same
                            // colour as the "this tab is selected" state.
                            if t == .stories && storyEngine.hasUnviewed {
                                Circle().fill(VoiidColor.accent)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(VoiidColor.background, lineWidth: 1.5))
                                    .offset(x: 7, y: -3)
                            }
                        }
                }
                .frame(height: 28)
                // Labels always show now: a fixed slot is wide enough for them, which is the
                // point of scrolling rather than squeezing.
                Text(t.label)
                    // The active label steps up in weight rather than only in colour, so
                    // selection survives for a colour-blind user and in bright sunlight.
                    .font(VoiidFont.rounded(10, active ? .semibold : .medium))
                    .foregroundStyle(active ? VoiidColor.primary : VoiidColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        // PRESS RESPONSE, not just a post-hoc animation. `.plain` gives no feedback at all
        // on touch-down, so on a slow tap the bar did nothing until the finger lifted. This
        // dips the whole item the instant it is touched — the acknowledgement arrives with
        // the press rather than after it, which is most of what "feels interactive" means.
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(t.label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// Filled accent dot while visible; a hollow ghost glyph while ghosted (§8).
    @ViewBuilder
    private var mapVisibilityBadge: some View {
        if mapVisibility.isVisible {
            // SPARK, not the brand teal. Teal is the "this tab is selected" colour, so a teal
            // badge on the Map icon read as a second, contradictory selection state.
            Circle()
                .fill(VoiidColor.accent)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(VoiidColor.background, lineWidth: 1.5))
        } else {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(1.5)
                .background(Circle().fill(VoiidColor.background))
        }
    }
}

/// Touch-down feedback for a tab item.
///
/// Deliberately subtle: 0.92 and a fast spring. A tab bar is pressed constantly, so a large
/// or slow press animation stops reading as responsiveness and starts reading as lag.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
