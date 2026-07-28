//
//  RootTabView.swift
//  Voiid
//
//  Main app shell — custom bottom nav: AI · Chats · Map · Clips.
//  Elastic menu bar: a pill indicator stretches/snaps between tabs + icon bounce.
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

    // The asset/label ternaries were hardcoded for exactly three cases; with a 4th tab they
    // become switches so a future 5th tab is a compile error to omit, not a silent wrong icon.
    enum Tab: CaseIterable { case ai, chat, stories, map, clips
        var asset: String {
            switch self {
            case .ai:      return "TabAI"
            case .chat:    return "TabChats"
            case .stories: return "TabStories"
            case .map:     return "TabMap"     // rendered via SF Symbol (see iconGlyph) — no PNG asset
            case .clips:   return "TabClips"
            }
        }
        var label: String {
            switch self {
            case .ai:      return "AI"
            case .chat:    return "Chats"
            case .stories: return "Stories"
            case .map:     return "Map"
            case .clips:   return "Clips"
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(.ai)
            tabItem(.chat)
            tabItem(.stories)
            tabItem(.map)
            tabItem(.clips)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.xs)
        .background(VoiidColor.background.opacity(0.98))
        .overlay(VoiidColor.divider.opacity(0.5).frame(height: 1), alignment: .top)
    }

    private func tabItem(_ t: Tab) -> some View {
        let active = tab == t
        return Button {
            Haptics.selection()
            // elastic spring (low damping = bouncy)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { tab = t }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    // Elastic pill indicator that slides + stretches between tabs
                    if active {
                        Capsule()
                            .fill(VoiidColor.accent.opacity(0.55))
                            .matchedGeometryEffect(id: "tabPill", in: indicator)
                            .frame(width: 54, height: 40)
                    }
                    iconGlyph(t, active: active)
                        .frame(width: 24, height: 24)
                        .foregroundColor(active ? VoiidColor.primary : VoiidColor.textSecondary)
                        .scaleEffect(active ? 1.12 : 1)
                        // The Map badge sits at the icon's top-right, drawn whether or not the
                        // tab is active — visibility must be legible from every screen.
                        .overlay(alignment: .topTrailing) {
                            if t == .map { mapVisibilityBadge.offset(x: 6, y: -4) }
                            // Stories unread dot: any unexpired unviewed story exists (§8.1).
                            if t == .stories && storyEngine.hasUnviewed {
                                Circle().fill(VoiidColor.accent)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(VoiidColor.background, lineWidth: 1.5))
                                    .offset(x: 6, y: -4)
                            }
                        }
                }
                .frame(height: 40)
                Text(t.label)
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundColor(active ? VoiidColor.primary : VoiidColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// The Map tab uses an SF Symbol (no bundled `TabMap` PNG exists yet — a designed asset
    /// can replace this without touching call sites). Every other tab uses its template PNG.
    @ViewBuilder
    private func iconGlyph(_ t: Tab, active: Bool) -> some View {
        if t == .map {
            Image(systemName: "map")
                .resizable().scaledToFit()
                .fontWeight(active ? .semibold : .regular)
        } else {
            Image(t.asset)
                .renderingMode(.template)
                .resizable().scaledToFit()
        }
    }

    /// Filled accent dot while visible; a hollow ghost glyph while ghosted (§8).
    @ViewBuilder
    private var mapVisibilityBadge: some View {
        if mapVisibility.isVisible {
            Circle()
                .fill(VoiidColor.primary)
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
