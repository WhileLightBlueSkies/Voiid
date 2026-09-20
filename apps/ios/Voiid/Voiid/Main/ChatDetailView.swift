//
//  ChatDetailView.swift
//  Voiid
//
//  1:1 / group chat. Full experience on dummy data:
//   • bubbles: sent = filled peacock teal, received = the quiet card surface with a hairline
//   • receipts are WORDS — Sent · Delivered · Seen — on every outgoing message, not ticks
//   • date separators (Today / Yesterday / date) + typing indicator
//   • voice notes (record + send + playback), images (pick + send + fullscreen)
//   • no bottom tab bar here (hidden via session.hideTabBar)
//

import SwiftUI
import MapKit
import PhotosUI
import UIKit
import CryptoKit
import AVFoundation
import AVKit

struct ChatDetailView: View {
    let conversation: VConversation
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    /// Settings → Privacy. Observed (not just read) so flipping a toggle in the Settings
    /// sheet re-renders the presence line immediately instead of on the next open.
    @ObservedObject private var privacy = PrivacySettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var draft = ""
    @State private var transcriptNearBottom = true
    @State private var photoItem: PhotosPickerItem?
    /// The message whose media opened the gallery. An id, not a decoded UIImage: the
    /// viewer pages through the whole conversation, so it needs to know WHERE it started,
    /// not just what was tapped.
    @State private var galleryStartId: String?
    /// Set by the viewer's "Jump to message". The transcript scrolls to it and flashes it.
    @State private var jumpTargetId: String?
    /// Briefly marks the message a jump landed on.
    @State private var highlightedId: String?
    @ObservedObject private var notificationRouter = NotificationMessageRouter.shared
    @State private var notificationPositioned = false
    @State private var showInfo = false       // group info / contact profile
    @State private var showSafetyNumber = false
    @State private var showAttach = false     // attach menu (photo / poll)
    @State private var showPollCompose = false
    @State private var showLocationCompose = false   // location share compose sheet
    @State private var showLudoSetup = false
    @State private var pickPhoto = false
    /// Live capture, distinct from `pickPhoto` (the photo LIBRARY). The camera button was
    /// wired to the library, so tapping it opened the picker rather than the camera.
    @State private var showCamera = false
    @State private var showGifPicker = false
    /// Recording takes over the WHOLE composer row — see RecordingBar. Kept here rather than
    /// in the mic button because the bar is a sibling of the text field, not its child.
    @State private var isRecording = false
    @State private var recordSeconds: TimeInterval = 0
    @State private var recordDragX: CGFloat = 0
    @State private var cancelRecordingRequest = 0
    @State private var recordingDeleted = false
    @State private var recordingDiscarding = false
    @State private var replyingTo: VMessage?  // reply preview above input
    @State private var infoMessage: VMessage? // Message Info sheet
    @State private var forwardMessage: VMessage? // forward chat-picker
    @State private var deleteMessage: VMessage?   // single delete confirm
    // Multi-select
    @State private var selectionMode = false
    @State private var selectedIDs = Set<String>()
    @State private var showBulkDelete = false
    @State private var forwardBulk = false
    @State private var activeCall: CallRequest?
    @State private var typingIdleTask: Task<Void, Never>?
    @State private var typingActivity = TypingActivity()
    /// Place profile-originated calls once the navigation transition finishes.
    @State private var pendingCall: CallKind?
    /// REAL group members (from the server), used for @mentions and group-call member tiles.
    /// Empty for 1:1 chats. Loaded on appear — never DummyData.
    @State private var groupMembers: [VMember] = []

