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
import PhotosUI
import UIKit
import CryptoKit
import AVFoundation

struct ChatDetailView: View {
    let conversation: VConversation
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    /// Settings → Privacy. Observed (not just read) so flipping a toggle in the Settings
    /// sheet re-renders the presence line immediately instead of on the next open.
    @ObservedObject private var privacy = PrivacySettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var fullscreenImage: UIImage?
    @State private var showInfo = false       // group info / contact profile
    @State private var showAttach = false     // attach menu (photo / poll)
    @State private var showPollCompose = false
    @State private var showLocationCompose = false   // location share compose sheet
    @State private var pickPhoto = false
    @State private var showGifPicker = false
    /// Recording takes over the WHOLE composer row — see RecordingBar. Kept here rather than
    /// in the mic button because the bar is a sibling of the text field, not its child.
    @State private var isRecording = false
    @State private var recordSeconds: TimeInterval = 0
    @State private var recordDragX: CGFloat = 0
    @State private var replyingTo: VMessage?  // reply preview above input
    @State private var infoMessage: VMessage? // Message Info sheet
    @State private var forwardMessage: VMessage? // forward chat-picker
    @State private var deleteMessage: VMessage?   // single delete confirm
    @State private var showClearChat = false
    // Multi-select
    @State private var selectionMode = false
    @State private var selectedIDs = Set<String>()
    @State private var showBulkDelete = false
    @State private var forwardBulk = false
    @State private var activeCall: CallRequest?
    /// Set by ContactProfileView's Call / Video buttons. Placed once that screen has popped —
    /// starting a call while a navigation transition is in flight drops the CallKit UI.
    @State private var pendingCall: CallKind?
    /// REAL group members (from the server), used for @mentions and group-call member tiles.
    /// Empty for 1:1 chats. Loaded on appear — never DummyData.
    @State private var groupMembers: [VMember] = []

