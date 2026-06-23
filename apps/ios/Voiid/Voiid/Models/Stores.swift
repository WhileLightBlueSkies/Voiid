//
//  Stores.swift
//  Voiid
//
//  Local, in-memory app state (NO network, NO crypto — dummy experience build).
//  Everything is interactive: sending a message appends it, marks it sent→delivered→read
//  on timers, and simulates a reply, so the app *feels* real end-to-end on a device.
//

import SwiftUI
import Combine

// MARK: - Session / onboarding

@MainActor
final class AppSession: ObservableObject {
    enum Route { case onboarding, main }
    @Published var route: Route
    @Published var profile = DummyData.me
    /// Hides the bottom tab bar when a full-screen child (e.g. a chat) is open.
    @Published var hideTabBar = false

    private let auth = AuthService.shared

    init() {
        // Resume straight to the app if we already hold a valid session token.
        route = AuthService.shared.isAuthenticated ? .main : .onboarding
    }

    /// The authenticated user's id (our backend id), once logged in.
    var userId: String? { auth.userId }

    /// Called at the end of onboarding once a real session token exists
    /// (onboarding logs in via AuthService before calling this).
    func completeOnboarding() {
        withAnimation(.easeInOut) { route = .main }
    }

    func signOut() {
        auth.logout()
        withAnimation(.easeInOut) { route = .onboarding }
    }
}

// MARK: - Chat store (the heart of the "feels real" experience)

@MainActor
final class ChatStore: ObservableObject {
    // REAL backend data — starts empty, loaded via `loadConversations()`. A new
    // account shows an empty list, which confirms we're reading the live server
    // (not mock). Message content is still E2EE/not-yet-decrypted (placeholder).
    @Published var directConversations: [VConversation] = []
    @Published var groupConversations: [VConversation] = []
    @Published var messagesByConversation: [String: [VMessage]] = [:]
    @Published var typingConversations: Set<String> = []
    @Published var loadError: String?

    /// Fetch real conversations from the backend. Call after login / on appear.
    /// Also installs the realtime (WebSocket) handlers once.
    func loadConversations() async {
        startRealtime()
        do {
            let convs = try await ChatService.shared.fetchConversations()
            directConversations = convs.filter { $0.type == .direct }
            groupConversations = convs.filter { $0.type == .group }
            // Show any locally-cached (already-decrypted) messages immediately.
            for c in convs { refresh(c.id) }
            loadError = nil
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load chats."
        }
    }

    /// Messages currently held for a conversation (decrypted, from the local store).
    /// No dummy seeding — a chat with no decrypted messages shows empty.
    func messages(for id: String) -> [VMessage] {
        messagesByConversation[id] ?? []
    }

    /// Start (or reopen) a 1:1 chat with a discovered contact. Creates the
    /// conversation server-side (idempotent), inserts it locally, and returns it
    /// so the caller can navigate into ChatDetail.
    func startDirectChat(with contact: VContact) async -> VConversation? {
        do {
            let convId = try await ChatService.shared.createDirect(memberId: contact.userId)
            if let existing = directConversations.first(where: { $0.id == convId }) {
                return existing
            }
            let conv = VConversation(id: convId, type: .direct, title: contact.displayName,
                                     photoName: nil, lastMessagePreview: nil, lastMessageAt: nil,
                                     unreadCount: 0, peerUserId: contact.userId, photoURL: contact.photoURL)
            directConversations.insert(conv, at: 0)
            return conv
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t start chat."
            return nil
        }
    }

    /// Create a group conversation with `name` and the chosen contacts, insert it
    /// locally, and return it so the caller can navigate into it. Message E2E for
    /// groups (MLS) is a later increment — this wires the create + membership only.
    func createGroup(name: String, members: [VContact]) async -> VConversation? {
        do {
            let convId = try await ChatService.shared.createGroup(
                name: name, memberIds: members.map { $0.userId })
            if let existing = groupConversations.first(where: { $0.id == convId }) {
                return existing
            }
            let conv = VConversation(id: convId, type: .group, title: name,
                                     photoName: nil, lastMessagePreview: nil, lastMessageAt: nil,
                                     unreadCount: 0, memberCount: members.count + 1)
            groupConversations.insert(conv, at: 0)
            return conv
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t create group."
            return nil
        }
    }

