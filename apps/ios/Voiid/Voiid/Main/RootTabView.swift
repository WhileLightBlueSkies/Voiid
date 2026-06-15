//
//  RootTabView.swift
//  Voiid
//
//  Main app shell — custom bottom nav: AI · Chats · Clips.
//  Elastic menu bar: a pill indicator stretches/snaps between tabs + icon bounce.
//

import SwiftUI

struct RootTabView: View {
    @State private var tab: Tab = .chat
    @Namespace private var indicator

    enum Tab: CaseIterable { case ai, chat, clips
        var asset: String { self == .ai ? "TabAI" : self == .chat ? "TabChats" : "TabClips" }
        var label: String { self == .ai ? "AI" : self == .chat ? "Chats" : "Clips" }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .chat:  ChatsHomeView()
                case .ai:    AIChatView()
                case .clips: ClipsFeedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
        }
        .ignoresSafeArea(.keyboard)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(.ai)
            tabItem(.chat)
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
                    Image(t.asset)
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundColor(active ? VoiidColor.primary : VoiidColor.textSecondary)
                        .scaleEffect(active ? 1.12 : 1)
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
}