    var body: some View {
        VStack(spacing: 0) {
            // Multi-select has its own bar; NORMAL mode uses the NATIVE navigation bar +
            // toolbar — Apple's system back button and `chatToolbar` items. No custom chrome,
            // no forced background: iOS renders it as Liquid Glass on 26 and its own native
            // bar on 18 (the native fallback), automatically.
            if selectionMode { selectionHeader }
            // "You are sharing your location" — pinned at the top of the chat, one-tap Stop.
            LocationBanner(conversationId: conversation.id)
            messageList
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
                        role: m.isAdmin ? .admin : .member, statusText: nil, isYou: m.userId == myId)
            }
        }
        .task(id: conversation.id) {
            // Poll the conversation while it's open — fetch+decrypt new messages, send
            // receipts, refresh presence — so delivery doesn't depend on the WS push
            // (which can be silently dropped). Every 4s.
            while !Task.isCancelled {
                await chat.syncMessages(conversation)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .onDisappear {
            // NOTE: do NOT reset hideTabBar here. Pushing the contact/group profile fires
            // this onDisappear, and if it ran AFTER the profile's onAppear (which hides the
            // bar) the footer would flash back on over the profile. The bar is instead
            // restored solely by each ROOT tab's onAppear (hideTabBar = false), so returning
            // to Chats/Clips/etc. shows it and every detail screen keeps it hidden.
            // Settings → Privacy → "Send typing indicators". With it off we never sent a
            // start frame, so there is nothing to stop.
            if privacy.sendTypingIndicators, let peer = livePeerUserId {
                WebSocketClient.shared.sendTyping(conversationId: conversation.id, recipientIds: [peer], isStart: false)
            }
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
            if conversation.type == .group {
                GroupInfoView(conversation: conversation)
            } else {
                ContactProfileView(conversation: conversation, pendingCall: $pendingCall)
            }
        }
        .sheet(isPresented: $showGifPicker) {
            GifPickerSheet { data in
                // A GIF is ORDINARY E2EE MEDIA once it reaches here — same encrypt-and-upload
                // path as a photo. The recipient never contacts Tenor, so no third party
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
                onSendPin: { label in sendLocationPin(label: label) },
                onStartLive: { duration in startLiveShare(duration: duration) })
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $infoMessage) { msg in
            MessageInfoSheet(message: msg, isGroup: conversation.type == .group)
                .presentationDetents([.medium])
        }
        .sheet(item: $forwardMessage) { msg in
            ForwardSheet(message: msg) { targets in
                chat.forward(msg, to: targets)
            }
        }
        // Single message delete — confirmation modal
        .confirmationDialog("Delete message?", isPresented: Binding(
            get: { deleteMessage != nil }, set: { if !$0 { deleteMessage = nil } }),
            titleVisibility: .visible) {
            if let m = deleteMessage {
                if m.isMine {
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
        // Clear chat — alert modal
        .alert("Clear this chat?", isPresented: $showClearChat) {
            Button("Clear chat", role: .destructive) { chat.clearChat(conversation.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("All messages will be removed from this chat.") }
        // Bulk delete — alert modal
        .alert("Delete \(selectedIDs.count) message\(selectedIDs.count == 1 ? "" : "s")?", isPresented: $showBulkDelete) {
            Button("Delete", role: .destructive) {
                for id in selectedIDs { chat.deleteMessage(id, in: conversation.id, forEveryone: false) }
                exitSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This will delete the selected messages.") }
        // Bulk forward
        .sheet(isPresented: $forwardBulk) {
            ForwardSheet(message: chat.messages(for: conversation.id).first(where: { selectedIDs.contains($0.id) }) ?? VMessage(id: "", conversationId: "", senderId: "", text: "", createdAt: .now)) { targets in
                let msgs = chat.messages(for: conversation.id).filter { selectedIDs.contains($0.id) }
                for m in msgs { chat.forward(m, to: targets) }
                exitSelection()
            }
        }
        .fullScreenCover(item: Binding(
            get: { fullscreenImage.map { ImageWrapper(image: $0) } },
            set: { fullscreenImage = $0?.image })
        ) { wrapper in
            ImageViewer(image: wrapper.image) { fullscreenImage = nil }
        }
        .fullScreenCover(item: $activeCall) { CallScreen(request: $0) }
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
    private func sendLocationPin(label: String?) {
        Task {
            let peer = isGroupChat ? nil : await resolvePeer()
            guard isGroupChat || peer != nil else { return }
            LocationShareEngine.shared.sendPin(conversationId: conversation.id, isGroup: isGroupChat,
                                               peerUserId: peer, label: label) { _ in
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
            Button { Haptics.tap(); showInfo = true } label: {
                HStack(spacing: VoiidSpacing.sm) {
                    ProfileAvatarButton(photoURL: conversation.photoURL,
                                        name: conversation.title, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title)
                            .font(VoiidFont.rounded(17, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .lineLimit(1)
                        if let presenceText {
                            Text(presenceText)
                                .font(VoiidFont.rounded(11, .regular))
                                .foregroundColor(chat.typingConversations.contains(conversation.id) ? VoiidColor.primary : VoiidColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(conversation.type == .group ? "Group info" : "Contact profile")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { Haptics.tap(); startCall(.voice) } label: {
                Image(systemName: "phone.fill")
            }
            .accessibilityLabel("Voice call")
            Button { Haptics.tap(); startCall(.video) } label: {
                Image(systemName: "video.fill")
            }
            .accessibilityLabel("Video call")
            Menu {
                Button { showInfo = true } label: {
                    Label(conversation.type == .group ? "Group info" : "View profile", systemImage: "info.circle")
                }
                Button { withAnimation { selectionMode = true } } label: {
                    Label("Select messages", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) { showClearChat = true } label: {
                    Label("Clear chat", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private var selectionHeader: some View {
        HStack(spacing: VoiidSpacing.md) {
            Button { exitSelection() } label: {
                Text("Cancel").font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.primary)
            }
            Text("\(selectedIDs.count) selected")
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
        return "last seen recently"
    }

    // MARK: message list with date separators + auto-scroll

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: VoiidSpacing.sm) {
                    ForEach(groupedByDay, id: \.0) { day, msgs in
                        DateSeparator(text: day)
                        ForEach(msgs) { msg in
                            messageRow(msg).id(msg.id)
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
                .padding(.top, VoiidSpacing.xl)
                .padding(.bottom, VoiidSpacing.md)
            }
            .onChange(of: chat.messages(for: conversation.id).count) { _, _ in
                withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
            }
            .onChange(of: chat.typingConversations) { _, _ in
                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(lastID, anchor: .bottom) }
        }
    }

    // Extracted per-message row (keeps messageList small enough for the type-checker).
    @ViewBuilder private func messageRow(_ msg: VMessage) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            if selectionMode {
                Image(systemName: selectedIDs.contains(msg.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(selectedIDs.contains(msg.id) ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.5))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            MessageBubble(message: msg,
                          isGroup: conversation.type == .group,
                          isLastMine: msg.id == lastMineID,
                          onTapImage: { img in fullscreenImage = img },
                          onVote: { optId in chat.vote(messageId: msg.id, optionId: optId, in: conversation.id) },
                          onReply: { withAnimation { replyingTo = msg } },
                          onForward: { forwardMessage = msg },
                          onReact: { e in chat.react(messageId: msg.id, emoji: e, in: conversation.id) },
                          onCopy: { UIPasteboard.general.string = msg.text },
                          onInfo: { infoMessage = msg },
                          onDelete: { deleteMessage = msg },
                          selectionMode: selectionMode,
                          onSelectTap: { toggleSelect(msg.id) },
                          // Tap a call bubble to call back with the SAME kind.
                          onCallBack: { isVideo in startCall(isVideo ? .video : .voice) })
        }
    }

    private var lastID: String { chat.messages(for: conversation.id).last?.id ?? "" }
    private var lastMineID: String { chat.messages(for: conversation.id).last(where: { $0.isMine })?.id ?? "" }

    /// Group messages by calendar day for separators.
    private var groupedByDay: [(String, [VMessage])] {
        let msgs = chat.messages(for: conversation.id)
        let groups = Dictionary(grouping: msgs) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted().map { (VoiidDate.separator($0), groups[$0]!.sorted { $0.createdAt < $1.createdAt }) }
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
    private var inputRow: some View {
        Group {
            if isRecording {
                // Recording REPLACES the row. It is a modal state that needs the full width —
                // trying to fit a live waveform, a timer and a cancel affordance beside the
                // text field is what made the old inline version look cramped and broken.
                // The mic button stays mounted underneath (opacity 0) so its gesture keeps
                // receiving the drag; unmounting it would end the recording on the first move.
                ZStack(alignment: .trailing) {
                    RecordingBar(seconds: recordSeconds, dragX: recordDragX) {
                        withAnimation { isRecording = false }
                    }
                    micGestureHost.opacity(0.001)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(VoiidColor.divider.opacity(0.6).frame(height: 0.5), alignment: .top)
                .transition(.opacity)
            } else {
                normalInputRow
            }
        }
    }

    /// The mic, mounted invisibly under the recording bar so its long-press/drag gesture
    /// survives the row swapping out from under it.
    private var micGestureHost: some View {
        VoiceRecordButton(
            onSend: { data, duration in
                chat.sendMedia(data, mime: "audio/m4a",
                               caption: "Voice · \(Int(duration))s", to: conversation.id)
            },
            onRecordingChange: { active in
                withAnimation(.easeOut(duration: 0.18)) { isRecording = active }
                if !active { recordSeconds = 0; recordDragX = 0 }
            },
            onDrag: { recordDragX = $0 },
            onTick: { recordSeconds = $0 })
    }

    private var normalInputRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // Attach — photo / location / poll.
            Menu {
                Button { pickPhoto = true } label: { Label("Photo", systemImage: "photo") }
                Button { showLocationCompose = true } label: { Label("Location", systemImage: "location") }
                if conversation.type == .group {
                    Button { showPollCompose = true } label: { Label("Poll", systemImage: "chart.bar") }
                }
            } label: {
                // A tinted DISC, matching the mic and send buttons. These two were bare
                // glyphs sitting beside two filled circles, which is what made the row look
                // unbalanced — four actions, two of them shapes and two of them floating ink.
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(VoiidColor.textSecondary.opacity(0.10))
                    .clipShape(Circle())
            }
            .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) {
                        // Encrypt + upload the real bytes (E2EE), not a placeholder.
                        chat.sendMedia(data, mime: "image/jpeg", to: conversation.id)
                    }
                    photoItem = nil
                }
            }

            // GIF. A first-class button rather than buried in the attach menu — it is the one
            // people reach for most, and a menu tap between them and it is friction for
            // nothing.
            Button {
                Haptics.tap()
                showGifPicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(VoiidColor.textSecondary.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            TextField("Message", text: $draft, axis: .vertical)
                .font(VoiidFont.rounded(16, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                // Grows to 6 lines, then SCROLLS INTERNALLY instead of pushing the composer up
                // the screen. `lineLimit(1...5)` alone caps the visible height but leaves the
                // field scrollless, so a long paragraph became unreadable — you could not see
                // what you had typed above the cap.
                .lineLimit(1...6)
                .fixedSize(horizontal: false, vertical: false)
                .frame(minHeight: 20)
                // The FIELD carries the pill, not the whole row. Putting the background on
                // the row meant a 6-line paragraph inflated the entire container into a tall
                // blob with the buttons stranded in its bottom corners — visible in the
                // screenshot. Now the pill grows with the text and the buttons sit beside it,
                // fixed, exactly as they do when the field is one line.
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(VoiidColor.fieldBorder, lineWidth: 1)
                )
                .onChange(of: draft) { _, newValue in
                    // Settings → Privacy → "Send typing indicators".
                    guard privacy.sendTypingIndicators, let peer = livePeerUserId else { return }
                    WebSocketClient.shared.sendTyping(conversationId: conversation.id,
                                                      recipientIds: [peer],
                                                      isStart: !newValue.isEmpty)
                }

            if hasText {
                Button {
                    Haptics.tap()
                    chat.send(draft.trimmingCharacters(in: .whitespaces), to: conversation.id, replyTo: replyingTo)
                    draft = ""
                    withAnimation { replyingTo = nil }
                } label: {
                    // A FILLED circle: send is the primary action here and should look like a
                    // button, not a loose glyph with no tap target to aim at.
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(VoiidColor.textOnPrimary)
                        .frame(width: 32, height: 32)
                        .background(VoiidColor.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                VoiceRecordButton(
                    onSend: { data, duration in
                        chat.sendMedia(data, mime: "audio/m4a",
                                       caption: "Voice · \(Int(duration))s", to: conversation.id)
                    },
                    onRecordingChange: { active in
                        withAnimation(.easeOut(duration: 0.18)) { isRecording = active }
                        if !active { recordSeconds = 0; recordDragX = 0 }
                    },
                    onDrag: { recordDragX = $0 },
                    onTick: { recordSeconds = $0 })
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // `.bar` material + a hairline, so the transcript blurs UNDER the composer as it
        // scrolls instead of sliding behind a flat opaque slab. Same treatment as the tab bar,
        // which is what makes the two read as one piece of chrome.
        .background(.bar)
        .overlay(VoiidColor.divider.opacity(0.6).frame(height: 0.5), alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
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
        HStack {
            if !log.incoming { Spacer(minLength: 56) }
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
                    Spacer(minLength: 8)
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
            if log.incoming { Spacer(minLength: 56) }
        }
        .padding(.vertical, 2)
    }
}

struct MessageBubble: View {
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
    var selectionMode: Bool = false
    var onSelectTap: () -> Void = {}
    /// Tap a call bubble to call back, with that call's kind (true = video).
    var onCallBack: (Bool) -> Void = { _ in }

    @State private var swipeX: CGFloat = 0
    @State private var showReactions = false
    @State private var showEmojiPicker = false

    static let reactionSet = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

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

    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isMine { Spacer(minLength: 56) }
            // Group, incoming: the sender's real profile photo beside the bubble, so you can
            // see at a glance who's texting (WhatsApp-style).
            if isGroup && !message.isMine {
                ProfileAvatarButton(photoURL: UserDirectory.shared.photoURL(message.senderId),
                                    name: message.senderName, size: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                // "Forwarded" tag
                if message.forwarded {
                    Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                        .font(VoiidFont.rounded(11, .regular).italic())
                        .foregroundColor(bubbleTextSecondary)
                }
                // Quoted reply
                if let rt = message.replyToText {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(bubbleAccent).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            if let s = message.replyToSender, !s.isEmpty {
                                Text(s).font(VoiidFont.rounded(11, .semibold)).foregroundColor(bubbleAccent)
                            }
                            Text(rt).font(VoiidFont.rounded(12, .regular)).foregroundColor(bubbleTextSecondary).lineLimit(2)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A translucent white scrim reads correctly on BOTH the filled teal and
                    // the light card; `fieldFill` is a light token and vanished on teal.
                    .background((message.isMine ? Color.white.opacity(0.16)
                                                : VoiidColor.fieldFill.opacity(0.7)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                // Sender identity (group, incoming only): the saved name (or phone) coloured
                // per sender, with the @username in a lighter tone so you know exactly who's
                // texting who.
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
                    }
                }
                if message.deletedForEveryone {
                    HStack(spacing: 5) {
                        Image(systemName: "slash.circle").font(.system(size: 13))
                        Text("This message was deleted").italic()
                    }
                    .font(VoiidFont.rounded(14, .regular)).foregroundColor(bubbleTextSecondary)
                } else if message.kind == .text {
                    textWithMeta
                } else {
                    content
                    metaRow.padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
            .overlay(alignment: message.isMine ? .bottomLeading : .bottomTrailing) {
                if let r = message.reaction {
                    Text(r).font(.system(size: 15))
                        .padding(3).background(VoiidColor.background).clipShape(Circle())
                        .overlay(Circle().stroke(VoiidColor.divider.opacity(0.5), lineWidth: 0.5))
                        .offset(x: message.isMine ? -8 : 8, y: 10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // In selection mode, a tap selects; otherwise long-press opens the reaction/actions pill.
            .onTapGesture { if selectionMode { onSelectTap() } }
            .onLongPressGesture(minimumDuration: 0.3) {
                guard !selectionMode else { return }
                Haptics.rigid(); showReactions = true
            }
            .popover(isPresented: $showReactions, arrowEdge: .top) {
                VStack(spacing: 8) {
                    // reaction row + "+" for the full emoji picker
                    HStack(spacing: 8) {
                        ForEach(Self.reactionSet, id: \.self) { e in
                            Button { onReact(e); showReactions = false } label: {
                                Text(e).font(.system(size: 28))
                            }
                            .buttonStyle(BouncyEmojiStyle())
                        }
                        Button {
                            showReactions = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showEmojiPicker = true }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(VoiidColor.textSecondary)
                                .frame(width: 34, height: 34)
                                .background(VoiidColor.fieldFill).clipShape(Circle())
                        }
                    }
                    Divider()
                    // actions
                    HStack(spacing: 0) {
                        actionBtn("Reply", "arrowshape.turn.up.left") { showReactions = false; onReply() }
                        actionBtn("Forward", "arrowshape.turn.up.right") { showReactions = false; onForward() }
                        actionBtn("Copy", "doc.on.doc") { showReactions = false; onCopy() }
                        if message.isMine { actionBtn("Info", "info.circle") { showReactions = false; onInfo() } }
                        actionBtn("Delete", "trash", tint: VoiidColor.error) { showReactions = false; onDelete() }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showEmojiPicker) {
                EmojiPickerSheet { e in onReact(e) }
            }
            if !message.isMine { Spacer(minLength: 56) }
        }
        .padding(.vertical, message.reaction != nil ? 8 : 1)
        // Swipe-to-reply
        .overlay(alignment: message.isMine ? .trailing : .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundColor(VoiidColor.primary)
                .opacity(Double(min(abs(swipeX) / 60, 1)))
                .padding(.horizontal, VoiidSpacing.lg)
        }
        .offset(x: swipeX)
        .gesture(selectionMode ? nil :
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    // received: swipe right (+), sent: swipe left (-)
                    let dx = v.translation.width
                    if message.isMine { swipeX = min(0, max(dx, -80)) }
                    else { swipeX = max(0, min(dx, 80)) }
                }
                .onEnded { _ in
                    if abs(swipeX) > 50 { Haptics.tap(); onReply() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { swipeX = 0 }
                }
        )
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9, anchor: message.isMine ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
            removal: .opacity))
    }

    private func actionBtn(_ title: String, _ icon: String, tint: Color = VoiidColor.primary, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(tint)
                Text(title).font(VoiidFont.rounded(11, .regular)).foregroundColor(VoiidColor.textPrimary)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
    }

    // Text bubble: message + (time · tick) flowing at the end, compact like WhatsApp.
    private var textWithMeta: some View {
        HStack(alignment: .bottom, spacing: 8) {
            styledText(message.text)
                .foregroundColor(bubbleText)
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
                    .font(VoiidFont.rounded(15, isMention ? .semibold : .regular))
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
                .font(VoiidFont.rounded(10, .regular))
                .foregroundColor(bubbleTextSecondary)
            if message.isMine { statusView }
        }
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
                .font(VoiidFont.rounded(10, .bold))
                .foregroundColor(message.isMine ? VoiidColor.textOnBubble : VoiidColor.primary)
        }
    }

    private func statusLabel(_ s: String) -> some View {
        Text(s)
            .font(VoiidFont.rounded(10, .medium))
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
        switch message.kind {
        case .image:
            if let ref = message.mediaRef {
                AsyncMediaImage(ref: ref, onTap: onTapImage)
            } else {
                // Local optimistic echo before upload completes (no ref yet).
                RoundedRectangle(cornerRadius: VoiidRadius.md)
                    .fill(VoiidColor.accent.opacity(0.4))
                    .frame(width: 200, height: 200)
                    .overlay(ProgressView())
            }
        case .voice:
            AsyncVoiceNote(ref: message.mediaRef, label: message.text)
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
            .font(VoiidFont.rounded(11, .medium))
            .foregroundColor(VoiidColor.textSecondary)
            .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 4)
            .background(VoiidColor.surfaceCard.opacity(0.7))
            .clipShape(Capsule())
            .padding(.vertical, VoiidSpacing.sm)
    }
}

// MARK: - Typing indicator bubble

struct TypingBubble: View {
    @State private var phase = 0.0
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(VoiidColor.textSecondary)
                        .frame(width: 7, height: 7)
                        .opacity(phase == Double(i) ? 1 : 0.3)
                }
            }
            .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 12)
            .background(VoiidColor.bubbleReceived)
            .clipShape(BubbleShape(isMine: false))
            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) { phase = 2 }
        }
    }
}

// MARK: - Bubble shape (tail on the correct side)

struct BubbleShape: Shape {
    let isMine: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16
        let corners: UIRectCorner = isMine
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        return Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: r, height: r)).cgPath)
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
    private func fileURL(_ key: String) -> URL? {
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
        guard let d = data(k), let img = UIImage(data: d) else { return nil }
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
    let ref: MediaRef
    var onTap: (UIImage) -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 220, height: 220).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))
                    .onTapGesture { onTap(image) }
            } else {
                RoundedRectangle(cornerRadius: VoiidRadius.md)
                    .fill(VoiidColor.accent.opacity(0.3))
                    .frame(width: 220, height: 220)
                    .overlay {
                        if failed { Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundColor(VoiidColor.primary) }
                        else { ProgressView() }
                    }
            }
        }
        .task(id: ref.mediaUrl) { await load() }
    }

    private func load() async {
        // Local-first: memory → disk → (only then) network. Offline, a photo seen once or
        // one you sent renders straight from disk with no spinner.
        if let cached = MediaCache.shared.image(ref.mediaUrl) { image = cached; return }
        do {
            let data = try await ChatEngine.shared.fetchMedia(ref)
            MediaCache.shared.setData(data, ref.mediaUrl)          // persist the plaintext bytes
            if let ui = UIImage(data: data) { MediaCache.shared.set(ui, ref.mediaUrl); image = ui }
            else { failed = true }
        } catch { failed = true }
    }
}

/// A voice-note bubble that fetches + decrypts its audio and plays it back.
struct AsyncVoiceNote: View {
    let ref: MediaRef?
    let label: String
    @State private var data: Data?
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30)).foregroundColor(VoiidColor.primary)
            }
            .buttonStyle(.plain)
            .disabled(data == nil)
            HStack(spacing: 2) {
                ForEach(0..<18, id: \.self) { i in
                    Capsule().fill(VoiidColor.primary.opacity(0.5))
                        .frame(width: 2.5, height: CGFloat(6 + (i * 7) % 18))
                }
            }
            if data == nil { ProgressView().scaleEffect(0.7) }
        }
        .frame(minWidth: 160)
        .task(id: ref?.mediaUrl) { await load() }
    }

    private func load() async {
        guard let ref else { return }
        if let cached = MediaCache.shared.data(ref.mediaUrl) { data = cached; return }
        if let d = try? await ChatEngine.shared.fetchMedia(ref) {
            MediaCache.shared.setData(d, ref.mediaUrl); data = d
        }
    }

    private func toggle() {
        if playing { player?.pause(); playing = false; return }
        guard let data else { return }
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(data: data)
        }
        player?.play(); playing = true
        // Reset the button when playback finishes.
        let dur = player?.duration ?? 0
        if dur > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + dur) { playing = false }
        }
    }
}

// MARK: - Image viewer

struct ImageWrapper: Identifiable { let id = UUID(); let image: UIImage }

struct ImageViewer: View {
    let image: UIImage
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
            VStack { HStack { Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.title2).foregroundColor(.white).padding() }
            }; Spacer() }
        }
    }
}