    /// Open a conversation: show cached messages, then sync (fetch + decrypt-new) from server.
    func openConversation(_ conv: VConversation) {
        refresh(conv.id)
        Task { await syncMessages(conv) }
    }

    /// Pull from the server and decrypt any new messages, then refresh the UI.
    func syncMessages(_ conv: VConversation) async {
        guard conv.type == .direct else { return }   // group E2E (MLS) is a later increment
        do {
            let peer = try await peerUserId(for: conv)
            _ = try await ChatEngine.shared.sync(conversationId: conv.id, peerUserId: peer)
            refresh(conv.id)
            await ChatEngine.shared.markRead(conversationId: conv.id)   // blue ticks for the sender
            await fetchPresence(conv.id, peerUserId: peer)
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load messages."
        }
    }

    /// Resolve the peer + refresh presence (for the periodic poll while a chat is open).
    func refreshPresence(_ conv: VConversation) async {
        guard conv.type == .direct, let peer = try? await peerUserId(for: conv) else { return }
        await fetchPresence(conv.id, peerUserId: peer)
    }

    /// Fetch + apply the peer's online/last-seen presence to the conversation.
    func fetchPresence(_ convId: String, peerUserId: String) async {
        guard let st = try? await ChatService.shared.status(userId: peerUserId),
              let i = directConversations.firstIndex(where: { $0.id == convId }) else { return }
        directConversations[i].isOnline = st.online
        directConversations[i].lastSeenAt = st.lastSeen
    }

    /// Apply a delivery/read receipt (WS) to one of our sent messages → tick color.
    private func applyReceipt(messageId: String, status: String) {
        let newStatus: MessageStatus = status == "read" ? .read : .delivered
        for (cid, arr) in messagesByConversation {
            if let i = arr.firstIndex(where: { $0.id == messageId && $0.isMine }) {
                var copy = arr
                // Don't downgrade read→delivered.
                if !(copy[i].status == .read && newStatus == .delivered) {
                    copy[i].status = newStatus
                    messagesByConversation[cid] = copy
                }
                return
            }
        }
    }

    /// Rebuild a conversation's UI messages from the local (decrypted) store.
    private func refresh(_ convId: String) {
        let mapped = ChatEngine.shared.messages(conversationId: convId).map { d -> VMessage in
            let kind: MessageKind = d.media.map { $0.mime.hasPrefix("audio/") ? .voice : .image } ?? .text
            // Use the server id once known so read/delivery receipts can match it;
            // pending (offline/un-sent) messages show the clock tick.
            let status: MessageStatus = d.isMine ? (d.pending ? .sending : .sent) : .read
            return VMessage(id: d.serverId ?? d.id, conversationId: convId,
                            senderId: d.isMine ? "me" : d.senderId,
                            kind: kind, text: d.text, createdAt: d.createdAt,
                            status: status, isMine: d.isMine,
                            mediaRef: d.media)
        }
        if !mapped.isEmpty || messagesByConversation[convId] != nil {
            messagesByConversation[convId] = mapped
        }
        if let last = mapped.last {
            bumpPreview(convId, preview: last.kind == .text ? last.text : previewFor(last.kind))
        }
    }

    /// Send a media (image/voice) message: encrypt the blob on-device, upload the
    /// ciphertext to R2, and pack the key into the E2EE message (direct chats only).
    func sendMedia(_ data: Data, mime: String, caption: String = "", to conversationId: String) {
        let kind: MessageKind = mime.hasPrefix("audio/") ? .voice : .image
        let tempId = UUID().uuidString
        let msg = VMessage(id: tempId, conversationId: conversationId, senderId: "me",
                           kind: kind, text: caption, createdAt: .now, status: .sending, isMine: true)
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: previewFor(kind))

