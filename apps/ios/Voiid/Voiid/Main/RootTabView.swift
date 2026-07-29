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
    @Namespace private var indicator
    /// True for the moment the indicator is travelling between tabs — drives its stretch.
    @State private var isSliding = false

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

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .chat:    ChatsHomeView()
                case .ai:      AIChatView()
                case .stories: StoriesHomeView()
                case .map:     MapTabView()
                case .clips:   ClipsFeedView()
                case .communities:
                    ComingSoonView(
                        icon: "person.3.fill",
                        title: "Communities",
                        blurb: "Group spaces for the people, teams and interests you care about — announcements, sub-groups and shared media in one place.")
                case .games:
                    ComingSoonView(
                        icon: "gamecontroller.fill",
                        title: "Games",
                        blurb: "Quick games you can start straight from a chat and play with anyone in your conversations.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                }
                // Keep the selected tab on screen — a tab chosen by a deep link (a
                // notification opening Chats, say) must not sit silently off the edge.
                .onChange(of: tab) { _, t in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(t, anchor: .center) }
                }
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
            isSliding = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { tab = t }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { isSliding = false }
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
                            .scaleEffect(x: isSliding ? 1.9 : 1, y: 1, anchor: .center)
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
        .buttonStyle(.plain)
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
