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
    @State private var showSettings = false
    @State private var allContacts: [VContact] = []   // discovered VOIID contacts (for search)
    @Namespace private var underline

    enum Tab: String { case chats = "Chats", groups = "Groups" }

    private let columns = [GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                tabs
                // "You are sharing your location" — pinned below the tabs, visible from the
                // home screen, one-tap Stop (docs/LOCATION.md §8). Renders nothing when idle.
                LocationBanner()
                // `loadError` was set but never rendered anywhere, so a failed sync on a
                // cold launch produced a blank grid with no explanation. With local-first
                // loading this only appears when we have nothing cached to fall back on.
                if let loadError = chat.loadError {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "wifi.exclamationmark")
                        Text(loadError).font(VoiidFont.rounded(13, .regular))
                        Spacer()
                        Button("Retry") { Task { await chat.loadConversations() } }
                            .font(VoiidFont.rounded(13, .semibold))
                    }
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, VoiidSpacing.sm)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.bottom, VoiidSpacing.sm)
                }
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
            // Native large title + toolbar (replaces the hand-drawn header): the system draws
            // the "Chats" title and the bar; we only supply the leading profile avatar (→
            // Settings) and the trailing compose action.
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showSettings = true } label: {
                        ProfileAvatarButton(photoURL: session.profile.photoURL,
                                            name: session.profile.fullName, size: 32)
                    }
                    .accessibilityLabel("Profile and settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        if tab == .groups { showNewGroup = true } else { showNewChat = true }
                    } label: {
                        Image(systemName: tab == .groups ? "person.3.fill" : "square.and.pencil")
                    }
                    .accessibilityLabel(tab == .groups ? "New group" : "New chat")
                }
            }
            .onAppear { session.hideTabBar = false }   // root screen always shows the bar
            .task {
                // INSTANT FIRST: render the cached (local) chat list before ANY network or
                // address-book work. loadConversations() reads local storage synchronously up
                // front, so the list appears immediately; the network sync inside it continues
                // after. Nothing slow may run before this — that was the 8–15s "not instant" bug
                // (contact discovery + profile fetch were awaited ahead of the render).
                await chat.loadConversations()

                // Everything below is background/best-effort and must NEVER block the list.
                WebSocketClient.shared.reconnect()         // fresh socket (avoid a stale/dead one missing pushes)
                LocationShareEngine.shared.configure()     // route inbound live fixes + start the expiry ticker
                Task { try? await E2EManager.shared.bootstrap() }   // publish identity/prekeys (idempotent)
                Task { await session.refreshServerProfile() }       // REAL name/photo/bio/username
                // Contact discovery (rebuilds saved-name map after a restore) — SLOW (address
                // book + hashing + network), so strictly background; when it finishes it
                // refreshes names in place via UserDirectory.
                Task { _ = try? await ContactsService.shared.discover() }
            }
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
            .onReceive(NotificationCenter.default.publisher(for: .voiidOpenConversation)) { note in
                // Deep-link from a tapped message notification: open its conversation,
                // loading the list first if it isn't in memory yet.
                guard let convId = note.object as? String else { return }
                Task { @MainActor in
                    let present = chat.directConversations.contains { $0.id == convId }
                        || chat.groupConversations.contains { $0.id == convId }
                    if !present { await chat.loadConversations() }
                    if let conv = chat.directConversations.first(where: { $0.id == convId })
                        ?? chat.groupConversations.first(where: { $0.id == convId }) {
                        openConversation = conv
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
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
                    // Mirrors ChatDetailView.startCall. Without peerUserId (1:1) or
                    // conversationId (group) CallScreen falls back to the SIMULATED
                    // path — so calls started from the list must carry them, or they
                    // silently do nothing real.
                    let isGroup = conv.type == .group
                    // 1:1 and group calls both own the audio route, so they're
                    // mutually exclusive.
                    guard GroupCallService.canStart() else { return }
                    // A real group call needs the MLS group to exist: the media key is
                    // derived from it, and joining without it would hand plaintext to
                    // the SFU. Fall back rather than silently downgrade.
                    let conversationId: String? = (isGroup && GroupEngine.shared.hasGroup(conversationId: conv.id))
                        ? conv.id
                        : nil
                    activeCall = CallRequest(
                        title: conv.title,
                        isGroup: isGroup,
                        members: isGroup ? DummyData.groupMembers : [],
                        photoName: conv.photoName,
                        kind: kind,
                        peerUserId: isGroup ? nil : conv.peerUserId,
                        conversationId: conversationId)
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
