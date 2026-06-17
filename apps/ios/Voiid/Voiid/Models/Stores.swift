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
    @Published var directConversations: [VConversation] = DummyData.directConversations
    @Published var groupConversations: [VConversation] = DummyData.groupConversations
    @Published var messagesByConversation: [String: [VMessage]] = [:]
    @Published var typingConversations: Set<String> = []

    func messages(for id: String) -> [VMessage] {
        if let m = messagesByConversation[id] { return m }
        let isGroup = groupConversations.contains { $0.id == id }
        let seed = isGroup ? DummyData.groupMessages(for: id) : DummyData.messages(for: id)
        messagesByConversation[id] = seed
        return seed
    }

    /// Send a message. Simulates the full lifecycle locally: sent → delivered → read,
    /// then a typing indicator and an auto-reply — so ticks, timestamps and typing all animate.
    func send(_ text: String, kind: MessageKind = .text, to conversationId: String,
              replyTo: VMessage? = nil, forwarded: Bool = false) {
        let id = UUID().uuidString
        var msg = VMessage(id: id, conversationId: conversationId, senderId: "me",
                           kind: kind, text: text, createdAt: .now, status: .sending, isMine: true)
        msg.forwarded = forwarded
        if let r = replyTo {
            msg.replyToSender = r.isMine ? "You" : (r.senderName.isEmpty ? "" : r.senderName)
            msg.replyToText = r.kind == .text ? r.text : "Attachment"
        }
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: kind == .text ? text : previewFor(kind))

        // sent → delivered → read
        advance(id, in: conversationId, to: .sent, after: 0.3)
        advance(id, in: conversationId, to: .delivered, after: 1.0)
        advance(id, in: conversationId, to: .read, after: 2.2)

        // simulated reply with a typing indicator
        Task { await simulateReply(in: conversationId) }
    }

    private func previewFor(_ kind: MessageKind) -> String {
        switch kind {
        case .image: return "📷 Photo"
        case .voice: return "🎤 Voice message"
        case .document: return "📄 Document"
        default: return "Message"
        }
    }

    private func advance(_ messageId: String, in convId: String, to status: MessageStatus, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard var arr = self.messagesByConversation[convId],
                  let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                arr[idx].status = status
                if status == .delivered { arr[idx].deliveredAt = .now }
                if status == .read { arr[idx].readAt = .now; if arr[idx].deliveredAt == nil { arr[idx].deliveredAt = .now } }
                self.messagesByConversation[convId] = arr
            }
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

    private func simulateReply(in convId: String) async {
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        typingConversations.insert(convId)
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        typingConversations.remove(convId)
        let replies = ["Yoooo", "Haha nice", "Whats good?", "On my way", "👍", "Let's do it"]
        let reply = VMessage(id: UUID().uuidString, conversationId: convId, senderId: "u4",
                             text: replies.randomElement()!, createdAt: .now, isMine: false)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            messagesByConversation[convId, default: []].append(reply)
        }
        bumpPreview(convId, preview: reply.text)
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
