//
//  ChatsHomeView.swift
//  Voiid
//
//  Chat home (Figma Screen-6/7): hamburger header, search, Chats | Groups tabs
//  with animated underline, 3-column grid of avatar cards. Tap a card -> chat.
//

import SwiftUI

struct ChatsHomeView: View {
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    @State private var search = ""
    @State private var tab: Tab = .chats
    @State private var openConversation: VConversation?
    @State private var deleteTarget: VConversation?
    @Namespace private var underline

    enum Tab: String { case chats = "Chats", groups = "Groups" }

    private let columns = [GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchBar
                tabs
                ScrollView {
                    LazyVGrid(columns: columns, spacing: VoiidSpacing.lg) {
                        ForEach(items) { conv in
                            Button { Haptics.tap(); openConversation = conv } label: { gridCard(conv) }
                                .buttonStyle(SoftPressStyle(scale: 0.94))
                                .contextMenu {
                                    Button { openConversation = conv } label: { Label("Open", systemImage: "bubble.left") }
                                    Button(role: .destructive) { deleteTarget = conv } label: {
                                        Label("Delete chat", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.lg)
                    .padding(.bottom, 110)
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .onAppear { session.hideTabBar = false }   // root screen always shows the bar
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
            .confirmationDialog("Delete this chat?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible) {
                if let c = deleteTarget {
                    Button("Delete chat", role: .destructive) { chat.deleteConversation(c.id) }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    private var items: [VConversation] {
        let base = tab == .chats ? chat.directConversations : chat.groupConversations
        guard !search.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    // Top bar — "Chats" title left, hamburger menu right
    private var header: some View {
        HStack {
            Text("Chats")
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Spacer()
            Button { Haptics.tap() } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(VoiidColor.textPrimary)
            }
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.sm)
    }

    private var searchBar: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.placeholder)
            TextField("", text: $search,
                      prompt: Text("Search").foregroundColor(VoiidColor.placeholder))
                .font(VoiidFont.body).foregroundColor(VoiidColor.textPrimary)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(height: 52)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.pill).stroke(VoiidColor.fieldBorder, lineWidth: 1))
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.md)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton(.chats)
            tabButton(.groups)
        }
        .padding(.top, VoiidSpacing.lg)
        .overlay(VoiidColor.divider.opacity(0.5).frame(height: 1), alignment: .bottom)
    }

    private func tabButton(_ t: Tab) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = t }
        } label: {
            VStack(spacing: 8) {
                Text(t.rawValue)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(tab == t ? VoiidColor.primary : VoiidColor.textSecondary)
                ZStack {
                    Capsule().fill(.clear).frame(height: 3)
                    if tab == t {
                        Capsule()
                            .fill(LinearGradient(colors: [VoiidColor.primary, VoiidColor.accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(height: 3)
                            .matchedGeometryEffect(id: "tabUnderline", in: underline)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func gridCard(_ conv: VConversation) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                // Avatar fills the column width as a square (scales per device).
                ZStack {
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        .fill(VoiidColor.fieldFill)
                    if let name = conv.photoName, let ui = UIImage(named: name) {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Image("VoiidWordmark").resizable().scaledToFit()
                            .frame(width: 56).opacity(0.22)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))

                if conv.isOnline {
                    Circle().fill(VoiidColor.success)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                        .offset(x: -6, y: 6)
                }
                if conv.unreadCount > 0 {
                    Text("\(conv.unreadCount)")
                        .font(VoiidFont.rounded(11, .bold)).foregroundColor(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(VoiidColor.error).clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            Text(conv.title)
                .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1)
        }
    }
}
