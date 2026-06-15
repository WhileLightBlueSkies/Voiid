//
//  ChatsHomeView.swift
//  Voiid
//
//  Chat home (Figma Screen-6/7): search bar, Chats | Groups segmented tabs,
//  grid of avatar cards. Tapping a card opens the chat.
//

import SwiftUI

struct ChatsHomeView: View {
    @EnvironmentObject var chat: ChatStore
    @State private var search = ""
    @State private var tab: Tab = .chats
    @State private var openConversation: VConversation?

    enum Tab { case chats, groups }

    private let columns = [GridItem(.flexible(), spacing: VoiidSpacing.lg),
                           GridItem(.flexible(), spacing: VoiidSpacing.lg),
                           GridItem(.flexible(), spacing: VoiidSpacing.lg)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                tabs
                ScrollView {
                    LazyVGrid(columns: columns, spacing: VoiidSpacing.lg) {
                        ForEach(items) { conv in
                            Button {
                                Haptics.tap(); openConversation = conv
                            } label: { gridCard(conv) }
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, 100)
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
        }
    }

    private var items: [VConversation] {
        let base = tab == .chats ? chat.directConversations : chat.groupConversations
        guard !search.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.textSecondary)
            TextField("Search", text: $search).font(VoiidFont.body)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(height: 52)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.top, VoiidSpacing.md)
    }

    private var tabs: some View {
        HStack(spacing: VoiidSpacing.xl) {
            tabButton("Chats", .chats)
            tabButton("Groups", .groups)
            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.md)
        .overlay(Divider(), alignment: .bottom)
    }

    private func tabButton(_ label: String, _ t: Tab) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(VoiidFont.headline)
                .foregroundColor(tab == t ? VoiidColor.primary : VoiidColor.textSecondary)
            Rectangle().fill(tab == t ? VoiidColor.primary : .clear).frame(height: 2)
        }
        .onTapGesture { withAnimation(.spring(response: 0.3)) { tab = t } }
    }

    private func gridCard(_ conv: VConversation) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                VoiidAvatar(size: 100, imageName: conv.photoName)
                if conv.isOnline {
                    Circle().fill(VoiidColor.success)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                        .offset(x: -6, y: 6)
                }
                if conv.unreadCount > 0 {
                    Text("\(conv.unreadCount)")
                        .font(VoiidFont.caption).foregroundColor(.white)
                        .padding(6).background(VoiidColor.error).clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            Text(conv.title)
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1)
        }
    }
}
