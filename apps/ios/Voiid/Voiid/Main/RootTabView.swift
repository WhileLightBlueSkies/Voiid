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
        HStack {
            tabItem(.ai, "sparkles", "AI")
            Spacer()
            tabItem(.chat, "bubble.left.fill", "CHAT")
            Spacer()
            tabItem(.clips, "play.rectangle.fill", "FILM")
        }
        .padding(.horizontal, VoiidSpacing.xl)
        .padding(.top, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.sm)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }

    private func tabItem(_ t: Tab, _ icon: String, _ label: String) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { tab = t }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .scaleEffect(tab == t ? 1.1 : 1)
                Text(label).font(VoiidFont.rounded(11, .semibold))
            }
            .foregroundColor(tab == t ? VoiidColor.primary : VoiidColor.textSecondary)
            .frame(width: 70)
        }
    }
}