    private var chatContent: some View {
        VStack(spacing: 0) {
            // Multi-select has its own bar; NORMAL mode uses the NATIVE navigation bar +
            // toolbar — Apple's system back button and `chatToolbar` items. No custom chrome,
            // no forced background: iOS renders it as Liquid Glass on 26 and its own native
            // bar on 18 (the native fallback), automatically.
            if selectionMode { selectionHeader }
            // "You are sharing your location" — pinned at the top of the chat, one-tap Stop.
            LocationBanner(conversationId: conversation.id)
            ongoingCallBanner
            messageList
            if let error = chat.loadError {
                Text(error).font(.footnote).foregroundStyle(VoiidColor.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            inputBar
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selectionMode)
        .toolbar(selectionMode ? .hidden : .visible, for: .navigationBar)
        .toolbar { if !selectionMode { chatToolbar } }
        // Hide the bottom tab bar while a chat is open; restore on leave.
        .onAppear {
            session.hideTabBar = true
            chat.openConversation(conversation)   // load cached + sync (fetch+decrypt) real messages
            // Call bubbles come from the local call_history table, not the message store, so
            // they are loaded alongside the transcript rather than arriving through sync.
            chat.loadCallLogs(conversation.id)
        }
        // A call placed from THIS chat must leave its bubble behind as soon as it ends, not
        // only on the next open. CallService clears `active` when the call is fully torn down.
        .onChange(of: CallService.shared.active == nil) { _, _ in
            chat.loadCallLogs(conversation.id)
        }
        .task(id: conversation.id) {
            // Real group members for @mentions + group-call tiles (never DummyData).
            guard conversation.type == .group,
                  let cm = try? await ChatService.shared.members(conversationId: conversation.id) else { return }
            let myId = TokenStore.shared.userId
            groupMembers = cm.map { m in
                VMember(id: m.userId, name: m.name ?? "VOIID user", phone: "", photoName: nil,
                        role: m.role, statusText: nil, isYou: m.userId == myId)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Poll the conversation while it's open — fetch+decrypt new messages, send
            // receipts, refresh presence — so delivery doesn't depend on the WS push
            // (which can be silently dropped). Every 4s.
            while !Task.isCancelled {
                await chat.syncMessages(conversation)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .onDisappear {
            // CLOSE the conversation: this is what stops read receipts firing for a chat the
            // user has navigated away from. Paired with `openConversation` in ChatStore.
            chat.closeConversation(conversation.id)
            // NOTE: do NOT reset hideTabBar here. Pushing the contact/group profile fires
            // this onDisappear, and if it ran AFTER the profile's onAppear (which hides the
            // bar) the footer would flash back on over the profile. The bar is instead
            // restored solely by each ROOT tab's onAppear (hideTabBar = false), so returning
            // to Chats/Clips/etc. shows it and every detail screen keeps it hidden.
            stopTyping()
        }
        .onChange(of: privacy.sendTypingIndicators) { _, enabled in
            if !enabled { stopTyping() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopTyping() }
        }

        // The profile screen asks for a call by setting `pendingCall`; it is placed once the
        // push has finished unwinding, so ChatDetailView remains the single owner of call
        // setup rather than duplicating peer resolution and the group-call lock.
        .onChange(of: showInfo) { _, isShowing in
            guard !isShowing, let kind = pendingCall else { return }
            pendingCall = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { startCall(kind) }
        }
        .navigationDestination(isPresented: $showInfo) {
            switch conversation.type {
            case .group:
                GroupInfoView(conversation: conversation, pendingCall: $pendingCall)
            case .self:
                // Note to Self has no peer, so ContactProfileView would open, find
                // `peerUserId == nil`, and render a profile of nobody. There is no second
                // person to show — the header is not a link.
                EmptyView()
            case .direct:
                ContactProfileView(conversation: conversation, pendingCall: $pendingCall)
            }
        }
    }

    private var chatSheets: some View {
        chatContent
        .sheet(isPresented: $showSafetyNumber) {
            if conversation.type == .group {
                GroupSecurityVerificationSheet(conversationId: conversation.id)
            } else {
                SafetyNumberView(peerUserId: livePeerUserId ?? "", peerName: conversation.title)
            }
        }
        .sheet(isPresented: $showGifPicker) {
            GifPickerSheet { data in
                // A GIF is ORDINARY E2EE MEDIA once it reaches here — same encrypt-and-upload
                // path as a photo. The recipient never contacts GIPHY, so no third party
                // learns who received what, and the GIF survives the provider deleting it.
                chat.sendMedia(data, mime: "image/gif", to: conversation.id)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPollCompose) {
            PollComposeSheet { q, opts in
                chat.sendPoll(q, options: opts, to: conversation.id)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLocationCompose) {
            LocationComposeSheet(
                conversationTitle: conversation.title,
                isGroup: conversation.type == .group,
                audienceCount: conversation.type == .group ? max(1, conversation.memberCount - 1) : 1,
                onSendPin: { label, coord in sendLocationPin(label: label, coordinate: coord) },
                onStartLive: { duration in startLiveShare(duration: duration) })
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLudoSetup) {
            LudoChatSetupView(
                hasHumanPeer: conversation.type != .self,
                availablePeers: conversation.type == .group
                    ? max(1, conversation.memberCount - 1) : 1
            ) { mode, difficulty in
                startLudo(mode: mode, difficulty: difficulty)
            }
            .presentationDetents([.medium])
        }
        .alert("Reaction not sent", isPresented: Binding(
            get: { chat.reactionError != nil },
            set: { if !$0 { chat.reactionError = nil } }
        )) {
            Button("OK", role: .cancel) { chat.reactionError = nil }
        } message: {
            Text(chat.reactionError ?? "")
        }
        .alert("Message not sent", isPresented: Binding(
            get: { chat.mediaSendError != nil },
            set: { if !$0 { chat.mediaSendError = nil } }
        )) {
            Button("OK", role: .cancel) { chat.mediaSendError = nil }
        } message: {
            Text(chat.mediaSendError ?? "")
        }
        .alert("Couldn’t delete", isPresented: Binding(
            get: { chat.deletionError != nil },
            set: { if !$0 { chat.deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { chat.deletionError = nil }
        } message: { Text(chat.deletionError ?? "") }
        .sheet(item: $infoMessage) { msg in
            MessageInfoSheet(message: msg, isGroup: conversation.type == .group)
                .presentationDetents([.medium])
        }
        .sheet(item: $forwardMessage) { msg in
            ForwardSheet(message: msg) { targets in
                chat.forward(msg, to: targets)
            }
        }
    }

    var body: some View {
        chatSheets
        // Single message delete — confirmation modal
        .confirmationDialog("Delete message?", isPresented: Binding(
            get: { deleteMessage != nil }, set: { if !$0 { deleteMessage = nil } }),
            titleVisibility: .visible) {
            if let m = deleteMessage {
                if m.isMine && conversation.type != .group && !m.deletedForEveryone && m.status != .sending && m.status != .failed {
                    Button("Delete for everyone", role: .destructive) {
                        chat.deleteMessage(m.id, in: conversation.id, forEveryone: true)
                    }
                }
                Button("Delete for me", role: .destructive) {
                    chat.deleteMessage(m.id, in: conversation.id, forEveryone: false)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        // Bulk delete — alert modal
        .alert("Delete \(selectedIDs.count) message\(selectedIDs.count == 1 ? "" : "s")?", isPresented: $showBulkDelete) {
            if canDeleteSelectionForEveryone {
                Button("Delete for everyone", role: .destructive) {
                    chat.deleteMessages(selectedIDs, in: conversation.id, forEveryone: true)
                    exitSelection()
                }
            }
            Button("Delete for me", role: .destructive) {
                chat.deleteMessages(selectedIDs, in: conversation.id, forEveryone: false)
                exitSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose who the selected messages are deleted for.") }
        // Bulk forward
        .sheet(isPresented: $forwardBulk) {
            ForwardSheet(message: chat.messages(for: conversation.id).first(where: { selectedIDs.contains($0.id) }) ?? VMessage(id: "", conversationId: "", senderId: "", text: "", createdAt: .now)) { targets in
                let msgs = chat.messages(for: conversation.id).filter { selectedIDs.contains($0.id) }
                for m in msgs { chat.forward(m, to: targets) }
                exitSelection()
            }
        }
        .fullScreenCover(item: Binding(
            get: { galleryStartId.map { IdWrapper(id: $0) } },
            set: { galleryStartId = $0?.id })
        ) { start in
            ChatMediaViewer(chatId: conversation.id, startMessageId: start.id) { messageId in
                // Jump to message: the viewer dismisses itself, then the thread scrolls to
                // the message and flashes it. Set AFTER dismissal so the scroll happens on a
                // visible transcript rather than behind a cover that is still on screen.
                jumpTargetId = messageId
            }
            .environmentObject(chat)
        }
        // ChatStore injected by hand — see the note at the matching call site in
        // ChatsHomeView. A fullScreenCover does not reliably inherit environment objects and
        // the failure is a runtime crash, not a compile error.
        .fullScreenCover(item: $activeCall) { CallScreen(request: $0).environmentObject(chat) }
    }

    /// "Ongoing call — Join". Groups only: a 1:1 call rings the peer directly, so there is no
    /// such thing as a 1:1 call you could be missing quietly.
    ///
    /// Extracted rather than inlined into `body` — as an inline `if` it pushed that VStack past
    /// the type-checker's budget and failed the build outright.
    @ViewBuilder private var ongoingCallBanner: some View {
        if conversation.type == .group {
            OngoingCallBanner(conversationId: conversation.id) { startCall(.voice) }
        }
    }

    private func startCall(_ kind: CallKind) {
        let isGroup = conversation.type == .group

        // 1:1 and group calls both own the audio route, so they are mutually
        // exclusive — starting one while the other runs would put two WebRTC audio
        // session managers in charge of a single AVAudioSession.
        guard GroupCallService.canStart() else { return }

        // A real group call needs the MLS group to exist, since the media key is
        // derived from it. Without it we'd have no way to encrypt, and joining
        // unencrypted would expose media to the SFU — so fall back rather than
        // silently downgrade.
        //
        // A 1:1 call always carries its conversation: `POST /calls/ring` requires one
        // (without it the callee's wake push is never sent) and the missed-call
        // notification threads and deep-links on it. It does NOT make the call a group
        // call — that needs `isGroup` too.
        let conversationId: String? = isGroup
            ? (GroupEngine.shared.hasGroup(conversationId: conversation.id) ? conversation.id : nil)
            : conversation.id

        activeCall = CallRequest(
            title: conversation.title,
            isGroup: isGroup,
            members: isGroup ? groupMembers : [],
            photoName: conversation.photoName,
            kind: kind,
            peerUserId: isGroup ? nil : resolvedPeerUserId,
            conversationId: conversationId)
    }

    /// The 1:1 peer's user id for placing a real call.
    private var resolvedPeerUserId: String? {
        chat.directConversations.first(where: { $0.id == conversation.id })?.peerUserId ?? conversation.peerUserId
    }

    // MARK: - Location sharing (docs/LOCATION.md — feature A)

    private var isGroupChat: Bool { conversation.type == .group }

    /// The 1:1 peer's user id, local-first (cached) then resolved from the server.
    private func resolvePeer() async -> String? {
        if let p = resolvedPeerUserId { return p }
        return try? await ChatService.shared.resolvePeer(conversationId: conversation.id).peerUserId
    }

    /// Send a static pin. The engine captures one fix and sends the E2EE envelope; the
    /// echo appears in this chat, so we refresh once the send returns.
    private func sendLocationPin(label: String?, coordinate: CLLocationCoordinate2D? = nil) {
        Task {
            let peer = isGroupChat ? nil : await resolvePeer()
            guard isGroupChat || peer != nil else { return }
            LocationShareEngine.shared.sendPin(conversationId: conversation.id, isGroup: isGroupChat,
                                               peerUserId: peer, label: label,
                                               coordinate: coordinate) { _ in
                Task { @MainActor in chat.openConversation(conversation) }
            }
        }
    }

    /// Start a time-bounded live share. The audience for the WS fix stream is the peer
    /// (1:1) or every OTHER group member (resolved from the server member list).
    private func startLiveShare(duration: ShareDuration) {
        Task {
            let me = TokenStore.shared.userId
            let recipients: [String]
            let peer: String?
            if isGroupChat {
                peer = nil
                recipients = ((try? await ChatService.shared.members(conversationId: conversation.id)) ?? [])
                    .map { $0.userId }.filter { $0 != me }
            } else {
                peer = await resolvePeer()
                recipients = peer.map { [$0] } ?? []
            }
            guard !recipients.isEmpty else { return }
            _ = await LocationShareEngine.shared.startLiveShare(
                conversationId: conversation.id, isGroup: isGroupChat, peerUserId: peer,
                recipientIds: recipients, duration: duration)
            chat.openConversation(conversation)
        }
    }

    // MARK: header

    /// The NATIVE chat toolbar. Apple owns the back button and all bar chrome; we only
    /// supply content — a tappable avatar+name in `.principal` (→ profile / group info) and
    /// call / video / ⋯ as trailing items. The system renders it: Liquid Glass on iOS 26,
    /// the classic native bar on iOS 18. Nothing custom, no forced background.
    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Note to Self has nothing behind the header — see navigationDestination. A
            // button that opens an empty screen is worse than a label that does nothing.
            Button { guard conversation.type != .self else { return }; Haptics.tap(); showInfo = true } label: {
                HStack(spacing: VoiidSpacing.sm) {
                    // 36pt and 16pt — the reference's header metrics. The FULL name stays
                    // here, deliberately: unlike a grid tile this row has the width for it,
                    // and the one place you should be certain who you are talking to is the
                    // conversation itself. `minimumScaleFactor` handles the long ones rather
                    // than truncating an identity.
                    ProfileAvatarButton(photoURL: conversation.photoURL,
                                        name: conversation.title, size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(conversation.title)
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if let presenceText {
                            // 12pt MEDIUM, not 11pt regular.
                            //
                            // The colour already passed WCAG on paper — textSecondary is
                            // 6.06:1 on the light ground and 7.57:1 on the dark one. That
                            // measurement is misleading here: this line sits in a Liquid
                            // Glass toolbar, so the real backdrop is not the ground colour
                            // at all, it is whatever chat content happens to be scrolling
                            // underneath, blurred. Against a photo or a filled bubble the
                            // effective contrast is far lower than the number suggests.
                            //
                            // Weight is what survives that. A thin 11pt glyph has almost no
                            // ink to carry against a busy translucent backdrop; the same
                            // text one step heavier and one point larger stays legible
                            // without shouting, and "Online" reads as status rather than as
                            // a caption someone forgot to style.
                            //
                            // ONLINE ALSO GETS A DOT. Presence is the one fact here worth
                            // spotting without reading, and a green dot is how every
                            // messenger signals it — colour alone would fail for the ~1 in
                            // 12 men with a colour-vision deficiency, so the word stays too.
                            HStack(spacing: 4) {
                                if isPeerOnline {
                                    Circle()
                                        .fill(VoiidColor.success)
                                        .frame(width: 6, height: 6)
                                }
                                Text(presenceText)
                                    .font(VoiidFont.rounded(12, .medium))
                                    .foregroundColor(presenceTint)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(conversation.type == .group ? "Group info" : "Contact profile")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { Haptics.tap(); startCall(.voice) } label: {
                Image(systemName: "phone")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Voice call")
            .accessibilityIdentifier("chat.header.voiceCall")
            Button { Haptics.tap(); startCall(.video) } label: {
                Image(systemName: "video")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Video call")
            .accessibilityIdentifier("chat.header.videoCall")
        }
    }

    private var canDeleteSelectionForEveryone: Bool {
        let rows = chat.messages(for: conversation.id).filter { selectedIDs.contains($0.id) }
        return conversation.type != .group && !rows.isEmpty && rows.allSatisfy {
            $0.isMine && !$0.deletedForEveryone && $0.status != .sending && $0.status != .failed
        }
    }

    private var selectionHeader: some View {
        HStack(spacing: VoiidSpacing.md) {
            Button { exitSelection() } label: {
                Text("Cancel").font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.primary)
            }
            Text("\(selectedIDs.count) selected")
            Button("All") {
                selectedIDs = Set(chat.messages(for: conversation.id).filter { $0.call == nil && $0.kind != .system }.map(\.id))
            }
            .accessibilityLabel("Select all messages")
                .font(VoiidFont.rounded(16, .semibold)).foregroundColor(VoiidColor.textPrimary)
            Spacer()
            Button { if !selectedIDs.isEmpty { forwardBulk = true } } label: {
                Image(systemName: "arrowshape.turn.up.right").font(.system(size: 18)).foregroundColor(VoiidColor.primary)
            }.disabled(selectedIDs.isEmpty)
            Button { if !selectedIDs.isEmpty { showBulkDelete = true } } label: {
                Image(systemName: "trash").font(.system(size: 18)).foregroundColor(VoiidColor.error)
            }.disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
        .background(VoiidColor.background)
    }

    private func exitSelection() {
        withAnimation { selectionMode = false; selectedIDs.removeAll() }
    }
    private func toggleSelect(_ id: String) {
        Haptics.selection()
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }


    /// Peer user_id read from the live store (resolved lazily after open), not the
    /// value-copied `conversation` which never updates.
    private var livePeerUserId: String? {
        chat.directConversations.first(where: { $0.id == conversation.id })?.peerUserId ?? conversation.peerUserId
    }

    /// True only for a 1:1 peer who is actually online — drives the status dot. Groups show
    /// a member count, which is not presence, so they never get one.
    private var isPeerOnline: Bool {
        guard conversation.type == .direct, privacy.showOnlineStatus,
              !chat.typingConversations.contains(conversation.id) else { return false }
        return chat.directConversations.first(where: { $0.id == conversation.id })?.isOnline == true
    }

    /// Typing and Online are STATES worth noticing; "last seen" and a member count are
    /// reference facts. Tinting the first two and leaving the rest secondary is what makes
    /// the line scannable instead of uniformly grey.
    private var presenceTint: Color {
        if chat.typingConversations.contains(conversation.id) { return VoiidColor.primary }
        if isPeerOnline { return VoiidColor.onlineText }
        return VoiidColor.textSecondary
    }

    /// `nil` when there is no line to draw, so the caller omits the `Text` entirely
    /// rather than laying out an empty one.
    private var presenceText: String? {
        if chat.typingConversations.contains(conversation.id) { return "typing…" }
        if conversation.type == .group { return "\(conversation.memberCount) members" }
        // Settings → Privacy → "Show when contacts are online". Display-only, this
        // device: it hides the online / last-seen line, it does not change presence
        // reporting. Typing and the group member count are not online status and stay.
        guard privacy.showOnlineStatus else { return nil }
        let live = chat.directConversations.first(where: { $0.id == conversation.id })
        if live?.isOnline == true { return "Online" }
        if let seen = live?.lastSeenAt { return "last seen \(VoiidDate.relative(seen))" }
        return nil
    }

    // MARK: message list with date separators + auto-scroll

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: VoiidSpacing.sm) {
                    if conversation.type != .self { encryptionNotice }
                    ForEach(groupedByDay, id: \.0) { day, msgs in
                        DateSeparator(text: day)
                        ForEach(msgs) { msg in
                            messageRow(msg)
                                .id(msg.id)
                                // A wash behind the row rather than a border on the bubble:
                                // it reads at a glance while scrolling past and does not
                                // change the bubble's own shape.
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(VoiidColor.accent.opacity(
                                            highlightedId == msg.id ? 0.16 : 0))
                                        .padding(.horizontal, -6)
                                )
                        }
                    }
                    if chat.typingConversations.contains(conversation.id) {
                        TypingBubble().id("typing")
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                // Extra headroom at the TOP: the navigation bar is translucent, so the
                // transcript scrolls under it. With symmetric 16pt padding the first bubble
                // sat beneath the bar and was clipped — visible in the screenshot as a
                // half-hidden call log. The bar's own material still blurs whatever passes
                // behind it; this just stops content STARTING there.
                // 8, not 32: the first bubble sat a full extra 24pt down the screen.
            .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, VoiidSpacing.md)
            }
            .softTopEdgeEffect()
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 120
            } action: { _, nearBottom in
                transcriptNearBottom = nearBottom
            }
            .task(id: notificationRouter.pendingMessage?.id) {
                guard let target = notificationRouter.pendingMessage,
                      target.conversationId == conversation.id else { return }
                // A tap may arrive before the websocket or NSE has refreshed this transcript.
                if let id = target.messageId, !chat.messages(for: conversation.id).contains(where: { $0.id == id }) {
                    await chat.syncMessages(conversation)
                }
            }
            .task(id: "\(notificationRouter.pendingMessage?.id.uuidString ?? "")-\(chat.messages(for: conversation.id).count)") {
                guard let target = notificationRouter.pendingMessage,
                      target.conversationId == conversation.id, let messageId = target.messageId,
                      chat.messages(for: conversation.id).contains(where: { $0.id == messageId }) else { return }
                notificationPositioned = true
                await Task.yield()
                guard !Task.isCancelled, notificationRouter.pendingMessage == target else { return }
                proxy.scrollTo(messageId, anchor: .center)
                highlightedId = messageId
                notificationRouter.consumeMessage(target)
            }
            .task(id: highlightedId) {
                guard let id = highlightedId else { return }
                try? await Task.sleep(for: .milliseconds(1800))
                guard !Task.isCancelled, highlightedId == id else { return }
                highlightedId = nil
            }
            .onChange(of: chat.messages(for: conversation.id).count) { old, new in
                guard !notificationPositioned, notificationRouter.pendingMessage?.conversationId != conversation.id else { return }
                // The FIRST load is not an arrival — it is the transcript appearing. Landing
                // on it without animation is what makes a chat open AT the newest message
                // rather than at the top and then visibly scrolling down.
                //
                // `onAppear` alone could not do this: it fires before the cached messages
                // are in the store, so `lastID` was still empty and the scroll targeted
                // nothing. That is why opening a chat sat at the top.
                if old == 0 {
                    proxy.scrollTo(lastID, anchor: .bottom)
                } else if new > old && (transcriptNearBottom || chat.messages(for: conversation.id).last?.isMine == true) {
                    // A real new message DOES animate — the movement is what tells you
                    // something arrived.
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            .onChange(of: chat.typingConversations) { _, _ in
                guard transcriptNearBottom, chat.typingConversations.contains(conversation.id) else { return }
                guard !notificationPositioned, notificationRouter.pendingMessage?.conversationId != conversation.id else { return }
                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
            }
            .onAppear {
                guard notificationRouter.pendingMessage?.conversationId != conversation.id else { return }
                // Covers the case where messages were ALREADY in the store when the view
                // appeared (reopening a chat you just left), which the count change above
                // will not fire for.
                proxy.scrollTo(lastID, anchor: .bottom)
            }
            // JUMP TO MESSAGE, from the media viewer.
            //
            // A beat after the cover dismisses, or the scroll happens behind a view that is
            // still on screen and lands you at the bottom instead.
            .onChange(of: jumpTargetId) { _, id in
                guard let id else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(320))
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    // Flash it: after scrolling a long way, "which one was it" is the next
                    // question, and a brief highlight answers it without a permanent mark.
                    withAnimation(.easeIn(duration: 0.2)) { highlightedId = id }
                    try? await Task.sleep(for: .milliseconds(1400))
                    withAnimation(.easeOut(duration: 0.5)) { highlightedId = nil }
                    jumpTargetId = nil
                }
            }
            // The scrollbar is noise on a transcript nobody scrubs by handle.
            .scrollIndicators(.hidden)
            // Dragging the thread dismisses the keyboard — the gesture every messaging app
            // has, and its absence is felt every time you want to read back while typing.
            .scrollDismissesKeyboard(.interactively)
            // Lands AT THE BOTTOM on first layout rather than laying out at the top and
            // then visibly scrolling down to the newest message.
            .defaultScrollAnchor(.bottom)
        }
    }

    /// A header action: 32pt `surfaceCard` circle with a hairline, 14pt medium glyph.
    ///
    /// SIZED DOWN FROM THE REFERENCE'S 36, deliberately. The reference draws its own header
    /// as a plain HStack, so it can spend 36pt twice and lay the identity out beside it.
    /// Ours is a NATIVE toolbar, where the identity is the `.principal` item — and the
    /// system centres that against the whole bar, then shrinks and shifts it to clear
    /// whatever the trailing group occupies. Two 36pt circles pushed the avatar and name
    /// visibly right of centre.
    ///
    /// 32pt keeps the drawn chrome the reference asks for while leaving the identity where
    /// it belongs. The tap target is unchanged — the 44pt frame below is what the finger
    /// hits, not the circle.
    private func headerCircle(_ icon: String) -> some View {
        Circle()
            .fill(VoiidColor.surfaceCard)
            .frame(width: 32, height: 32)
            .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// Centered verification badge at the beginning of the transcript, at any message count.
    private var encryptionNotice: some View {
        Button { Haptics.tap(); showSafetyNumber = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .medium))
                Text("End-to-end encrypted").font(VoiidFont.rounded(12, .medium))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(VoiidColor.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(VoiidColor.surfaceCard, in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .center)
            .disabled(conversation.type != .group && livePeerUserId == nil)
            .accessibilityLabel("Messages and calls are end-to-end encrypted")
            .accessibilityHint("Verify security codes")
    }

    // Extracted per-message row (keeps messageList small enough for the type-checker).
    @ViewBuilder private func messageRow(_ msg: VMessage) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            if selectionMode {
                Button { toggleSelect(msg.id) } label: {
                    Image(systemName: selectedIDs.contains(msg.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(selectedIDs.contains(msg.id) ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.5))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selectedIDs.contains(msg.id) ? "Deselect message" : "Select message")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            MessageBubble(message: msg,
                          isGroup: conversation.type == .group,
                          isLastMine: msg.id == lastMineID,
                          onTapImage: { _ in galleryStartId = msg.id },
                          onVote: { optId in chat.vote(messageId: msg.id, optionId: optId, in: conversation.id) },
                          onReply: { withAnimation { replyingTo = msg } },
                          onForward: { forwardMessage = msg },
                          onReact: { e in chat.react(messageId: msg.id, emoji: e, in: conversation.id) },
                          onCopy: { UIPasteboard.general.string = msg.text },
                          onInfo: { infoMessage = msg },
                          onDelete: { deleteMessage = msg },
                          onSelect: {
                              // Enter selection ALREADY holding this message. Entering empty
                              // (which the old toolbar menu did) made the first tap after
                              // "Select messages" mean something different from every tap
                              // after it.
                              withAnimation { selectionMode = true; selectedIDs = [msg.id] }
                          },
                          selectionMode: selectionMode,
                          onSelectTap: { toggleSelect(msg.id) },
                          // Tap a call bubble to call back with the SAME kind.
                          onCallBack: { isVideo in startCall(isVideo ? .video : .voice) })
        }
    }

    private var lastID: String { chat.messages(for: conversation.id).last?.id ?? "" }
    private var lastMineID: String { chat.messages(for: conversation.id).last(where: { $0.isMine })?.id ?? "" }

    @State private var dayGroups = MessageDayGroups<VMessage>(date: \.createdAt)

    private var groupedByDay: [(String, [VMessage])] {
        dayGroups.groups(chat.messages(for: conversation.id)).map {
            (VoiidDate.separator($0.0), $0.1)
        }
    }

    // MARK: input bar (text + attach image + voice note)

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    // @mentions — suggest members when the draft's current token starts with "@" (group only).
    private var mentionQuery: String? {
        guard conversation.type == .group,
              let at = draft.lastIndex(of: "@") else { return nil }
        let after = draft[draft.index(after: at)...]
        // only active if the @token has no space yet
        return after.contains(" ") ? nil : String(after)
    }
    private var mentionSuggestions: [VMember] {
        guard let q = mentionQuery else { return [] }
        return groupMembers.filter { !$0.isYou &&
            (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
    }
    private func insertMention(_ m: VMember) {
        if let at = draft.lastIndex(of: "@") {
            draft = String(draft[..<at]) + "@\(m.name) "
        }
        Haptics.selection()
    }

    // Input bar — ⊕ · pink pill field · send/voice (matches design)
    private var inputBar: some View {
        VStack(spacing: 0) {
            if recordingDeleted {
                Label("Recording deleted", systemImage: "trash")
                    .font(VoiidFont.rounded(12, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.vertical, 6)
                    .transition(.opacity)
                    .task {
                        do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
                        withAnimation(.easeOut(duration: 0.15)) { recordingDeleted = false }
                    }
            }
            // Reply preview
            if let r = replyingTo {
                HStack(spacing: VoiidSpacing.sm) {
                    RoundedRectangle(cornerRadius: 2).fill(VoiidColor.primary).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.isMine ? "You" : (r.senderName.isEmpty ? conversation.title : r.senderName))
                            .font(VoiidFont.rounded(12, .semibold)).foregroundColor(VoiidColor.primary)
                        Text(r.kind == .text ? r.text : "Attachment")
                            .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Button { withAnimation { replyingTo = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(VoiidColor.textSecondary)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                .background(VoiidColor.surfaceCard)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // @mention suggestions strip (group only)
            if !mentionSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VoiidSpacing.sm) {
                        ForEach(mentionSuggestions) { m in
                            Button { insertMention(m) } label: {
                                HStack(spacing: 6) {
                                    VoiidAvatar(size: 26, imageName: m.photoName).clipShape(Circle())
                                    Text(m.name).font(VoiidFont.rounded(13, .medium)).foregroundColor(VoiidColor.textPrimary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(VoiidColor.surfaceCard).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                }
                .background(VoiidColor.background)
            }
            inputRow
        }
    }

    /// The composer.
    ///
    /// The attach button and GIF button live INSIDE the pill, not beside it. Previously the
    /// plus sat outside, so the pill could never use the full width and the row carried two
    /// sets of padding — the wasted space in the original. Everything is now one container:
    /// actions on the left, text in the middle, send on the right.
    ///
    /// Height dropped from 46pt minimum + 8pt vertical padding to a 38pt field in a pill with
    /// 4pt padding. Same tap targets (the buttons are 32pt, above the 44pt-with-padding
    /// threshold once the pill's own padding is counted), noticeably less chrome.
    /// The composer.
    ///
    /// ONE mic button, mounted ONCE, never swapped. The previous version rendered the normal
    /// row and the recording bar as alternatives in an `if`, which meant SwiftUI TORE DOWN the
    /// VoiceRecordButton the instant recording began and mounted a different instance inside
    /// the bar. The active gesture died with it and the new instance had no recorder — so
    /// recording, hold-to-record and slide-to-cancel all failed together. That is one bug, not
    /// three.
    ///
    /// The fix is identity: the button lives at a fixed position in the tree, and the
    /// RECORDING BAR is layered over the rest of the row instead of replacing it. The gesture
    /// therefore survives, because from SwiftUI's point of view nothing moved.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // Everything except the mic collapses while recording — same slot, zero width, so
            // the view identities survive and only the layout changes.
            HStack(alignment: .bottom, spacing: VoiidSpacing.sm) {
                // ONE button outside the pill, not two.
                //
                // The reference puts a single 44pt attach circle beside the field and moves
                // the secondary actions INSIDE the capsule (see `messageField`). Ours had a
                // second 44pt disc for GIF sitting next to it, which gave the row a
                // three-control left cluster and squeezed the field it exists to serve.
                if !(isRecording || recordingDiscarding) {
                    attachButton
                }
                ZStack(alignment: .leading) {
                    if (isRecording || recordingDiscarding) {
                        RecordingBar(seconds: recordSeconds, dragX: recordDragX, isDiscarding: recordingDiscarding) {
                            cancelRecordingRequest += 1
                        }
                    } else {
                        messageField
                    }
                }
                if !(isRecording || recordingDiscarding) && hasText { sendButton }
            }
            .frame(maxWidth: .infinity)

            // The mic. ALWAYS in the tree, at the same position — this is what keeps the
            // gesture alive across the state change. Hidden (not removed) while recording,
            // because the bar shows the state and a second mic beside it would be noise.
            //
            // IT ALSO COLLAPSES WHEN THERE IS TEXT, which gives the reference's mic↔send
            // SWAP — one slot, one control, the state told by which glyph is there — without
            // the `if/else` that would destroy the button. Removing it from the tree is
            // exactly the bug described above: the active gesture dies with the instance.
            // Collapsing to zero width is indistinguishable on screen and keeps identity.
            micButton
                .opacity((isRecording || recordingDiscarding) || hasText ? 0 : 1)
                .frame(width: (isRecording || recordingDiscarding) || hasText ? 0 : 46)
                .allowsHitTesting(!hasText && !recordingDiscarding)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // OPAQUE, not `.bar` — the reference's choice, and it removed the material for a
        // reason we had reintroduced: a translucent composer lets the last bubble and the
        // typing indicator bleed through it as they scroll under, so the newest message
        // reads as cut in half by the control you are about to type into.
        //
        // The transcript ends at the composer rather than passing behind it, which is what
        // makes the bottom of the thread legible.
        .background(VoiidColor.background)
        .overlay(VoiidColor.divider.frame(height: 0.5), alignment: .top)
        .animation(.easeOut(duration: 0.18), value: (isRecording || recordingDiscarding))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
    }

    private var micButton: some View {
        VoiceRecordButton(
            onSend: { data, duration in
                chat.sendMedia(data, mime: "audio/m4a",
                               caption: "Voice · \(Int(duration))s", to: conversation.id)
            },
            onRecordingChange: { active in
                if active { recordingDeleted = false; recordSeconds = 0; recordDragX = 0 }
                withAnimation(.easeOut(duration: 0.18)) { isRecording = active }
            },
            onDrag: { recordDragX = $0 },
            onTick: { recordSeconds = $0 },
            cancelRequest: cancelRecordingRequest,
            onDiscard: {
                withAnimation(.easeOut(duration: 0.18)) { recordingDiscarding = true }
            })
        .task(id: recordingDiscarding) {
            guard recordingDiscarding else { return }
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                recordingDiscarding = false
                recordingDeleted = true
            }
        }
    }

    private var attachButton: some View {
        // Attach — photo / location / poll.
        Menu {
            Button { pickPhoto = true } label: { Label("Photo", systemImage: "photo") }
            Button { showLocationCompose = true } label: { Label("Location", systemImage: "location") }
            Button { showLudoSetup = true } label: { Label("Games · Ludo", systemImage: "gamecontroller") }
            if conversation.type == .group {
                Button { showPollCompose = true } label: { Label("Poll", systemImage: "chart.bar") }
            }
        } label: {
            // A tinted DISC, matching the mic and send buttons. These two were bare
            // glyphs sitting beside two filled circles, which is what made the row look
            // unbalanced — four actions, two of them shapes and two of them floating ink.
            Image(systemName: "plus")
                // 44pt, 20pt glyph, accent ink on a fieldFill disc with a divider stroke —
                // the reference's composer chrome. At 32/15 in faint grey this was both
                // under the touch minimum and visually incidental next to the send button.
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(VoiidColor.accentInk)
                .frame(width: 44, height: 44)
                .background(VoiidColor.fieldFill)
                .clipShape(Circle())
                .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
        }
        .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            // `selfieMode: false` — rear camera and no forced square crop. The defaults are
            // tuned for a profile photo; a chat photo is usually of what is in front of you,
            // and cropping it square discards the framing the sender chose.
            CameraPicker(onCapture: { image in
                // Re-encoded rather than sent raw: a capture is a full-resolution HEIC/JPEG
                // that can run to several MB, and the media path is the same encrypt-and-
                // upload one every other image takes. 0.85 keeps it visually lossless at a
                // fraction of the bytes.
                guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                chat.sendMedia(data, mime: "image/jpeg", to: conversation.id)
            }, selfieMode: false)
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    // Encrypt + upload the real bytes (E2EE), not a placeholder.
                    chat.sendMedia(data, mime: "image/jpeg", to: conversation.id)
                }
                photoItem = nil
            }
        }
    }

    private func startLudo(mode: LudoChatMode, difficulty: String) {
        Task {
            let candidates: [String]
            if conversation.type == .group {
                candidates = groupMembers.filter { !$0.isYou }.map(\.id)
            } else if conversation.type == .direct {
                if let peer = conversation.peerUserId {
                    candidates = [peer]
                } else {
                    let resolved = try? await ChatService.shared.resolvePeer(
                        conversationId: conversation.id)
                    candidates = resolved?.peerUserId.map { [$0] } ?? []
                }
            } else {
                candidates = []
            }
            let opponents: [String]
            let bots: Int
            switch mode {
            case .duelHuman: opponents = Array(candidates.prefix(1)); bots = 0
            case .duelBot: opponents = []; bots = 1
            case .four: opponents = Array(candidates.prefix(3)); bots = 3 - opponents.count
            }
            guard let id = await GamesEngine.shared.createLudoFromChat(
                conversationId: conversation.id, opponentIds: opponents,
                bots: bots, difficulty: difficulty) else { return }
            if !opponents.isEmpty {
                chat.send(GameInvite.encode(slug: "ludo", matchId: id, meta: .init(
                    game: "Ludo", from: "", level: bots > 0 ? difficulty.capitalized : "",
                    format: mode == .four ? "4 players" : "1 vs 1",
                    sentAt: GameInvite.nowMs())), to: conversation.id)
            }
            NotificationCenter.default.post(name: .voiidOpenGameMatch, object: nil,
                userInfo: ["match_id": id, "slug": "ludo"])
        }
    }

    private var gifButton: some View {
        // GIF. A first-class button rather than buried in the attach menu — it is the one
        // people reach for most, and a menu tap between them and it is friction for
        // nothing.
        Button {
            Haptics.tap()
            showGifPicker = true
        } label: {
            Image(systemName: "face.smiling")
                // Matches the attach button's metrics so the two read as one pair.
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(VoiidColor.textSecondary)
                .frame(width: 44, height: 44)
                .background(VoiidColor.fieldFill)
                .clipShape(Circle())
                .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// The pill: the field plus its inline actions.
    ///
    /// The reference carries GIF/emoji and camera INSIDE the capsule, beside the text, and
    /// keeps only attach outside it. That is what lets the field own the row's width — two
    /// 44pt discs outside the pill cost 88pt of a 393pt screen before a character is typed.
    ///
    /// They collapse while there is text so the field keeps its full width for what you are
    /// writing, and reappear when it empties.
    private var messageField: some View {
        HStack(alignment: .bottom, spacing: VoiidSpacing.sm) {
            fieldText
            if !hasText {
                inlineAction("face.smiling", "GIFs and stickers") {
                    Haptics.tap(); showGifPicker = true
                }
                inlineAction("camera", "Camera") {
                    Haptics.tap(); showCamera = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(VoiidColor.divider, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: hasText)
    }

    /// A glyph inside the pill. Bare ink, not a disc — it sits ON the field's own fill, and
    /// a second circle inside a capsule reads as a button stuck to a button.
    private func inlineAction(_ icon: String, _ label: String,
                              _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundColor(VoiidColor.textSecondary)
                // 30pt of target inside the pill's own padding — the capsule's 10pt vertical
                // padding brings the real touch area to 44pt.
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var fieldText: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .font(VoiidFont.rounded(16, .regular))
            .foregroundColor(VoiidColor.textPrimary)
            // Native vertical TextField grows to six lines, then scrolls its content
            // and follows the insertion point without expanding the composer further.
            .lineLimit(1...6)
            .fixedSize(horizontal: false, vertical: false)
            .frame(minHeight: 20)
            // The FIELD carries the pill, not the whole row. Putting the background on
            // the row meant a 6-line paragraph inflated the entire container into a tall
            // blob with the buttons stranded in its bottom corners — visible in the
            // screenshot. Now the pill grows with the text and the buttons sit beside it,
            // fixed, exactly as they do when the field is one line.

            .onChange(of: draft) { _, text in
                let now = ProcessInfo.processInfo.systemUptime
                let allowed = privacy.sendTypingIndicators && scenePhase == .active
                    && chat.openConversationId == conversation.id
                emitTyping(typingActivity.edited(at: now, allowed: allowed,
                                                hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                typingIdleTask?.cancel()
                guard typingActivity.active else { typingIdleTask = nil; return }
                typingIdleTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    catch { return }
                    emitTyping(typingActivity.expire(at: ProcessInfo.processInfo.systemUptime))
                }
            }
    }

    private func emitTyping(_ state: Bool?) {
        guard let state else { return }
        if state && (!privacy.sendTypingIndicators || UIApplication.shared.applicationState != .active) { return }
        // The server derives current group membership; direct chats narrow to their peer.
        let recipients: [String]? = conversation.type == .group ? nil : livePeerUserId.map { [$0] }
        WebSocketClient.shared.sendTyping(conversationId: conversation.id,
                                          recipientIds: recipients, isStart: state)
    }

    private func stopTyping() {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        emitTyping(typingActivity.stop())
    }

    private var sendButton: some View {
            Button {
                Haptics.tap()
                chat.send(draft.trimmingCharacters(in: .whitespaces), to: conversation.id, replyTo: replyingTo)
                draft = ""
                withAnimation { replyingTo = nil }
            } label: {
                // A FILLED circle: send is the primary action here and should look like a
                // button, not a loose glyph with no tap target to aim at.
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    // 46pt, the reference's size. At 32 every composer control was ~30%
                    // smaller than the design and the send target was below the 44pt minimum.
                    .frame(width: 46, height: 46)
                    .background(VoiidColor.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Message bubble

/// A finished call, in the transcript (WhatsApp/Signal style).
///
/// Sided like a real bubble — outgoing right, incoming left — because a call IS attributable
/// to one party, unlike a system announcement. Tapping calls back with the same kind.
///
/// A MISSED incoming call is the one state that gets colour: it is the only one the user may
/// still need to act on. Everything else stays quiet so a long call history does not shout.
struct CallLogBubble: View {
    let log: VCallLog
    var onCallBack: () -> Void

    private var missed: Bool { log.incoming && !log.answered }

    /// The call-log arrow. Direction first, medium second: whether it was video is already in
    /// the title text, but whether YOU called THEM is not stated anywhere else.
    private var directionIcon: String {
        if missed { return "phone.arrow.down.left" }          // arrived, unanswered
        if log.outcome == "declined" { return "phone.down.fill" }
        return log.incoming ? "arrow.down.left" : "arrow.up.right"
    }

    /// Outgoing sits on filled teal, so everything on it inverts.
    private var bodyTint: Color { log.incoming ? VoiidColor.textPrimary : VoiidColor.textOnBubble }
    private var subTint: Color {
        log.incoming ? VoiidColor.textSecondary : VoiidColor.textOnBubble.opacity(0.75)
    }
    private var iconTint: Color { log.incoming ? VoiidColor.primary : VoiidColor.textOnBubble }

    private var title: String {
        // "Incoming"/"Outgoing" is stated, not implied. An answered call read only "Voice
        // call" regardless of who placed it, so the transcript could not tell you whether you
        // called them or they called you — the single most useful fact in a call log.
        if log.answered {
            let medium = log.isVideo ? "video call" : "voice call"
            return (log.incoming ? "Incoming " : "Outgoing ") + medium
        }
        switch log.outcome {
        case "declined": return log.incoming ? "Declined call" : "Call declined"
        case "failed":   return "Call failed"
        default:
            if log.incoming { return log.isVideo ? "Missed video call" : "Missed voice call" }
            return "No answer"
        }
    }

    /// Duration only when there IS one — an unanswered call has no elapsed time to report.
    private var durationText: String? {
        guard let s = log.durationSeconds else { return nil }
        let m = s / 60
        return m >= 60
            ? String(format: "%d:%02d:%02d", m / 60, m % 60, s % 60)
            : String(format: "%d:%02d", m, s % 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            // minLength 0, not 56. The old value FORCED a 56pt gutter on the opposite side,
            // so a short call log was pushed to at least (width - 56) — combined with the
            // Spacer that used to sit inside the bubble, that is why these rendered wider
            // than the messages around them. Zero lets the bubble be exactly as wide as its
            // content and sit flush against its own edge, which is what Android does.
            if !log.incoming { Spacer(minLength: 0) }
            Button {
                Haptics.tap()
                onCallBack()
            } label: {
                HStack(spacing: 10) {
                    // The glyph sits on a soft disc so the row has an anchor, and so a
                    // MISSED call's red is a filled badge rather than a lone tinted icon
                    // that is easy to miss in a scrolling transcript.
                    ZStack {
                        Circle()
                            .fill(missed ? VoiidColor.error.opacity(0.15) : iconTint.opacity(0.15))
                            .frame(width: 34, height: 34)
                        // DIRECTION, which was missing entirely — every call drew the same
                        // phone glyph, so incoming and outgoing were indistinguishable and the
                        // bubble's side was the only clue. These are the standard call-log
                        // arrows: up-right leaving, down-left arriving, and a distinct
                        // "missed" variant so a missed call is not just a red tint.
                        Image(systemName: directionIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(missed ? VoiidColor.error : iconTint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundColor(bodyTint)
                        HStack(spacing: 5) {
                            Text(log.startedAt, style: .time)
                            if let durationText { Text("· \(durationText)") }
                        }
                        .font(VoiidFont.rounded(11, .regular))
                        .foregroundColor(subTint)
                    }
                    // NO Spacer HERE. A `Spacer` inside the bubble expands to every point the
                    // parent offers, so the bubble stretched to the full width of the
                    // transcript no matter how short "Missed · 0:12" is — a call log ended up
                    // wider than the messages around it, which is backwards. Fixed 10pt
                    // instead, so the row WRAPS its content like Android's does.
                    Spacer().frame(width: 10)
                    // Tapping calls back, so say so — a bare row gives no hint it is tappable.
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(subTint)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                // Outgoing is FILLED teal exactly like a sent message; incoming is the quiet
                // card. A call log is part of the transcript, so it has to obey the same
                // sided colour language rather than inventing its own.
                .background(log.incoming ? VoiidColor.bubbleReceived : VoiidColor.bubbleSent)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    log.incoming
                        ? RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(VoiidColor.divider, lineWidth: 0.5)
                        : nil
                )
            }
            .buttonStyle(.plain)
            // A flexible Spacer on the trailing side so the bubble sits against its own edge
            // — this one is OUTSIDE the bubble, so it pushes rather than stretches.
            if log.incoming { Spacer(minLength: 0) }
        }
        .padding(.vertical, 2)
    }
}

private extension VerticalAlignment {
    private enum GroupBubbleBottom: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[.bottom] }
    }
    static let groupBubbleBottom = VerticalAlignment(GroupBubbleBottom.self)
}

struct MessageBubble: View {
    @State private var showingSenderProfile = false
    let message: VMessage
    let isGroup: Bool
    var isLastMine: Bool = false      // (kept for call-site compatibility)
    var onTapImage: (UIImage) -> Void
    var onVote: (String) -> Void = { _ in }      // optionId
    var onReply: () -> Void = {}
    var onForward: () -> Void = {}
    var onReact: (String) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onInfo: () -> Void = {}
    var onDelete: () -> Void = {}
    /// Enter multi-select, starting with THIS message chosen. Lives on the long-press pill
    /// rather than in a toolbar menu: selecting messages begins with a message, so the
    /// affordance belongs on one.
    var onSelect: () -> Void = {}
    var selectionMode: Bool = false
    var onSelectTap: () -> Void = {}
    /// Tap a call bubble to call back, with that call's kind (true = video).
    var onCallBack: (Bool) -> Void = { _ in }

    @State private var swipeX: CGFloat = 0
    @State private var voiceScrubbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var bodyFontSize = 16.0
    @State private var showEmojiPicker = false


    var body: some View {
        // A finished call (WhatsApp-style): its own sided, tappable bubble — NOT a centered
        // system pill, because it is an action you can repeat, not an announcement.
        if let log = message.call {
            CallLogBubble(log: log) { onCallBack(log.isVideo) }
        } else if message.kind == .system {
            // System message — centered pill (e.g. "You added Priyanshu").
            Text(message.text)
                .font(VoiidFont.rounded(11, .medium))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 5)
                .background(VoiidColor.surfaceCard.opacity(0.7))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else {
            bubble
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .groupBubbleBottom, spacing: isGroup && !message.isMine ? 2 : 6) {
            if message.isMine { Spacer(minLength: 24) }
            // Group, incoming: the sender's real profile photo beside the bubble, so you can
            // see at a glance who's texting (WhatsApp-style).
            if isGroup && !message.isMine {
                Button { showingSenderProfile = true } label: {
                    ProfileAvatarButton(photoURL: UserDirectory.shared.photoURL(message.senderId), name: message.senderName, size: 32)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(selectionMode)
                    .alignmentGuide(.groupBubbleBottom) { $0[.bottom] - 6 }
                    .accessibilityLabel("View \(message.senderName)’s profile")
            }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 0) {
                if isGroup && !message.isMine && !message.senderName.isEmpty {
                    HStack(spacing: 5) {
                        Text(message.senderName)
                            .font(VoiidFont.rounded(12, .semibold))
                            .foregroundColor(message.senderColor)
                        if let uname = UserDirectory.shared.user(message.senderId)?.username, !uname.isEmpty {
                            Text("@\(uname)")
                                .font(VoiidFont.rounded(11, .regular))
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                    }.padding(.leading, 14).padding(.bottom, 4)
                }
                Group {
                if selectionMode {
                    bubbleContent
                        .overlay { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onSelectTap) }
                } else {
                    MessageContextMenu(message: message,
                        isEnabled: !voiceScrubbing,
                        canReact: canReact,
                        myReaction: message.reactions[TokenStore.shared.userId ?? ""],
                        onForward: onForward, onMoreEmoji: { showEmojiPicker = true },
                        onReact: onReact, onReply: onReply, onCopy: onCopy,
                        onSelect: onSelect, onDelete: onDelete, onInfo: onInfo,
                        onSwipe: nativeVoiceSwipe) {
                            bubbleContent
                        }
                }
                }
                .alignmentGuide(.groupBubbleBottom) { $0[.bottom] }
                if !message.deletedForEveryone && !message.reactions.isEmpty {
                    MessageReactionBadges(reactions: message.reactions,
                        myUserId: TokenStore.shared.userId, messageId: message.id,
                        isEnabled: canReact && !selectionMode, onReact: onReact)
                }
            }
            .frame(maxWidth: 300, alignment: message.isMine ? .trailing : .leading)
            .sheet(isPresented: $showingSenderProfile) {
                GroupMemberProfileSheet(member: .init(id: message.senderId, name: message.senderName,
                                                     photoURL: UserDirectory.shared.photoURL(message.senderId)))
            }
            .sheet(isPresented: $showEmojiPicker) {
                EmojiPickerSheet(onPick: onReact)
            }
            if !message.isMine { Spacer(minLength: 24) }
        }
    }

    private var bubble: some View {
        bubbleRow
        // Swipe-to-reply
        .overlay(alignment: message.isMine ? .trailing : .leading) {
            // A chip that FILLS as the pull crosses the threshold, not a bare fading glyph.
            // The bare arrow said "something is happening"; the chip says how close you are
            // to the thing happening, and confirms the moment it will fire.
            let progress = Double(min(abs(swipeX) / 44, 1))
            let armed = abs(swipeX) > 44
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(armed ? VoiidColor.textOnAccent : VoiidColor.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(armed ? VoiidColor.accent : VoiidColor.surfaceCard))
                .scaleEffect(0.6 + 0.4 * progress)
                .opacity(progress)
                .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: armed)
                .padding(.horizontal, VoiidSpacing.md)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .offset(x: swipeX)
        .simultaneousGesture(replyGesture, including: allowsReplyGesture ? .all : .subviews)
        .transition(.opacity)
    }

    private var allowsReplyGesture: Bool {
        !selectionMode && !message.deletedForEveryone && message.kind != .voice
    }

    private var replyGesture: some Gesture {
            DragGesture(minimumDistance: 32)
                .onChanged { v in
                    guard !voiceScrubbing else { swipeX = 0; return }
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else {
                        swipeX = 0
                        return
                    }
                    // received: swipe right (+), sent: swipe left (-)
                    //
                    // DAMPED to 0.55, the reference's constant. Tracking 1:1 let the bubble
                    // run the full 80pt for 80pt of finger, which reads as the bubble having
                    // come loose. Resistance says "this moves, but it is going to spring
                    // back" — the same thing a UIScrollView says at its edge.
                    let dx = v.translation.width * 0.55
                    if message.isMine { swipeX = min(0, max(dx, -58)) }
                    else { swipeX = max(0, min(dx, 58)) }
                }
                .onEnded { value in
                    // 58pt of DAMPED travel ≈ 105pt of finger, so the threshold is a
                    // deliberate pull rather than something a scroll can trip.
                    let dx = value.translation.width * 0.55
                    let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                    let passedThreshold = message.isMine ? dx < -44 : dx > 44
                    if horizontal && passedThreshold && !voiceScrubbing { Haptics.tap(); onReply() }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9)) { swipeX = 0 }
                }
    }

    private var nativeVoiceSwipe: ((CGFloat, Bool) -> Void)? {
        guard message.kind == .voice, !message.deletedForEveryone else { return nil }
        return { offset, ended in handleVoiceSwipe(offset, ended: ended) }
    }

    private func handleVoiceSwipe(_ offset: CGFloat, ended: Bool) {
        if ended {
            if abs(offset) > 44 { Haptics.tap(); onReply() }
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9)) { swipeX = 0 }
        } else { swipeX = offset }
    }

    private var canReact: Bool {
        !isGroup && !message.deletedForEveryone && message.status != .sending && message.status != .failed
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 5) {
                // "Forwarded" tag
                if message.forwarded {
                    Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                        .font(VoiidFont.rounded(11, .regular).italic())
                        .foregroundColor(bubbleTextSecondary)
                }
                // Quoted reply
                if let rt = message.replyToText {
                    // 13/13 with an 8pt rail gap and 2pt line spacing — the reference's
                    // numbers. At 11/12 the quote read as fine print rather than as the
                    // message being answered.
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(bubbleAccent).frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            if let s = message.replyToSender, !s.isEmpty {
                                Text(s).font(VoiidFont.rounded(13, .semibold)).foregroundColor(bubbleAccent)
                            }
                            Text(rt).font(VoiidFont.rounded(13, .regular)).foregroundColor(bubbleTextSecondary).lineLimit(2)
                        }
                    }
                    .padding(8)
                    // NO `maxWidth: .infinity`. It made every bubble containing a quote
                    // inflate to the full available width, so a two-word reply became a
                    // full-width slab. The block hugs its content and the BUBBLE decides its
                    // own width, which is the reference's behaviour — it removed a Spacer
                    // here for exactly this reason.
                    .frame(alignment: .leading)
                    // A translucent white scrim reads correctly on BOTH the filled teal and
                    // the light card; `fieldFill` is a light token and vanished on teal.
                    // A DIM, not a plate. `fieldFill.opacity(0.7)` is near-solid on the
                    // received bubble and drew a hard inset panel; the reference dims the
                    // passage instead, so the quote reads as quieter text inside the same
                    // bubble rather than a second surface stacked on it.
                    .background((message.isMine ? Color.black.opacity(0.10)
                                                : Color.primary.opacity(0.06)))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                // Quoted MOMENT — the story this reply answers. Deliberately built from the
                // same parts as the quoted-message block directly above (accent rail, author
                // line in the accent, secondary body, the same translucent-white-on-teal /
                // fieldFill-on-card scrim, the same corner radius), plus a leading thumbnail,
                // so a story quote and a message quote read as two of one thing rather than as
                // two separate inventions. Without it a tapped reaction landed here as a lone
                // "❤️" with nothing saying which moment it answered.
                if let sid = message.storyQuoteId {
                    StoryQuoteView(storyId: sid,
                                   authorId: message.storyQuoteAuthorId,
                                   createdAt: message.storyQuoteAt,
                                   accent: bubbleAccent,
                                   secondary: bubbleTextSecondary,
                                   fill: message.isMine ? Color.white.opacity(0.16)
                                                        : VoiidColor.fieldFill.opacity(0.7))
                }
                if message.deletedForEveryone {
                    HStack(spacing: 5) {
                        Image(systemName: "slash.circle").font(.system(size: 13))
                        Text("This message was deleted").italic()
                    }
                    .font(VoiidFont.rounded(14, .regular)).foregroundColor(bubbleTextSecondary)
                } else if GameInvite.isInvite(message.text) {
                    // BEFORE the .text branch, deliberately. An invite IS a text message, so
                    // `kind == .text` sent it to textWithMeta — which renders the raw body and
                    // never consults GameInvite. The interception in `content` was therefore
                    // unreachable for the only messages that needed it, which is why the invite
                    // showed as `voiid:game/...` plus a wall of JSON.
                    content
                    metaRow.padding(.top, 2)
                } else if message.isStoryReaction {
                    // A tapped reaction, not prose. Set at 34pt so it reads as the gesture it
                    // was — the same emoji in 15pt body type looks like someone typed a heart
                    // by accident. `metaRow` still rides beneath it so the bubble keeps its
                    // timestamp and delivery word like every other outgoing message.
                    Text(message.text)
                        .font(.system(size: 34))
                        .padding(.vertical, 2)
                    metaRow.padding(.top, 2)
                } else if message.kind == .image {
                    content
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        styledText(message.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 236, alignment: .leading).padding(8)
                    }
                } else if message.kind == .text {
                    textWithMeta
                } else {
                    content
                    metaRow.padding(.top, 2)
                        .frame(maxWidth: message.kind == .voice ? .infinity : nil, alignment: .trailing)
                }
            }
            // 14/10, the reference's numbers. At 12/8 the text sat tight against the fill
            // and the bubbles read smaller-set than the design.
            .padding(.horizontal, message.kind == .image && !message.deletedForEveryone ? 4 : 14)
            .padding(.vertical, message.kind == .image && !message.deletedForEveryone ? 4 : 10)
            // YOUR bubble is filled peacock teal; theirs is the quiet card surface. This was
            // backwards — `isMine` drew `bubbleReceived` (white) and theirs drew `surfaceCard`
            // (also white), so the two sides were nearly indistinguishable and the eye could
            // not track its own thread down the screen. The filled side is also what carries
            // the 5.53:1 separation the palette was chosen for.
            .background(message.isMine ? VoiidColor.bubbleSent : VoiidColor.bubbleReceived)
            .clipShape(BubbleShape(isMine: message.isMine))
            // Their bubble is near-white on a near-white ground in LIGHT mode, so it needs a
            // hairline to hold its edge. Mine is filled and needs none.
            .overlay(
                message.isMine ? nil :
                    BubbleShape(isMine: false).stroke(VoiidColor.divider, lineWidth: 0.5)
            )

            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: message.kind == .text ? .combine : .contain)
            .accessibilityIdentifier("message.\(message.id).bubble")
    }

    // Match the preview's single layout: wrap the body while keeping metadata
    // anchored at the bottom. Switching layouts during hosting-controller sizing
    // can otherwise measure an inline row and render a taller stacked row.
    private var textWithMeta: some View {
        HStack(alignment: .bottom, spacing: 8) {
            styledText(message.text)
                .fixedSize(horizontal: false, vertical: true)
            metaRow
        }
    }

    /// Renders text with @mentions highlighted.
    ///
    /// Colours are BUBBLE-AWARE and set per word HERE, not by the caller. Every word carried
    /// `VoiidColor.textPrimary` — dark ink — applied INSIDE the `Text`, which beats the outer
    /// `.foregroundColor(bubbleText)` the caller was setting. So a sent message drew dark plum
    /// on the filled teal bubble: barely legible in light mode, and the actual bug reported as
    /// "text shows black in the bubble".
    ///
    /// A mention on YOUR bubble also cannot use `VoiidColor.primary` — that IS the bubble's
    /// fill, so the word would vanish entirely. It uses the on-bubble ink at full strength
    /// instead, with weight carrying the emphasis.
    private func styledText(_ text: String) -> Text {
        let base = message.isMine ? VoiidColor.textOnBubble : VoiidColor.textPrimary
        let mention = message.isMine ? VoiidColor.textOnBubble : VoiidColor.primary
        return text.split(separator: " ", omittingEmptySubsequences: false).enumerated()
            .reduce(Text("")) { acc, pair in
                let (i, word) = pair
                let space = i == 0 ? "" : " "
                let isMention = word.hasPrefix("@") && word.count > 1
                let piece = Text(space + String(word))
                    // 16pt — the reference's body size. 15 read noticeably smaller against
                    // the same bubble geometry.
                    .font(VoiidFont.rounded(bodyFontSize, isMention ? .semibold : .regular))
                    .foregroundColor(isMention ? mention : base)
                return acc + piece
            }
    }

    // MARK: - Bubble-aware colours
    //
    // YOUR bubble is filled peacock teal, so anything drawn on it must invert. Reading these
    // from the token directly would put dark-plum text on a dark-teal fill — legible in light
    // mode by luck, unreadable in dark.

    /// Body text on this bubble.
    private var bubbleText: Color {
        message.isMine ? VoiidColor.textOnBubble : VoiidColor.textPrimary
    }
    /// Secondary text (timestamps, "Forwarded", quoted body) on this bubble.
    private var bubbleTextSecondary: Color {
        message.isMine ? VoiidColor.textOnBubble.opacity(0.75) : VoiidColor.textSecondary
    }
    /// The accent used for a quoted-reply rail and its author line.
    private var bubbleAccent: Color {
        message.isMine ? VoiidColor.textOnBubble.opacity(0.9) : VoiidColor.primary
    }

    private var metaRow: some View {
        HStack(spacing: 5) {
            Text(VoiidDate.bubbleTime(message.createdAt))
                .font(VoiidFont.rounded(11, .regular))
                .foregroundColor(bubbleTextSecondary)
            if message.isMine { statusView }
        }
        .fixedSize()
    }

    /// Delivery state as a WORD — Sent · Delivered · Seen — not a tick.
    ///
    /// Ticks are a convention people have to learn, and one tick versus two is a distinction
    /// of a few pixels that colour-blind users cannot resolve at all (WhatsApp's blue-vs-grey
    /// double tick is the canonical example). A word is unambiguous at a glance, needs no
    /// legend, and reads correctly to VoiceOver without extra labelling.
    ///
    /// Shown on EVERY outgoing message, so each one reports its own true state rather than
    /// only the last one in the thread.
    @ViewBuilder private var statusView: some View {
        switch message.status {
        case .sending:
            // Still a glyph: "Sending" is transient and would make the row jump in width the
            // instant it resolved.
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundColor(bubbleTextSecondary)
        case .failed:
            // The one state that gets colour AND an icon — it is the only one the user must
            // act on, and state must never be carried by hue alone.
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9))
                Text("Failed").font(VoiidFont.rounded(10, .semibold))
            }
            .foregroundColor(VoiidColor.error)
        case .sent:
            statusLabel("Sent")
        case .delivered:
            statusLabel("Delivered")
        case .read:
            // Seen steps up in WEIGHT rather than changing colour, so the distinction survives
            // for a colour-blind user and in bright sunlight.
            Text("Seen")
                .font(VoiidFont.rounded(10.5, .bold))
                .foregroundColor(message.isMine ? VoiidColor.textOnBubble : VoiidColor.primary)
        }
    }

    private func statusLabel(_ s: String) -> some View {
        Text(s)
            .font(VoiidFont.rounded(10.5, .medium))
            .foregroundColor(bubbleTextSecondary)
    }

    private var statusLabel: String? {
        switch message.status {
        case .sending:   return "Sending…"
        case .sent:      return "Sent"
        case .delivered: return "Delivered"
        case .read:      return "Seen"
        case .failed:    return "Failed"
        }
    }

    @ViewBuilder private var content: some View {
        // A game invite is a TEXT message whose body carries a token (see GameInvite.swift).
        // Intercepted before the kind switch so both sides render the Join card rather than a
        // raw `voiid:game/...` line.
        if let invite = GameInvite.parse(message.text) {
            GameInviteBubble(message: message, invite: invite)
        } else {
            kindContent
        }
    }

    private var imageDeliveryLabel: String {
        switch message.status {
        case .sending: return "Sending"
        case .failed: return "Failed"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Seen"
        }
    }

    @ViewBuilder private var kindContent: some View {
        switch message.kind {
        case .image:
            if let ref = message.mediaRef {
                AsyncMediaImage(ref: ref, onTap: onTapImage)
                    .overlay(alignment: .bottomTrailing) {
                        Text(VoiidDate.bubbleTime(message.createdAt) + (message.isMine ? " · " + imageDeliveryLabel : ""))
                            .font(VoiidFont.rounded(11, .medium))
                            .foregroundStyle(.white).padding(12)
                            .allowsHitTesting(false)
                    }
            } else {
                // Local optimistic echo before upload completes (no ref yet).
                RoundedRectangle(cornerRadius: VoiidRadius.md)
                    .fill(VoiidColor.fieldFill)
                    .frame(width: 260, height: 220)
                    .overlay(ProgressView())
            }
        case .voice:
            AsyncVoiceNote(ref: message.mediaRef, label: message.text,
                           onOwnBubble: message.isMine,
                           onScrubbingChanged: { editing in
                               voiceScrubbing = editing
                               if editing { swipeX = 0 }
                           })
        case .poll:
            if let poll = message.poll { PollBubble(poll: poll, onVote: onVote) }
        case .location:
            // The conversation goes with it so the full-screen detail can draw EVERY sharer in
            // this chat on one map, not just the person whose bubble was tapped.
            if let ref = message.location {
                LocationPinBubble(ref: ref, conversationId: message.conversationId)
            }
            else { styledText(message.text) }
        default:
            styledText(message.text)
        }
    }
}

// MARK: - Game invite bubble (tap to join)

/// An invite to a match, in the transcript.
///
/// BOTH SIDES GET A BUTTON, and that is deliberate: the creator's board is already open, but
/// they may have closed it, and "Open" on their own invite is the only way back into a match
/// that hasn't finished. Labelling it per side keeps that honest without two code paths.
///
/// Tapping posts a notification rather than calling a closure: the board lives in the Games
/// tab's own navigation stack, so every layer between this bubble and there (list, row,
/// bubble) would otherwise grow a parameter it does nothing with. Same reasoning as the
/// group-call and story deep links.
private struct GameInviteBubble: View {
    let message: VMessage
    let invite: GameInvite.Parsed

    /// An expired invite is still a real message — it just can't be joined any more. Showing it as
    /// live would send the tapper into a match the server has already abandoned.
    private var expired: Bool { invite.meta?.isExpired == true }

    /// Who this came from, resolved locally from the AUTHENTICATED sender id.
    ///
    /// `meta.from` is written by the sender's client into the payload, so rendering it verbatim
    /// meant a modified client could attribute an invite to any name it liked, including someone
    /// else's. Attribution comes from the envelope; a name inside a payload is at most a fallback
    /// for a peer we have never seen. It stays in the wire format for older clients and for the
    /// pre-marker human line, it just no longer outranks your own address book.
    private var attributedSender: String? {
        let resolved = UserDirectory.shared.displayName(message.senderId,
                                                        fallback: invite.meta?.from)
        return resolved == "Unknown" ? nil : resolved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Artwork by NAME, the same runtime lookup the catalog cards use — so a game whose art
            // ships later needs no change here, and one without art degrades to a tinted glyph.
            ZStack {
                Rectangle().fill(VoiidColor.primary.opacity(0.10))
                if invite.slug == "ludo" {
                    LudoInviteMiniBoard()
                        .frame(width: 40, height: 40)
                } else if UIImage(named: "game_\(invite.slug)") != nil {
                    Image("game_\(invite.slug)")
                        .resizable()
                        .scaledToFill()
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.45),
                                .init(color: .black.opacity(0.55), location: 1)],
                        startPoint: .top, endPoint: .bottom)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 34))
                        .foregroundStyle(VoiidColor.primary)
                }
                if expired {
                    Color.black.opacity(0.45)
                    Text("Expired")
                        .font(VoiidFont.rounded(13, .bold))
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text("GAME INVITE")
                    .font(VoiidFont.rounded(10.5, .bold))
                    .foregroundStyle(VoiidColor.primary)
                Text(invite.meta?.game.isEmpty == false
                     ? invite.meta!.game
                     : GameInvite.preview(message.text))
                    .font(VoiidFont.rounded(16, .bold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .lineLimit(2)
                // Settings the opponent is agreeing to — overs, format, difficulty. Assembled by
                // GameInvite so both platforms describe an invite identically.
                if let details = invite.meta?.detailLine(), !details.isEmpty {
                    Text(details)
                        .font(VoiidFont.rounded(12, .medium))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                if !message.isMine, let from = attributedSender {
                    Text("from \(from)")
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }

                Button {
                    Haptics.tap()
                    NotificationCenter.default.post(
                        name: .voiidOpenGameMatch, object: nil,
                        userInfo: ["match_id": invite.matchId, "slug": invite.slug])
                } label: {
                    Text(expired ? "Invite expired"
                         : (message.isMine ? "Open lobby" : "Tap to play"))
                        .font(VoiidFont.rounded(14, .bold))
                        .foregroundStyle(expired ? VoiidColor.textSecondary
                                                 : VoiidColor.textOnPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(expired ? VoiidColor.fieldFill : VoiidColor.primary))
                }
                .disabled(expired)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 248)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct LudoInviteMiniBoard: View {
    var body: some View {
        Canvas { ctx, size in
            let u = min(size.width, size.height) / 15
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(ludoHex: 0x1A1510)))
            let r0 = CGRect(x: 0, y: 0, width: 6 * u, height: 6 * u)
            let r1 = CGRect(x: 9 * u, y: 0, width: 6 * u, height: 6 * u)
            let r2 = CGRect(x: 9 * u, y: 9 * u, width: 6 * u, height: 6 * u)
            let r3 = CGRect(x: 0, y: 9 * u, width: 6 * u, height: 6 * u)
            ctx.fill(Path(r0), with: .color(Theme.seat(0)))
            ctx.fill(Path(r1), with: .color(Theme.seat(1)))
            ctx.fill(Path(r2), with: .color(Theme.seat(2)))
            ctx.fill(Path(r3), with: .color(Theme.seat(3)))
            let centerRect = CGRect(x: 6 * u, y: 6 * u, width: 3 * u, height: 3 * u)
            ctx.fill(Path(centerRect), with: .color(Theme.brass))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Poll bubble (vote + live results)

struct PollBubble: View {
    let poll: VPoll
    var onVote: (String) -> Void
    @State private var votedOption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.system(size: 12)).foregroundColor(VoiidColor.primary)
                Text("Poll").font(VoiidFont.rounded(11, .semibold)).foregroundColor(VoiidColor.textSecondary)
            }
            Text(poll.question).font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)

            ForEach(poll.options) { opt in
                let total = max(poll.totalVotes, 1)
                let pct = CGFloat(opt.votes) / CGFloat(total)
                Button {
                    guard votedOption == nil else { return }
                    Haptics.tap(); votedOption = opt.id; onVote(opt.id)
                } label: {
                    ZStack(alignment: .leading) {
                        // result fill bar
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 10)
                                .fill(votedOption == opt.id ? VoiidColor.accent : VoiidColor.fieldFill)
                                .frame(width: votedOption != nil ? g.size.width * pct : g.size.width)
                        }
                        HStack {
                            Text(opt.text).font(VoiidFont.rounded(14, .regular)).foregroundColor(VoiidColor.textPrimary)
                            Spacer()
                            if votedOption != nil {
                                Text("\(Int(pct * 100))%").font(VoiidFont.rounded(12, .medium)).foregroundColor(VoiidColor.textSecondary)
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                    }
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Text("\(poll.totalVotes) votes").font(VoiidFont.rounded(11, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
        .frame(width: 240)
    }
}

// MARK: - Date separator pill

struct DateSeparator: View {
    let text: String
    var body: some View {
        Text(text)
            // 12/14/6 on an OPAQUE capsule — the reference's numbers. At 11pt on a 70%
            // fill the pill read as washed out, and the transcript showed through it.
            .font(VoiidFont.rounded(12, .medium))
            .foregroundColor(VoiidColor.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(VoiidColor.surfaceCard)
            .clipShape(Capsule())
            .padding(.vertical, VoiidSpacing.xs)
    }
}

// MARK: - Typing indicator bubble

struct TypingBubble: View {
    @State private var step = 0
    @State private var timer: Timer?

    /// 380ms per dot — the reference's cadence. Fast enough to read as active, slow enough
    /// that the eye can follow which dot is lit.
    private func advance() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { step = (step + 1) % 3 }
        }
    }
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    // COLOUR steps between dots rather than opacity fading across all three.
                    // A continuous opacity ramp reads as one pulsing blob; stepping the
                    // accent from dot to dot reads as three dots taking turns, which is what
                    // says "still typing".
                    Circle()
                        .fill(step == i ? VoiidColor.accent : VoiidColor.textSecondary)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(VoiidColor.bubbleReceived)
            .clipShape(BubbleShape(isMine: false))
            Spacer(minLength: 40)
        }
        .onAppear { advance() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
}

// MARK: - Bubble shape (tail on the correct side)

/// 20pt corners, with the SPEAKER-SIDE bottom corner tightened to 7 rather than squared off.
///
/// Two changes from the previous shape, both from the Voiid Ui reference:
///
///  * The speaker corner was 0 — a hard right angle. A fully square corner reads as a
///    rendering error next to three 16pt ones; tightening it to ~35% of the radius keeps the
///    bubble pointing at its sender without looking broken.
///  * `UIBezierPath(byRoundingCorners:)` draws CIRCULAR arcs. SwiftUI's `.continuous` style
///    is the squircle the rest of the system uses, and at 20pt the difference between the
///    two is visible — circular corners read harder.
struct BubbleShape: Shape {
    let isMine: Bool

    private let r: CGFloat = 20
    /// The speaker-side corner. 35% of the radius: present enough to read as a corner,
    /// tight enough to read as directional.
    private var tight: CGFloat { r * 0.35 }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: isMine ? r : tight,
            bottomTrailingRadius: isMine ? tight : r,
            topTrailingRadius: r,
            style: .continuous
        ).path(in: rect)
    }
}

// MARK: - Encrypted media rendering (fetch + decrypt on demand)

/// Local-first cache of DECRYPTED media keyed by the R2 object key. Two tiers: an in-memory
/// map for instant re-render, and an on-disk store in the app-group container so media
/// survives app restarts and renders WITHOUT the network — the WhatsApp behaviour (a photo
/// you've seen once, or one you sent, shows instantly and offline). The plaintext bytes are
/// what's cached, so the render path never re-downloads or re-decrypts after the first time.
@MainActor final class MediaCache {
    static let shared = MediaCache()
    private var images: [String: UIImage] = [:]
    private var datas: [String: Data] = [:]

    /// `<app-group>/media/`. Nil only if the entitlement is missing (then memory-only).
    private let dir: URL? = {
        guard let base = AppGroup.containerURL else { return nil }
        let d = base.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Stable, filesystem-safe filename for an R2 key (which may contain '/').
    /// The on-disk path for a cached plaintext blob.
    ///
    /// Internal rather than private because AVPlayer CANNOT read from memory — a video has
    /// to be handed a file URL, so the gallery needs the path after `setData` has written
    /// it. Images do not: they decode straight from the in-memory Data.
    func fileURL(_ key: String) -> URL? {
        guard let dir else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    func data(_ k: String) -> Data? {
        if let d = datas[k] { return d }
        guard let url = fileURL(k), let d = try? Data(contentsOf: url) else { return nil }
        datas[k] = d                          // promote disk → memory
        return d
    }

    func setData(_ d: Data, _ k: String) {
        datas[k] = d
        guard let url = fileURL(k) else { return }
        // Same protection class as the message store: readable after first unlock (so a
        // background fetch can write it) but encrypted at rest.
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func image(_ k: String) -> UIImage? {
        if let img = images[k] { return img }
        guard let d = data(k) else { return nil }
        // Rebuilt as an animation when the cached bytes are a GIF. Without this, a GIF played
        // on first receipt and then froze the next time it was drawn from cache — which is
        // the harder bug to notice, because the first view looks right.
        guard let img = AnimatedGif.image(from: d, key: k) ?? UIImage(data: d) else { return nil }
        images[k] = img                       // derive + memoize from the cached bytes
        return img
    }

    func set(_ img: UIImage, _ k: String) { images[k] = img }

    /// Drop every decrypted byte, memory AND disk. Called by `SessionTeardown` on sign-out:
    /// this cache is process-lifetime and sign-out does not restart the process, so without
    /// this the previous account's photos and voice notes stay readable behind the login
    /// screen (in memory) and on disk.
    func clear() {
        images.removeAll(); datas.removeAll()
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// An image bubble that fetches + decrypts its blob via ChatEngine on appear.
struct AsyncMediaImage: View {
    @Environment(\.displayScale) private var displayScale
    private static let width: CGFloat = 260
    private static let height: CGFloat = 220
    let ref: MediaRef
    var onTap: (UIImage) -> Void
    var fill: Bool = true
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryCount = 0
    private struct LoadID: Hashable { let ref: MediaRef; let attempt: Int; let scale: CGFloat }

    var body: some View {
        Group {
            if fill {
                ZStack {
                    VoiidColor.fieldFill
                    content
                }
                // Reserve the same space during loading, failure and success.
                .frame(width: Self.width, height: Self.height)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 65).allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else { content }
        }
        .task(id: LoadID(ref: ref, attempt: retryCount, scale: displayScale)) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Group {
                // A GIF arrives here as an animated UIImage (`images != nil`), which SwiftUI's
                // Image draws as a single still. Handing it to UIKit is what makes a sent GIF
                // actually play in the bubble instead of freezing on frame one.
                if image.images != nil {
                    AnimatedGifView(image: image,
                                    contentMode: fill ? .scaleAspectFill : .scaleAspectFit)
                } else {
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                }
            }
                .frame(width: fill ? Self.width : nil, height: fill ? Self.height : nil)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { onTap(image) }
                .overlay {
                    if ref.mime.hasPrefix("video/") {
                        Image(systemName: "play.circle.fill").font(.system(size: 44))
                            .foregroundStyle(.white).shadow(radius: 4).allowsHitTesting(false)
                    }
                }
        } else if failed {
            Button { retryCount += 1 } label: {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 24))
                    Text("Couldn't load media").font(VoiidFont.rounded(13))
                    Text("Tap to retry").font(VoiidFont.rounded(12, .medium))
                }.foregroundStyle(fill ? VoiidColor.textSecondary : .white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain)
        } else { ProgressView().tint(fill ? VoiidColor.textSecondary : .white) }
    }

    private func load() async {
        failed = false
        image = nil
        if ref.mime.hasPrefix("video/") {
            let item = ChatMediaItem(id: "bubble:" + ref.mediaUrl, chatId: "", type: .video,
                ref: ref, sentAt: .distantPast, senderId: "", senderName: nil,
                isOutgoing: false, caption: nil, durationMs: nil)
            let thumbnail = await ChatMediaThumbnails.shared.thumbnail(for: item, side: Self.width,
                                                                       displayScale: displayScale)
            guard !Task.isCancelled else { return }
            image = thumbnail
            failed = thumbnail == nil
            return
        }
        if let cached = MediaCache.shared.image(ref.mediaUrl) { image = cached; return }
        do {
            let data = try await ChatEngine.shared.fetchMedia(ref)
            try Task.checkCancellation()
            // An animated GIF first: UIImage(data:) would give back frame one and the
            // animation would be lost before it ever reached the view.
            let animated = ref.mime == "image/gif"
                ? AnimatedGif.image(from: data, key: ref.mediaUrl) : nil
            guard let decoded = animated ?? UIImage(data: data) else { failed = true; return }
            MediaCache.shared.setData(data, ref.mediaUrl)
            MediaCache.shared.set(decoded, ref.mediaUrl)
            image = decoded
        } catch {
            // A lazy row disappearing during a scroll is not a failed download.
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

// MARK: - Image viewer

/// Wraps a message id so `fullScreenCover(item:)` can drive the gallery. The old
/// `ImageWrapper` carried a decoded UIImage, which is what limited the viewer to the single
/// photo that was tapped.
struct IdWrapper: Identifiable { let id: String }

/// A video in the gallery: decrypted to a local file, then played with system controls.
///
/// AVKit's `VideoPlayer` rather than a bare AVPlayerLayer, deliberately — unlike the Clips
/// player this is a full-screen viewer where scrub, play/pause and volume are the whole
/// point, and hand-rolling transport controls to avoid AVKit's would be work for nothing.
///
/// The bytes take the SAME encrypt/decrypt path as images: fetch, cache the plaintext, then
/// hand AVPlayer a file URL. AVPlayer cannot read from memory, so the decrypted bytes must
/// land on disk — inside the app group, under the same file protection as every other
/// cached plaintext.
private struct AsyncVideoPlayer: View {
    let ref: MediaRef

    @State private var url: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let url {
                VideoPlayer(player: AVPlayer(url: url))
            } else if failed {
                VStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                    Text("Couldn't load this video")
                        .font(VoiidFont.rounded(14))
                }
                .foregroundColor(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: ref.mediaUrl) { await load() }
    }

    private func load() async {
        // `fileURL` only computes a path; it does not prove the bytes are there. Checking
        // first is what makes a second open instant instead of re-fetching.
        if let cached = MediaCache.shared.fileURL(ref.mediaUrl),
           FileManager.default.fileExists(atPath: cached.path) {
            url = cached
            return
        }
        do {
            let data = try await ChatEngine.shared.fetchMedia(ref)
            MediaCache.shared.setData(data, ref.mediaUrl)
            url = MediaCache.shared.fileURL(ref.mediaUrl)
            if url == nil { failed = true }
        } catch {
            failed = true
        }
    }
}

/// The media gallery: every image in the conversation, swipeable.
///
/// It used to show ONE decoded UIImage with a close button — no swiping between photos, no
/// zoom, no drag-to-dismiss. Opening a picture was a dead end you had to back out of before
/// you could see the next one, which is the opposite of how people actually look through a
/// chat's photos.
///
/// Built from the transcript rather than from a separate media index, so what you page
/// through is exactly what is in the conversation, in the order it was sent.
struct MediaGallery: View {
    let refs: [(id: String, ref: MediaRef)]
    let startId: String
    let onClose: () -> Void

    @State private var index: Int = 0
    /// Vertical drag for the dismiss gesture. Horizontal belongs to the pager.
    @State private var dragY: CGFloat = 0

    private var dismissProgress: CGFloat { min(1, abs(dragY) / 220) }

    var body: some View {
        ZStack {
            // Fades as you pull down, so the photo lifts off the page rather than the whole
            // screen going with it.
            Color.black.opacity(1 - Double(dismissProgress) * 0.85).ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(refs.indices, id: \.self) { i in
                    ZoomableMedia(ref: refs[i].ref)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragY)
            .scaleEffect(1 - dismissProgress * 0.12)
            .gesture(
                // minimumDistance keeps this from stealing the pager's horizontal drag; the
                // axis check does the rest, so a diagonal swipe still pages.
                DragGesture(minimumDistance: 18)
                    .onChanged { v in
                        guard abs(v.translation.height) > abs(v.translation.width) else { return }
                        dragY = v.translation.height
                    }
                    .onEnded { v in
                        // Velocity as well as distance: a quick flick dismisses without
                        // having to drag the photo a third of the way down the screen.
                        if abs(dragY) > 140 || abs(v.predictedEndTranslation.height) > 380 {
                            onClose()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                dragY = 0
                            }
                        }
                    }
            )

            VStack {
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.35)))
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // Position, only when there is more than one — "1 of 1" is noise.
                    if refs.count > 1 {
                        Text("\(index + 1) of \(refs.count)")
                            .font(VoiidFont.rounded(14, .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .monospacedDigit()
                    }
                    Spacer()
                    // Balances the close button so the counter sits centred.
                    Color.clear.frame(width: 34, height: 34)
                }
                .padding(.horizontal, VoiidSpacing.md)
                Spacer()
            }
            .opacity(1 - dismissProgress)
        }
        .statusBarHidden()
        .onAppear { index = refs.firstIndex { $0.id == startId } ?? 0 }
    }
}

/// One item in the gallery: pinch to zoom, double-tap to toggle, pan while zoomed.
private struct ZoomableMedia: View {
    let ref: MediaRef

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var isVideo: Bool { ref.mime.hasPrefix("video/") }

    var body: some View {
        Group {
            if isVideo {
                // Video plays through the existing decrypt-and-cache path; the gallery only
                // has to host it.
                AsyncVideoPlayer(ref: ref)
            } else {
                AsyncMediaImage(ref: ref, onTap: { _ in }, fill: false)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = max(1, min(5, lastScale * v)) }
                            .onEnded { _ in
                                lastScale = scale
                                // Snapping home when barely zoomed stops the image drifting
                                // slightly off-centre after every pinch.
                                if scale <= 1.02 { reset() }
                            }
                    )
                    .simultaneousGesture(
                        // Only while zoomed, or this would fight the pager's own swipe.
                        DragGesture()
                            .onChanged { v in
                                guard scale > 1 else { return }
                                offset = CGSize(width: lastOffset.width + v.translation.width,
                                                height: lastOffset.height + v.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                        }
                    }
            }
        }
    }

    private func reset() {
        scale = 1; lastScale = 1
        offset = .zero; lastOffset = .zero
    }
}
