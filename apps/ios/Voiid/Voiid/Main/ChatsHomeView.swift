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
    @State private var callTarget: VConversation?
    @State private var activeCall: CallRequest?
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var allContacts: [VContact] = []   // discovered VOIID contacts (for search)
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
                if search.isEmpty {
                    // Home-screen-style draggable grid (reorder + drag to Call/Delete zones)
                    DraggableChatGrid(
                        items: tab == .chats ? $chat.directConversations : $chat.groupConversations,
                        onOpen: { openConversation = $0 },
                        onCall: { callTarget = $0 },
                        onDelete: { deleteTarget = $0 }
                    )
                } else {
                    // Search results — existing chats grid + contacts you can start a chat with.
                    ScrollView {
                        if !items.isEmpty {
                            sectionLabel("Chats")
                            LazyVGrid(columns: columns, spacing: VoiidSpacing.lg) {
                                ForEach(items) { conv in
                                    Button { Haptics.tap(); openConversation = conv } label: { gridCard(conv) }
                                        .buttonStyle(SoftPressStyle(scale: 0.94))
                                }
                            }
                            .padding(.horizontal, VoiidSpacing.lg)
                        }
                        if !contactResults.isEmpty {
                            sectionLabel("Start new chat")
                            VStack(spacing: 0) {
                                ForEach(contactResults) { c in
                                    Button { startChat(with: c) } label: { contactRow(c) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, VoiidSpacing.lg)
                        }
                        if items.isEmpty && contactResults.isEmpty {
                            Text("No chats or contacts found.")
                                .font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.textSecondary)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.top, VoiidSpacing.lg)
                    .padding(.bottom, 110)
                    .task(id: search) { await loadContactsForSearch() }
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .onAppear { session.hideTabBar = false }   // root screen always shows the bar
            .task {
                try? await E2EManager.shared.bootstrap()   // ensure identity/prekeys published (idempotent)
                WebSocketClient.shared.connect()           // live realtime relay (messages/typing/presence)
                await chat.loadConversations()              // load REAL conversations from backend
            }
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
            .sheet(isPresented: $showNewChat) {
                NewChatView { conv in
                    // Open the freshly-started chat after the sheet dismisses.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openConversation = conv }
                }
                .environmentObject(chat)
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { conv in
                    // Open the freshly-created group after the sheet dismisses.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openConversation = conv }
                }
                .environmentObject(chat)
            }
            .alert("Delete chat?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("Delete", role: .destructive) {
                    if let c = deleteTarget { chat.deleteConversation(c.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This chat will be deleted from your list.")
            }
            .sheet(item: $callTarget) { conv in
                CallTypeSheet(title: conv.title) { kind in
                    activeCall = CallRequest(
                        title: conv.title,
                        isGroup: conv.type == .group,
                        members: conv.type == .group ? DummyData.groupMembers : [],
                        photoName: conv.photoName,
                        kind: kind)
                }
            }
            .fullScreenCover(item: $activeCall) { CallScreen(request: $0) }
        }
    }

    private var items: [VConversation] {
        let base = tab == .chats ? chat.directConversations : chat.groupConversations
        guard !search.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    /// Contacts matching the search that you DON'T already have a chat with — so
    /// search surfaces "not started" chats too (tap to start). Chats tab only.
    private var contactResults: [VContact] {
        guard tab == .chats, !search.isEmpty else { return [] }
        let existingPeers = Set(chat.directConversations.compactMap { $0.peerUserId })
        return allContacts.filter {
            !existingPeers.contains($0.userId) &&
            $0.displayName.localizedCaseInsensitiveContains(search)
        }
    }

    private func loadContactsForSearch() async {
        guard allContacts.isEmpty else { return }   // cached (ContactsService also caches)
        if let result = try? await ContactsService.shared.discover() { allContacts = result.matches }
    }

    private func startChat(with c: VContact) {
        Haptics.tap()
        Task {
            if let conv = await chat.startDirectChat(with: c) {
                search = ""
                openConversation = conv
            }
        }
    }

    // Top bar — "Chats" title left, hamburger menu right
    private var header: some View {
        HStack {
            Text("Chats")
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Spacer()
            Button {
                Haptics.tap()
                if tab == .groups { showNewGroup = true } else { showNewChat = true }
            } label: {
                Image(systemName: tab == .groups ? "person.3.fill" : "square.and.pencil")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            Menu {
                Button(role: .destructive) {
                    Haptics.tap(); session.signOut()
                } label: {
                    Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
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

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text).font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textSecondary)
            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.md).padding(.bottom, VoiidSpacing.sm)
    }

    // A contact you can start a NEW chat with (search surfaced it; no conversation yet).
    private func contactRow(_ c: VContact) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidAvatar(size: 44, imageName: nil).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName).font(VoiidFont.rounded(16, .medium)).foregroundColor(VoiidColor.textPrimary)
                Text("Tap to start chat").font(VoiidFont.rounded(12)).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
            Image(systemName: "square.and.pencil").foregroundColor(VoiidColor.primary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, VoiidSpacing.sm)
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
