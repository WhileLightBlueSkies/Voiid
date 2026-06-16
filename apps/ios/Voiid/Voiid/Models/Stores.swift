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
    @Published var route: Route = .onboarding
    @Published var profile = DummyData.me
    /// Hides the bottom tab bar when a full-screen child (e.g. a chat) is open.
    @Published var hideTabBar = false

    func completeOnboarding() {
        withAnimation(.easeInOut) { route = .main }
    }
    func signOut() {
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
    func send(_ text: String, kind: MessageKind = .text, to conversationId: String) {
        let id = UUID().uuidString
        var msg = VMessage(id: id, conversationId: conversationId, senderId: "me",
                           kind: kind, text: text, createdAt: .now, status: .sending, isMine: true)
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: kind == .text ? text : previewFor(kind))

        // sent → delivered → read
        advance(id, in: conversationId, to: .sent, after: 0.3)
        advance(id, in: conversationId, to: .delivered, after: 1.0)
        advance(id, in: conversationId, to: .read, after: 2.2)

        // simulated reply with a typing indicator
        Task { await simulateReply(in: conversationId) }
        _ = msg
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
                self.messagesByConversation[convId] = arr
            }
        }
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
