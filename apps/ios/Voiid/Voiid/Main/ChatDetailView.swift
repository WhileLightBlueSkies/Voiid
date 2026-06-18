//
//  ChatDetailView.swift
//  Voiid
//
//  1:1 / group chat. Full experience on dummy data:
//   • bubbles: sent = light pink (#FCF4F8), received = white (#FFFFFF)
//   • refined receipts: tap a bubble for its time; Sent/Delivered/Read only under last sent msg
//   • date separators (Today / Yesterday / date) + typing indicator
//   • voice notes (record + send + playback), images (pick + send + fullscreen)
//   • no bottom tab bar here (hidden via session.hideTabBar)
//

import SwiftUI
import PhotosUI
import UIKit

struct ChatDetailView: View {
    let conversation: VConversation
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var fullscreenImage: UIImage?
    @State private var showInfo = false       // group info / contact profile
    @State private var showAttach = false     // attach menu (photo / poll)
    @State private var showPollCompose = false
    @State private var pickPhoto = false
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

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            inputBar
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Hide the bottom tab bar while a chat is open; restore on leave.
        .onAppear {
            session.hideTabBar = true
            chat.openConversation(conversation)   // load cached + sync (fetch+decrypt) real messages
        }
        .onDisappear {
            session.hideTabBar = false
            if let peer = livePeerUserId {
                WebSocketClient.shared.sendTyping(conversationId: conversation.id, recipientIds: [peer], isStart: false)
            }
        }
        .navigationDestination(isPresented: $showInfo) {
            if conversation.type == .group {
                GroupInfoView(conversation: conversation)
            } else {
                ContactProfileView(conversation: conversation)
            }
        }
        .sheet(isPresented: $showPollCompose) {
            PollComposeSheet { q, opts in
                chat.sendPoll(q, options: opts, to: conversation.id)
            }
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
        activeCall = CallRequest(
            title: conversation.title,
            isGroup: conversation.type == .group,
            members: conversation.type == .group ? DummyData.groupMembers : [],
            photoName: conversation.photoName,
            kind: kind)
    }

    // MARK: header — normal, or selection bar in multi-select

    @ViewBuilder private var header: some View {
        if selectionMode { selectionHeader } else { normalHeader }
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

    private var normalHeader: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            Button {
                Haptics.tap(); showInfo = true
            } label: {
                HStack(spacing: VoiidSpacing.sm) {
                    VoiidAvatar(size: 36, imageName: conversation.photoName)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title)
                            .font(VoiidFont.rounded(17, .semibold)).foregroundColor(VoiidColor.textPrimary)
                        Text(presenceText)
                            .font(VoiidFont.rounded(11, .regular))
                            .foregroundColor(chat.typingConversations.contains(conversation.id) ? VoiidColor.primary : VoiidColor.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: VoiidSpacing.lg) {
                Button { Haptics.tap(); startCall(.voice) } label: {
                    Image(systemName: "phone.fill").font(.system(size: 18)).foregroundColor(VoiidColor.textPrimary)
                }
                Button { Haptics.tap(); startCall(.video) } label: {
                    Image(systemName: "video.fill").font(.system(size: 19)).foregroundColor(VoiidColor.textPrimary)
                }
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
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundColor(VoiidColor.textPrimary)
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(VoiidColor.background)
    }

    /// Peer user_id read from the live store (resolved lazily after open), not the
    /// value-copied `conversation` which never updates.
    private var livePeerUserId: String? {
        chat.directConversations.first(where: { $0.id == conversation.id })?.peerUserId ?? conversation.peerUserId
    }

    private var presenceText: String {
        if chat.typingConversations.contains(conversation.id) { return "typing…" }
        if conversation.type == .group { return "\(conversation.memberCount) members" }
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
                .padding(.vertical, VoiidSpacing.md)
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
                          onSelectTap: { toggleSelect(msg.id) })
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
        return DummyData.groupMembers.filter { !$0.isYou &&
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

    private var inputRow: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Menu {
                Button { pickPhoto = true } label: { Label("Photo", systemImage: "photo") }
                if conversation.type == .group {
                    Button { showPollCompose = true } label: { Label("Poll", systemImage: "chart.bar") }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) {
                        chat.send("📷 Photo", kind: .image, to: conversation.id)
                        photoItem = nil; _ = data
                    }
                }
            }

            TextField("", text: $draft, axis: .vertical)
                .font(VoiidFont.rounded(16, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1...5)
                .padding(.horizontal, VoiidSpacing.md)
                .frame(minHeight: 46)
                .onChange(of: draft) { _, newValue in
                    guard let peer = livePeerUserId else { return }
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
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20)).foregroundColor(VoiidColor.primary)
                        .padding(.trailing, VoiidSpacing.sm)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                VoiceRecordButton { duration in
                    chat.send("🎤 Voice message · \(Int(duration))s", kind: .voice, to: conversation.id)
                }
                .padding(.trailing, VoiidSpacing.sm)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, VoiidSpacing.xs)
        .padding(.leading, VoiidSpacing.sm)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.pill).stroke(VoiidColor.fieldBorder, lineWidth: 1))
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.sm)
        .background(VoiidColor.background)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
    }
}