        guard let conv = directConversations.first(where: { $0.id == conversationId }) else {
            markStatus(tempId, in: conversationId, to: .sent)   // group: not supported yet
            return
        }
        Task {
            do {
                let peer = try await peerUserId(for: conv)
                _ = try await ChatEngine.shared.sendMedia(data, mime: mime, caption: caption,
                                                          conversationId: conversationId, peerUserId: peer)
                removeMessage(tempId, in: conversationId)
                refresh(conversationId)
            } catch {
                markStatus(tempId, in: conversationId, to: .failed)
                loadError = (error as? APIError)?.errorDescription ?? "Couldn’t send media."
            }
        }
    }

    /// Resolve (and cache) the peer user_id for a direct conversation.
    private func peerUserId(for conv: VConversation) async throws -> String {
        if let p = conv.peerUserId { return p }
        if let i = directConversations.firstIndex(where: { $0.id == conv.id }),
           let p = directConversations[i].peerUserId { return p }
        let resolved = try await ChatService.shared.resolvePeer(conversationId: conv.id)
        guard let peer = resolved.peerUserId else { throw APIError.http(status: 404, message: "no peer") }
        if let i = directConversations.firstIndex(where: { $0.id == conv.id }) {
            directConversations[i].peerUserId = peer
        }
        return peer
    }

    /// Send a real E2EE message in a direct chat (encrypt → /messages/send). Group
    /// chats keep a local echo only until MLS group messaging is wired.
    func send(_ text: String, kind: MessageKind = .text, to conversationId: String,
              replyTo: VMessage? = nil, forwarded: Bool = false) {
        let tempId = UUID().uuidString
        var msg = VMessage(id: tempId, conversationId: conversationId, senderId: "me",
                           kind: kind, text: text, createdAt: .now, status: .sending, isMine: true)
        msg.forwarded = forwarded
        if let r = replyTo {
            msg.replyToSender = r.isMine ? "You" : (r.senderName.isEmpty ? "" : r.senderName)
            msg.replyToText = r.kind == .text ? r.text : "Attachment"
        }
        guard let conv = directConversations.first(where: { $0.id == conversationId }) else {
            // Group (or unknown) — transient local echo only (group E2E/MLS not wired).
            messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
            bumpPreview(conversationId, preview: kind == .text ? text : previewFor(kind))
            markStatus(tempId, in: conversationId, to: .sent)
            return
        }

        guard kind == .text else {
            // Non-text via this path (rare, e.g. forwarded media) — transient echo.
            messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
            bumpPreview(conversationId, preview: previewFor(kind))
            return
        }

        // Text: persist as PENDING in the engine store NOW (instant + offline-visible),
        // then flush (send) in the background. The store is the single source of truth.
        _ = ChatEngine.shared.enqueueText(text, conversationId: conversationId)
        refresh(conversationId)
        bumpPreview(conversationId, preview: text)
        Task {
            guard let peer = try? await peerUserId(for: conv) else {
                loadError = "Couldn’t resolve the recipient."; return
            }
            await ChatEngine.shared.flushPending(conversationId: conversationId, peerUserId: peer)
            refresh(conversationId)
        }
    }

    // MARK: - Realtime (WebSocket) glue

    private var realtimeInstalled = false
    private func startRealtime() {
        guard !realtimeInstalled else { return }
        realtimeInstalled = true
        WebSocketClient.shared.onMessageRef = { [weak self] cid in
            Task { await self?.handleIncoming(cid) }
        }
        WebSocketClient.shared.onTyping = { [weak self] cid, _, isTyping in
            guard let self else { return }
            if isTyping { self.typingConversations.insert(cid) } else { self.typingConversations.remove(cid) }
        }
        WebSocketClient.shared.onReceipt = { [weak self] mid, status in
            self?.applyReceipt(messageId: mid, status: status)
        }
    }

    /// A message arrived (WS ref) — fetch + decrypt that conversation.
    private func handleIncoming(_ conversationId: String) async {
        if let conv = directConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv); return
        }
        // Unknown conversation (first message from a new contact) — load the list,
        // THEN sync that conversation so the message actually appears (not just on open).
        await loadConversations()
        if let conv = directConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv)
        }
    }

    private func markStatus(_ id: String, in convId: String, to status: MessageStatus) {
        guard var arr = messagesByConversation[convId], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].status = status
        messagesByConversation[convId] = arr
    }
    private func removeMessage(_ id: String, in convId: String) {
        messagesByConversation[convId]?.removeAll { $0.id == id }
    }

    private func previewFor(_ kind: MessageKind) -> String {
        switch kind {
        case .image: return "📷 Photo"
        case .voice: return "🎤 Voice message"
        case .document: return "📄 Document"
        default: return "Message"
        }
    }

    /// Forward a message to one or more conversations (with a Forwarded tag).
    func forward(_ message: VMessage, to conversationIds: [String]) {
        for cid in conversationIds {
            send(message.kind == .text ? message.text : message.text,
                 kind: message.kind == .poll ? .text : message.kind,
                 to: cid, forwarded: true)
        }
    }

    /// Delete a message. forEveryone=true leaves a "deleted" tombstone; otherwise removes it.
    func deleteMessage(_ messageId: String, in convId: String, forEveryone: Bool) {
        guard var arr = messagesByConversation[convId] else { return }
        if forEveryone {
            if let i = arr.firstIndex(where: { $0.id == messageId }) {
                arr[i].deletedForEveryone = true
                arr[i].reaction = nil
                withAnimation { messagesByConversation[convId] = arr }
            }
        } else {
            withAnimation { arr.removeAll { $0.id == messageId }; messagesByConversation[convId] = arr }
        }
        Haptics.rigid()
    }

    /// Delete an entire conversation from the list.
    func deleteConversation(_ convId: String) {
        withAnimation {
            directConversations.removeAll { $0.id == convId }
            groupConversations.removeAll { $0.id == convId }
            messagesByConversation[convId] = nil
        }
        Haptics.rigid()
    }

    /// Clear all messages in a conversation but keep it in the list.
    func clearChat(_ convId: String) {
        withAnimation { messagesByConversation[convId] = [] }
        if let i = directConversations.firstIndex(where: { $0.id == convId }) {
            directConversations[i].lastMessagePreview = nil
        } else if let i = groupConversations.firstIndex(where: { $0.id == convId }) {
            groupConversations[i].lastMessagePreview = nil
        }
        Haptics.rigid()
    }

    /// Toggle an emoji reaction on a message.
    func react(messageId: String, emoji: String, in convId: String) {
        guard var arr = messagesByConversation[convId],
              let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            arr[idx].reaction = (arr[idx].reaction == emoji) ? nil : emoji
            messagesByConversation[convId] = arr
        }
        Haptics.tap()
    }

    /// Send a poll into a conversation.
    func sendPoll(_ question: String, options: [String], to conversationId: String) {
        let poll = VPoll(id: UUID().uuidString, question: question,
                         options: options.map { .init(id: UUID().uuidString, text: $0, votes: 0) })
        let msg = VMessage(id: UUID().uuidString, conversationId: conversationId, senderId: "me",
                           kind: .poll, text: "Poll", createdAt: .now, status: .sent, isMine: true, poll: poll)
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: "📊 Poll: \(question)")
    }

    /// Register a vote on a poll option (single choice; toggles).
    func vote(messageId: String, optionId: String, in conversationId: String) {
        guard var arr = messagesByConversation[conversationId],
              let mi = arr.firstIndex(where: { $0.id == messageId }),
              var poll = arr[mi].poll else { return }
        for oi in poll.options.indices {
            if poll.options[oi].id == optionId { poll.options[oi].votes += 1 }
        }
        arr[mi].poll = poll
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            messagesByConversation[conversationId] = arr
        }
    }

    private func bumpPreview(_ convId: String, preview: String) {
        if let i = directConversations.firstIndex(where: { $0.id == convId }) {
            directConversations[i].lastMessagePreview = preview
            directConversations[i].lastMessageAt = .now
        } else if let i = groupConversations.firstIndex(where: { $0.id == convId }) {
            groupConversations[i].lastMessagePreview = preview
            groupConversations[i].lastMessageAt = .now
        }
    }
}

// MARK: - AI store

@MainActor
final class AIStore: ObservableObject {
    @Published var messages: [VAIMessage] = DummyData.aiMessages
    @Published var thinking = false

    func send(_ text: String) {
        messages.append(VAIMessage(id: UUID().uuidString, text: text, isUser: true))
        Task {
            thinking = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            thinking = false
            let canned = "Whats good? How can i Help you today?"
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                messages.append(VAIMessage(id: UUID().uuidString, text: canned, isUser: false))
            }
        }
    }
}

// MARK: - Clips store

@MainActor
final class ClipsStore: ObservableObject {
    @Published var clips: [VClip] = DummyData.clips
    @Published var comments: [VClipComment] = DummyData.clipComments

    func toggleLike(_ clip: VClip) {
        guard let i = clips.firstIndex(of: clip) else { return }
        clips[i].likes += 1
    }
    func addComment(_ text: String) {
        comments.insert(VClipComment(id: UUID().uuidString, authorName: "You", text: text), at: 0)
    }
}
