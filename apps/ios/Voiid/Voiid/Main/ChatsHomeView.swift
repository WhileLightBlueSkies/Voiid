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
    /// OBSERVED, not read once. `ThemePreference.shared.mode` inside the sheet body would be
    /// a snapshot — the sheet is where the theme is CHANGED, so it has to re-render when it
    /// does.
    @ObservedObject private var theme = ThemePreference.shared
    @EnvironmentObject var session: AppSession
    @State private var search = ""
    @State private var tab: Tab = .chats
    @State private var openConversation: VConversation?
    @State private var deleteTarget: VConversation?
    @State private var callTarget: VConversation?
    @State private var activeCall: CallRequest?
    @ObservedObject private var layoutPref = ChatLayoutPreference.shared
    @State private var showCallLog = false
    @State private var showNewChat = false
    @State private var showFindByUsername = false
    @State private var showRequests = false
    /// Inbound requests waiting to be accepted. Drives the banner below the header; a count of
    /// zero hides it entirely rather than showing an empty affordance.
    @State private var pendingRequestCount = 0
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var allContacts: [VContact] = []   // discovered VOIID contacts (for search)
    @Namespace private var underline

    /// Reduce Motion is honoured where LARGE objects travel — the list reflow below moves
    /// every row on screen, which is exactly the vestibular motion the setting exists to
    /// suppress. Small-element feedback (press states, the badge) is kept: removing it would
    /// cost information and calm nobody.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: String { case chats = "Chats", groups = "Groups" }

    private let columns = [GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                compactHeader
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
                    // THREE STATES, not one. The grid used to render for all of them, so a
                    // fresh install and a still-loading list both showed the same blank
                    // screen — the first thing a new user ever sees, indistinguishable from
                    // the app being broken.
                    // "Empty" means no REAL conversations. Note to Self always exists, so a
                    // plain isEmpty check would never fire on the Chats tab and a brand-new
                    // user would see one lonely tile with no explanation of what to do next.
                    let realItems = items.filter { $0.type != .self }
                    if !chat.didLoadConversations && realItems.isEmpty {
                        chatsLoadingState
                    } else if realItems.isEmpty {
                        chatsEmptyState
                    } else if layoutPref.layout == .grid {
                        // Home-screen-style draggable grid (reorder + drag to Call/Delete zones)
                        DraggableChatGrid(
                            items: tab == .chats ? $chat.directConversations : $chat.groupConversations,
                            onOpen: { openConversation = $0 },
                            onCall: { callTarget = $0 },
                            onDelete: { deleteTarget = $0 }
                        )
                    } else {
                        chatListLayout(items)
                    }
                } else {
                    // Search results — existing chats grid + contacts you can start a chat with.
                    ScrollView {
                        requestsBanner
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
                                    // SoftPressStyle, not .plain: a search result had no press
                                    // feedback at all, so it felt dead beside the chat rows
                                    // above it that respond on press-down. Same fix as the
                                    // matching Android row.
                                    Button { startChat(with: c) } label: { contactRow(c) }
                                        .buttonStyle(SoftPressStyle())
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
            // NO NAVIGATION TITLE, NO TOOLBAR. Both are now the single `compactHeader` row
            // above: the avatar and compose button moved into it, and the "Chats" large
            // title is gone entirely — it named the tab already selected in the bar at the
            // bottom, in the app whose icon you just tapped.
            // `.toolbar(.hidden)` rather than `.navigationBarHidden(true)`.
            //
            // THIS IS WHY THE LAYOUT COLLAPSED. Hiding the bar removes its HEIGHT but not the
            // safe area it used to occupy — with `.background(...ignoresSafeArea())` already
            // pushing content upward, the header ended up under the status bar and everything
            // below it shifted up with it. `.toolbar(.hidden, for: .navigationBar)` hides the
            // chrome while the VStack still respects the top safe area, so the header starts
            // BELOW the clock where it belongs.
            .toolbar(.hidden, for: .navigationBar)
            // ROOT SCREEN SHOWS THE BAR — but only when it is genuinely on top.
            //
            // THE CANCELLED-SWIPE BUG. `onAppear` fires while a back-swipe REVEALS this view
            // underneath the chat, before the gesture has been committed. Release the drag
            // short of the threshold and navigation snaps back to the chat — but this
            // `onAppear` has already run and set the bar visible, and the chat's own
            // `onAppear` does NOT re-fire (it was never removed). Result: the tab bar sitting
            // over an open chat until the next push or tab switch.
            //
            // `openConversation == nil` is the unambiguous test: during a cancelled swipe the
            // binding is still set, because the pop never completed. A real pop clears it,
            // and `onChange` below catches that case.
            .onAppear { if openConversation == nil { session.hideTabBar = false } }
            // The pop actually completed — now the bar belongs on screen. This fires on a
            // finished swipe as well as a Back tap, which `onAppear` alone would miss.
            .onChange(of: openConversation) { _, conv in
                if conv == nil { session.hideTabBar = false }
            }
            .task { await refreshRequestCount() }
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
                MapPresenceEngine.shared.configureControlSender()   // hand map_key/map_off to the audience over the ratchet
                Task { try? await E2EManager.shared.bootstrap() }   // publish identity/prekeys (idempotent)
                Task { await session.refreshServerProfile() }       // REAL name/photo/bio/username
                // Contact discovery (rebuilds saved-name map after a restore) — SLOW (address
                // book + hashing + network), so strictly background; when it finishes it
                // refreshes names in place via UserDirectory.
                Task { _ = try? await ContactsService.shared.discover() }
            }
            // OPENING A CHAT LIVES HERE. Removing the old toolbar block took this line and
            // the deep-link handler below with it, so every tap set `openConversation` and
            // nothing consumed it — the tile highlighted and the chat never appeared.
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
            .sheet(isPresented: $showCallLog) {
                CallLogView()
            }
            .sheet(isPresented: $showSettings) {
                // The theme preference is applied at ContentView, and a SHEET is presented in
                // its own window — so SwiftUI's environment does not carry the override
                // across, and Settings (the screen that CHANGES the theme) was the one screen
                // that would not repaint when you changed it. Re-stating it here means the
                // sheet's own hierarchy agrees with the UIKit window override.
                SettingsSheet()
                    .preferredColorScheme(theme.mode.colorScheme)
            }
            .sheet(isPresented: $showFindByUsername) {
                FindByUsernameView { conversationId, pending in
                    // A PENDING request has no chat to open yet — the recipient has not
                    // accepted, so navigating into it would show an empty transcript that
                    // looks broken. Refresh the list instead; it appears once accepted.
                    guard !pending else { Task { await chat.loadConversations() }; return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        Task {
                            await chat.loadConversations()
                            openConversation = chat.directConversations.first { $0.id == conversationId }
                        }
                    }
                }
            }
            .sheet(isPresented: $showRequests) {
                MessageRequestsView { conversationId in
                    Task {
                        await chat.loadConversations()
                        await refreshRequestCount()
                        openConversation = chat.directConversations.first { $0.id == conversationId }
                    }
                }
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
                    // Load REAL members for the group-call tiles (never DummyData), then start.
                    Task {
                        var members: [VMember] = []
                        if isGroup, let cm = try? await ChatService.shared.members(conversationId: conv.id) {
                            let myId = TokenStore.shared.userId
                            members = cm.map { m in
                                VMember(id: m.userId, name: m.name ?? "VOIID user", phone: "", photoName: nil,
                                        role: m.role, statusText: nil, isYou: m.userId == myId)
                            }
                        }
                        activeCall = CallRequest(
                            title: conv.title,
                            isGroup: isGroup,
                            members: members,
                            photoName: conv.photoName,
                            kind: kind,
                            peerUserId: isGroup ? nil : conv.peerUserId,
                            conversationId: conversationId)
                    }
                }
            }
            // ChatStore is injected BY HAND, not inherited. CallScreen needs it (for the
            // add-to-call picker) and a fullScreenCover does not reliably inherit the root's
            // environment objects — the failure is a RUNTIME CRASH the moment the screen
            // appears, not a compile error. CallScreen's own comment documents this hazard
            // for the sheet one level deeper; the same rule applies to CallScreen itself.
            .fullScreenCover(item: $activeCall) { CallScreen(request: $0).environmentObject(chat) }
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

    /// Avatar · search · compose, on ONE row.
    ///
    /// The screen used to spend four stacked bands before the first chat: a toolbar with the
    /// avatar and compose button, a 40pt "Chats" large title, a 52pt search field, then the
    /// tabs. Roughly a third of the display was chrome telling you that you were in the app
    /// you had just opened.
    ///
    /// The title goes first. It named the tab that is already selected in the bar at the
    /// bottom of the screen, in the app whose icon you just tapped — it was the least
    /// informative pixel on the page.
    ///
    /// Then the search field slots BETWEEN the two controls that were already on that row.
    /// Search is the most-used control on a chat list and it now sits at thumb height rather
    /// than under a title, and the row that held two small buttons and a lot of empty space
    /// earns its height.
    private var compactHeader: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button { Haptics.tap(); showSettings = true } label: {
                // 40, matching the glass buttons opposite it — a 38pt avatar beside 40pt
                // controls reads as a misalignment rather than a smaller element.
                ProfileAvatarButton(photoURL: session.profile.photoURL,
                                    name: session.profile.fullName, size: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")

            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(VoiidColor.placeholder)
                TextField("", text: $search,
                          prompt: Text("Search").foregroundColor(VoiidColor.placeholder))
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                if !search.isEmpty {
                    Button {
                        Haptics.tap(); search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(VoiidColor.placeholder)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            // 40pt, down from 52 — it no longer has a whole band to itself, so it can match
            // the height of the controls beside it instead of towering over them.
            .frame(height: 40)
            .background(VoiidColor.fieldFill)
            .clipShape(Capsule())

            composeButton
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.xs)
    }

    /// ONE menu, not a button whose meaning changes with the tab.
    ///
    /// It used to be a compose glyph on Chats and a people glyph on Groups, each doing a
    /// different thing — so the control under your thumb meant something different depending
    /// on a tab selection two rows up. Now every way to start a conversation lives in one
    /// list, and the glyph is a plain ellipsis, which promises exactly what it delivers:
    /// more options.
    private var composeButton: some View {
        Menu {
            Button { Haptics.tap(); showNewChat = true } label: {
                Label("New chat", systemImage: "person.crop.circle")
            }
            Button { Haptics.tap(); showFindByUsername = true } label: {
                Label("Find by username", systemImage: "at")
            }
            Button { Haptics.tap(); showNewGroup = true } label: {
                Label("New group", systemImage: "person.3")
            }
            // SETTINGS IS HERE TOO, not only behind the avatar. Tapping your own face to
            // reach app settings is a convention people learn, not one they guess — this
            // is the discoverable path, and the avatar stays as the shortcut for anyone
            // who already knows it.
            Divider()
            Button { Haptics.tap(); showCallLog = true } label: {
                Label("Calls", systemImage: "phone")
            }
            Button { Haptics.tap(); showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            headerGlyph("ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// A circular header button in the system's glass material.
    ///
    /// GLASS ON iOS 26, MATERIAL BELOW. `.glassEffect` is iOS 26-only and this project
    /// targets iOS 18, so it is availability-gated rather than adopted outright — on 26 the
    /// button gets Apple's real Liquid Glass (it refracts and specular-highlights against
    /// whatever scrolls beneath it), and on 18 it falls back to `.ultraThinMaterial`, which
    /// is the same visual language the platform used before Liquid Glass existed. Neither
    /// path is a flat tint, so the control reads as a system button on both.
    ///
    /// OPTICAL CENTERING, not geometric. `square.and.pencil` carries its pencil up and to
    /// the right, so its ink sits high-right of the glyph's bounding box — centering the BOX
    /// leaves the mark visibly off-centre in the circle. A per-symbol nudge fixes what the
    /// layout engine cannot see, which is the difference between "centered" and "looks
    /// centered".
    private func headerGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(VoiidColor.primary)
            .offset(opticalOffset(name))
            .frame(width: 40, height: 40)
            .modifier(GlassCircle())
    }

    /// Per-symbol optical correction. Values are small and deliberate: enough to look
    /// centered, never enough to look shifted.
    private func opticalOffset(_ name: String) -> CGSize {
        switch name {
        // The pencil's tip extends up-right past the square, pulling the visual mass with it.
        case "square.and.pencil": return CGSize(width: -0.5, height: 0.5)
        // The @ sign's descender-less bowl sits fractionally high in its box.
        case "at":               return CGSize(width: 0, height: 0.5)
        default:                 return .zero
        }
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

    /// Count of inbound requests, for the banner.
    ///
    /// Deliberately a COUNT and not a live list: the banner only needs to know whether to
    /// appear and with what number, and fetching the full list on every chat-home appearance
    /// would be a request per launch for a screen most users never open.
    private func refreshRequestCount() async {
        pendingRequestCount = (try? await ContactPinService.shared.pending().count) ?? 0
    }

    /// "N message requests" — shown only when there ARE some.
    ///
    /// This is the only surface for requests: `GET /conversations` filters pending ones out,
    /// so without this banner a stranger's accepted-pending message would be invisible until
    /// they gave up. An empty state here would be an affordance to nowhere, so it hides.
    @ViewBuilder
    private var requestsBanner: some View {
        if pendingRequestCount > 0 {
            Button {
                Haptics.tap()
                showRequests = true
            } label: {
                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(VoiidColor.primary)
                    Text(pendingRequestCount == 1 ? "1 message request"
                                                  : "\(pendingRequestCount) message requests")
                        .font(VoiidFont.rounded(14, .medium))
                        .foregroundStyle(VoiidColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, VoiidSpacing.sm)
        }
    }

    /// The classic list layout. See ChatLayoutPreference for why this exists alongside the
    /// grid, and ChatListRows for the per-row design decisions.
    private func chatListLayout(_ items: [VConversation]) -> some View {
        List {
            ForEach(items) { conv in
                ChatListRow(
                    conversation: conv,
                    onTap: { openConversation = conv },
                    onCall: { callTarget = conv },
                    onDelete: { deleteTarget = conv }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(VoiidColor.background)
                .listRowSeparatorTint(VoiidColor.divider.opacity(0.5))
                // Inset the separator to start at the TEXT, not the screen edge — the
                // avatar column reads as a gutter, and a full-width rule cuts through it.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 54 + VoiidSpacing.md * 2 }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(VoiidColor.background)
        // ROWS REORDER, THEY DO NOT TELEPORT.
        //
        // A chat jumps to the top the moment a message lands, and every row below it shifts
        // down by one — the most frequent state change on this screen, and it happened in a
        // single frame with nothing connecting the before and after. You could not tell
        // whether a row moved, or the whole list changed, or you had misread it.
        //
        // A spring, not an ease: messages arrive in bursts, and a second arrival landing
        // mid-reflow retargets from where the rows currently are instead of restarting from a
        // stale position. `items` is Hashable with a stable id, so SwiftUI animates the row
        // that MOVED rather than crossfading the list.
        //
        // Critically damped. Nothing here was thrown by the user, so nothing has earned
        // overshoot — an unread chat bouncing into place would draw the eye to the motion
        // rather than to the message.
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9),
                   value: items)
    }

    // MARK: - Empty / loading states

    /// Shown while the FIRST server load is still in flight and we have nothing cached.
    ///
    /// Deliberately not a bare spinner in the middle of a void: three dimmed placeholder
    /// tiles in the same grid shape the real chats will occupy, so the layout does not jump
    /// when content lands and the screen reads as "filling in" rather than "empty".
    private var chatsLoadingState: some View {
        VStack(spacing: VoiidSpacing.lg) {
            LazyVGrid(columns: columns, spacing: VoiidSpacing.lg) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        .fill(VoiidColor.surfaceCard)
                        .frame(height: 104)
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)
            Spacer(minLength: 0)
        }
        .padding(.top, VoiidSpacing.md)
        // The shimmer is what separates "loading" from "broken" — a static grey grid reads
        // as content that failed to render.
        .modifier(PulsePlaceholder())
        .accessibilityLabel("Loading chats")
    }

    /// A genuinely empty list — a fresh account, or one that has never started a chat.
    ///
    /// AN EMPTY STATE MUST OFFER THE WAY OUT. Saying "no chats yet" and stopping leaves the
    /// user to hunt for the button; both routes into a first conversation are right here.
    private var chatsEmptyState: some View {
        VStack(spacing: VoiidSpacing.md) {
            Spacer(minLength: VoiidSpacing.xl)

            ZStack {
                Circle()
                    .fill(VoiidColor.primary.opacity(0.10))
                    .frame(width: 88, height: 88)
                Image(systemName: tab == .chats ? "bubble.left.and.bubble.right.fill" : "person.3.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VoiidColor.primary)
            }

            Text(tab == .chats ? "No chats yet" : "No groups yet")
                .font(VoiidFont.rounded(20, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)

            Text(tab == .chats
                 ? "Start a conversation with someone in your contacts, or find them by @username."
                 : "Groups you create or get added to will appear here.")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VoiidSpacing.xl)

            if tab == .chats {
                HStack(spacing: VoiidSpacing.sm) {
                    Button {
                        Haptics.tap(); showNewChat = true
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundStyle(VoiidColor.textOnPrimary)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 44)
                            .background(VoiidColor.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(SoftPressStyle())

                    Button {
                        Haptics.tap(); showFindByUsername = true
                    } label: {
                        Label("Find by @username", systemImage: "at")
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 44)
                            .background(VoiidColor.primary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(SoftPressStyle())
                }
                .padding(.top, VoiidSpacing.sm)
            }

            // Note to Self is a real, usable chat even with zero contacts — offer it here
            // rather than hiding the one thing a brand-new user CAN do immediately.
            if tab == .chats, let note = chat.directConversations.first(where: { $0.type == .self }) {
                Button {
                    Haptics.tap(); openConversation = note
                } label: {
                    Label("Open Note to Self", systemImage: "bookmark.fill")
                        .font(VoiidFont.rounded(14, .medium))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, VoiidSpacing.xs)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func gridCard(_ conv: VConversation) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                // Avatar fills the column width as a square (scales per device).
                // The avatar is clipped to the tile HERE, before anything is layered on top.
                // `scaledToFill` deliberately overflows its frame to cover the square, so
                // without a clip bound to the tile itself the photo spilled past the rounded
                // corners and over the neighbouring column.
                ZStack {
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        .fill(VoiidColor.fieldFill)
                    GridCardAvatar(conv: conv)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))

                // Badges sit INSIDE the tile. They used to be pushed OUT past its edge
                // (offset x: 6, y: -6), which broke the grid's alignment and let a badge
                // overlap the tile beside it.
                if conv.isOnline {
                    Circle().fill(VoiidColor.success)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if conv.unreadCount > 0 {
                    Text("\(conv.unreadCount)")
                        // textOnAccent, NOT textOnPrimary: amber is a light fill in both
                        // themes, and textOnPrimary flips to near-white in light mode, where
                        // it measured 3.31:1 here — the least legible text on this screen.
                        .font(VoiidFont.rounded(11, .bold)).foregroundColor(VoiidColor.textOnAccent)
                        // Same rolling digit and same arrival as the list row's badge — the
                        // two layouts must teach one vocabulary, so the badge behaves
                        // identically whichever you have chosen.
                        .contentTransition(.numericText())
                        .frame(minWidth: 20, minHeight: 20)
                        .background(VoiidColor.accent).clipShape(Circle())
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 1.5))
                        .padding(5)
                        .transition(.scale(scale: 0.5, anchor: .topTrailing)
                            .combined(with: .opacity))
                }
            }
            // On the ZStack, which outlives the badge — a modifier on the badge itself has
            // nothing left to drive its exit when it is removed.
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: conv.unreadCount)
            Text(conv.title)
                .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1)
        }
    }
}

/// The face on a chat-home grid tile.
///
/// WHY THIS EXISTS: the grid used to render `UIImage(named: conv.photoName)` — a BUNDLED
/// ASSET name left over from the dummy data. Real peers have no bundled asset, so every
/// real conversation fell through to the wordmark and no peer photo ever appeared. Real
/// photos live at `photo_url` (an absolute URL or an R2 object key) on the user directory,
/// which this consults through `AvatarCache` — the same cache the profile button, chat
/// header and map markers use, so a face is fetched once per launch and then painted from
/// memory/disk everywhere (and offline).
///
/// Groups have no peer, so they keep the wordmark until group photos exist as a feature.
private struct GridCardAvatar: View {
    let conv: VConversation
    @ObservedObject private var directory = UserDirectory.shared

    /// Seeded synchronously from the cache so a known face paints on the FIRST frame —
    /// no flash of wordmark when scrolling back to a tile we already resolved.
    @State private var image: UIImage?

    /// Directory first (authoritative, and republishes on a contacts sync), then the members
    /// payload carried on the conversation itself.
    private var ref: String? {
        if let peer = conv.peerUserId, let url = directory.photoURL(peer) { return url }
        return conv.photoURL
    }

    var body: some View {
        // GeometryReader gives the image an explicit box to fill.
        //
        // `scaledToFill()` alone sizes the image from its INTRINSIC dimensions first and only
        // then fills — so a 3000px upload rendered at 3000px and spilled far outside the tile,
        // which is the "full profile image instead of the square" bug. Pinning an exact frame
        // and clipping to it is what actually constrains it.
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let name = conv.photoName, let ui = UIImage(named: name) {
                    // Legacy bundled-asset path, kept so seeded/demo conversations still render.
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    // The placeholder is sized RELATIVE to the tile, not to a fixed 56pt — the
                    // grid is three columns of whatever the device is wide, so a constant here
                    // looked oversized on an SE and lost on a Max.
                    BrandWordmark(size: geo.size.width * 0.18,
                                  color: VoiidColor.textSecondary,
                                  opacity: 0.22)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .onAppear { if image == nil { image = AvatarCache.cached(ref) } }
        .task(id: ref) {
            if image == nil { image = AvatarCache.cached(ref) }
            if image == nil, let ref { image = await AvatarCache.resolve(ref) }
        }
    }
}

/// A slow opacity pulse for skeleton placeholders.
///
/// The point is to distinguish LOADING from BROKEN. A static grey grid reads as content that
/// failed to render; the same grid breathing reads as content on its way. Deliberately gentle
/// (0.45→0.85 over 1.1s) — a fast or high-contrast pulse draws the eye to the placeholder
/// instead of to the content replacing it.
struct PulsePlaceholder: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.85 : 0.45)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// A circular glass background, gated to the OS that supports it.
///
/// Kept as a modifier rather than inlined so the availability check exists ONCE. Repeating
/// `if #available` at each call site is how one branch quietly drifts from the other.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                // The hairline is what reads as a SURFACE. Without it a blurred disc on a
                // dark ground is just a lighter patch.
                .overlay(
                    Circle().strokeBorder(VoiidColor.textPrimary.opacity(0.10), lineWidth: 1)
                )
        }
    }
}