// MARK: - Message bubble with ticks + timestamp

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

    @State private var swipeX: CGFloat = 0
    @State private var showReactions = false
    @State private var showEmojiPicker = false

    static let reactionSet = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        // System message — centered pill (e.g. "You added Priyanshu").
        if message.kind == .system {
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
        HStack {
            if message.isMine { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 3) {
                // "Forwarded" tag
                if message.forwarded {
                    Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                        .font(VoiidFont.rounded(11, .regular).italic())
                        .foregroundColor(VoiidColor.textSecondary)
                }
                // Quoted reply
                if let rt = message.replyToText {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(VoiidColor.primary).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            if let s = message.replyToSender, !s.isEmpty {
                                Text(s).font(VoiidFont.rounded(11, .semibold)).foregroundColor(VoiidColor.primary)
                            }
                            Text(rt).font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary).lineLimit(2)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VoiidColor.fieldFill.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                // Sender name (group, incoming only) — colored per sender
                if isGroup && !message.isMine && !message.senderName.isEmpty {
                    Text(message.senderName)
                        .font(VoiidFont.rounded(12, .semibold))
                        .foregroundColor(message.senderColor)
                }
                if message.deletedForEveryone {
                    HStack(spacing: 5) {
                        Image(systemName: "slash.circle").font(.system(size: 13))
                        Text("This message was deleted").italic()
                    }
                    .font(VoiidFont.rounded(14, .regular)).foregroundColor(VoiidColor.textSecondary)
                } else if message.kind == .text {
                    textWithMeta
                } else {
                    content
                    metaRow.padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(message.isMine ? VoiidColor.bubbleReceived : VoiidColor.surfaceCard)
            .clipShape(BubbleShape(isMine: message.isMine))
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
        HStack(alignment: .bottom, spacing: 6) {
            styledText(message.text)
            metaRow
        }
    }

    /// Renders text with @mentions highlighted in the brand primary color.
    private func styledText(_ text: String) -> Text {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().reduce(Text("")) { acc, pair in
            let (i, word) = pair
            let space = i == 0 ? "" : " "
            let isMention = word.hasPrefix("@") && word.count > 1
            let piece = Text(space + String(word))
                .font(VoiidFont.rounded(15, isMention ? .semibold : .regular))
                .foregroundColor(isMention ? VoiidColor.primary : VoiidColor.textPrimary)
            return acc + piece
        }
    }

    private var metaRow: some View {
        HStack(spacing: 3) {
            Text(VoiidDate.bubbleTime(message.createdAt))
                .font(VoiidFont.rounded(10, .regular))
                .foregroundColor(VoiidColor.textSecondary.opacity(0.8))
            if message.isMine { tick }
        }
    }

    @ViewBuilder private var tick: some View {
        switch message.status {
        case .sending: Image(systemName: "clock").font(.system(size: 9)).foregroundColor(VoiidColor.textSecondary)
        case .sent:    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundColor(VoiidColor.textSecondary)
        case .delivered: doubleTick(VoiidColor.textSecondary)
        case .read:    doubleTick(VoiidColor.primary)
        case .failed:  Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundColor(VoiidColor.error)
        }
    }
    private func doubleTick(_ c: Color) -> some View {
        ZStack {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).offset(x: -2.5)
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).offset(x: 1.5)
        }.foregroundColor(c)
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .image:
            RoundedRectangle(cornerRadius: VoiidRadius.md)
                .fill(VoiidColor.accent.opacity(0.4))
                .frame(width: 200, height: 200)
                .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(VoiidColor.primary))
        case .voice:
            VoiceNotePlayer(label: message.text)
        case .poll:
            if let poll = message.poll { PollBubble(poll: poll, onVote: onVote) }
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
