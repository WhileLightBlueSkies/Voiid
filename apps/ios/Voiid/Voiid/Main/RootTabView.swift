//
//  RootTabView.swift
//  Voiid
//
//  Main app shell — custom bottom nav: CHAT · AI · CLIPS (Figma).
//

import SwiftUI

struct RootTabView: View {
    @State private var tab: Tab = .chat
    enum Tab { case chat, ai, clips }

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
            tabItem(.ai, "sparkles", "AI")
            tabItem(.chat, "bubble.left.fill", "Chats")
            tabItem(.clips, "play.rectangle.fill", "Clips")
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.xs)
        .background(VoiidColor.background.opacity(0.98))
        .overlay(VoiidColor.divider.opacity(0.5).frame(height: 1), alignment: .top)
    }

    private func tabItem(_ t: Tab, _ icon: String, _ label: String) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { tab = t }
        } label: {
            VStack(spacing: 6) {
                // Icon + label (active = primary, inactive = muted). PNG icons swap in later;
                // elastic select bounce.
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(tab == t ? VoiidColor.primary : VoiidColor.textSecondary)
                    .scaleEffect(tab == t ? 1.12 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.5), value: tab)
                Text(label)
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundColor(tab == t ? VoiidColor.primary : VoiidColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
