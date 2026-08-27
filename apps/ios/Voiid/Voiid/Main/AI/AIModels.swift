//
//  AIModels.swift
//  Voiid AI — the hub's tools, conversations, and the reply engine.
//
//  Ported from the reference app's `AI/AIModels.swift`, with the scripted engine replaced
//  by real on-device inference. The reference's types (AITool, AIMessage, AIThread) are
//  carried over as-is; `AIConversation` keeps its shape and its timing but now streams from
//  Apple's Foundation Models instead of a keyword table.
//
//  ── WHY ON-DEVICE, AND WHY THAT IS NOT A COMPROMISE ─────────────────────────────
//  The hub promises "I can see your chats, Spaces and events". Delivering that with a cloud
//  model would mean posting decrypted message text to someone else's server — which is
//  precisely the thing this app exists to avoid, and would make a liar of the first golden
//  rule in the README. Apple's SystemLanguageModel runs in-process on the phone, so the
//  transcript never leaves the device and the E2EE guarantee is untouched.
//
//  ── THE SCRIPT DID NOT GO AWAY ──────────────────────────────────────────────────
//  Foundation Models needs iOS 26, an eligible device, and Apple Intelligence switched on.
//  Plenty of real users will have none of those, and the app's deployment target is iOS 18.
//  So the reference's scripted replies remain as the fallback path, VERBATIM — see
//  `ScriptedReplies`. A user on an older phone gets the same assistant the reference
//  demonstrated rather than an error, and nobody sees a dead tab.
//

import Foundation
import SwiftUI
// `ObservableObject` and `@Published` come from Combine. SwiftUI re-exports them on some
// SDK configurations and not others, so relying on that is why this compiled locally and
// failed here — the import makes it explicit rather than incidental.
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Tools

/// One capability on the hub. Tapping it starts a conversation with its opening prompt
/// already sent, which is the whole point of a hub: skip the blank page.
struct AITool: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    /// What gets sent on the user's behalf when the card is tapped.
    let openingPrompt: String
    /// Marks the two or three worth a larger card.
    var isFeatured: Bool = false

    static let all: [AITool] = [
        .init(id: "summarise", title: "Catch me up",
              subtitle: "Summarise what you missed",
              icon: "text.line.first.and.arrowtriangle.forward",
              openingPrompt: "Catch me up on what I missed today.",
              isFeatured: true),
        .init(id: "draft", title: "Draft a reply",
              subtitle: "Say the hard thing well",
              icon: "square.and.pencil",
              openingPrompt: "Help me draft a reply.",
              isFeatured: true),
        .init(id: "plan", title: "Plan something",
              subtitle: "Trips, events, group plans",
              icon: "calendar.badge.clock",
              openingPrompt: "Help me plan something with my group."),
        .init(id: "translate", title: "Translate",
              subtitle: "Any message, any language",
              icon: "globe",
              openingPrompt: "Translate a message for me."),
        .init(id: "image", title: "Make an image",
              subtitle: "Describe it, get it",
              icon: "photo.on.rectangle.angled",
              openingPrompt: "Generate an image for me."),
        .init(id: "transcribe", title: "Transcribe",
              subtitle: "Voice notes into text",
              icon: "waveform",
              openingPrompt: "Transcribe a voice note."),
    ]
}

// MARK: - Messages

struct AIMessage: Identifiable, Hashable {
    enum Author: String, Hashable {
        case user
        case assistant
    }

    let id: String
    let author: Author
    /// Mutated as the reply streams in.
    var text: String
    var createdAt: Date = Date()
    /// True while the assistant is composing this message.
    var isStreaming: Bool = false
    /// Set when generation failed. Rendered in place of the text, and never persisted as
    /// if it were a real answer.
    var failure: String?
}

/// A saved thread, for the hub's Recent list.
///
/// Unlike the reference — where this was sample data and tapping a row opened a blank
/// screen — every row here is a real stored conversation that reopens where it left off.
struct AIThread: Identifiable, Hashable {
    let id: String
    var title: String
    var preview: String
    var updatedAt: Date
    var icon: String

    /// "2h ago" / "Yesterday" / "12 Aug", matching the reference's `age` column.
    var age: String { RelativeAge.string(for: updatedAt) }
}

enum RelativeAge {
    static func string(for date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}

// MARK: - Availability

/// Why the on-device model can or cannot answer right now.
///
/// Kept as a value rather than a Bool so the UI can say something TRUE about the reason —
/// "turn on Apple Intelligence" and "this iPhone can't run it" need different words, and
/// "still downloading" is not a failure at all.
enum AIAvailability: Equatable {
    case ready
    case osTooOld
    case deviceNotEligible
    case appleIntelligenceOff
    case modelDownloading

    /// True when a real model will answer. Everything else falls back to the script.
    var isReady: Bool { self == .ready }

    /// Shown under the greeting when the model cannot run. `nil` when it can.
    var notice: String? {
        switch self {
        case .ready:                return nil
        case .osTooOld:             return "Update to iOS 26 for on-device answers. Until then I'll use my built-in replies."
        case .deviceNotEligible:    return "This iPhone can't run the on-device model, so I'll use my built-in replies."
        case .appleIntelligenceOff: return "Turn on Apple Intelligence in Settings for on-device answers."
        case .modelDownloading:     return "The on-device model is still downloading. I'll use my built-in replies until it's ready."
        }
    }

    static var current: AIAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceOff
            case .unavailable(.modelNotReady):
                return .modelDownloading
            @unknown default:
                return .deviceNotEligible
            }
        }
        #endif
        return .osTooOld
    }
}

// MARK: - Conversation

/// One AI conversation: the transcript, the streaming state, and the engine behind it.
@MainActor
final class AIConversation: ObservableObject {

    /// Stable id for the whole thread, so persistence can update in place.
    let id: String

    @Published var messages: [AIMessage] = []
    /// True between sending and the first word of the reply.
    @Published private(set) var isThinking = false

    /// Set once at init. The engine cannot change under a live conversation.
    let availability: AIAvailability

    private var streamTask: Task<Void, Never>?
    /// Rebuilt lazily and torn down on `reset()`. Holding it across turns is what gives the
    /// model memory of the conversation so far.
    private var backend: AIBackend?

    /// Called whenever the transcript settles, so the owner can persist it. Not called on
    /// every streamed token — see `AIChatView`.
    var onTranscriptSettled: (() -> Void)?

    init(id: String = UUID().uuidString,
         messages: [AIMessage] = [],
         availability: AIAvailability = .current) {
        self.id = id
        self.messages = messages
        self.availability = availability
    }

    var isBusy: Bool { isThinking || messages.last?.isStreaming == true }

    /// A title for the Recent list: the first thing the user actually said, trimmed.
    var derivedTitle: String {
        guard let first = messages.first(where: { $0.author == .user })?.text else {
            return "New conversation"
        }
        let oneLine = first.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= 42 ? oneLine : String(oneLine.prefix(41)) + "…"
    }

    var derivedPreview: String {
        guard let last = messages.last else { return "" }
        let oneLine = last.text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= 80 ? oneLine : String(oneLine.prefix(79)) + "…"
    }

    func reset() {
        streamTask?.cancel()
        streamTask = nil
        backend = nil
        messages = []
        isThinking = false
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        messages.append(AIMessage(id: UUID().uuidString, author: .user, text: trimmed))
        respond(to: trimmed)
    }

    /// Re-runs the last user turn, discarding the assistant answer that followed it.
    func retryLast() {
        guard !isBusy else { return }
        guard let lastUser = messages.lastIndex(where: { $0.author == .user }) else { return }
        let prompt = messages[lastUser].text
        // Drop everything after that turn — the model is about to replace it, and leaving
        // the old answer visible while a new one streams in below reads as two replies.
        messages.removeSubrange((lastUser + 1)...)
        // The session remembers the answer we just discarded, so it has to go too;
        // otherwise the retry is conditioned on the very text we are trying to replace.
        backend = nil
        respond(to: prompt)
    }

    private func respond(to prompt: String) {
        streamTask?.cancel()
        isThinking = true

        streamTask = Task { [weak self] in
            guard let self else { return }

            // A beat before the first word. Long enough to read as consideration, short
            // enough that it never feels like the app has hung. The reference introduced
            // this to sell a canned reply; it survives because a real model's first token
            // can land almost instantly, and an answer that appears with no pause at all
            // reads as a lookup rather than a response.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }

            if self.availability.isReady, #available(iOS 26.0, *) {
                await self.streamFromModel(prompt)
            } else {
                await self.streamScripted(prompt)
            }
        }
    }

    // MARK: Real inference

    @available(iOS 26.0, *)
    private func streamFromModel(_ prompt: String) async {
        #if canImport(FoundationModels)
        let session: LanguageModelSession
        if let existing = backend?.session {
            session = existing
        } else {
            session = LanguageModelSession(instructions: Self.instructions)
            backend = AIBackend(session: session)
        }

        let id = UUID().uuidString
        var opened = false

        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                guard !Task.isCancelled else { return }

                // The first token is the moment to swap the dots for a bubble. Doing it
                // before this point leaves an empty block on screen while the model warms up.
                if !opened {
                    isThinking = false
                    messages.append(AIMessage(id: id, author: .assistant,
                                              text: "", isStreaming: true))
                    opened = true
                }

                guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
                // ASSIGN, do not append. Each snapshot carries the whole generation so far,
                // not the delta since the last one — appending concatenates the reply into
                // itself and the text grows quadratically.
                messages[i].content = snapshot.content
            }
        } catch {
            isThinking = false
            let message = Self.describe(error)
            if let i = messages.firstIndex(where: { $0.id == id }) {
                // Partial text is worse than none: it stops mid-sentence and reads as an
                // answer. Replace it with the reason.
                messages[i].text = ""
                messages[i].isStreaming = false
                messages[i].failure = message
            } else {
                messages.append(AIMessage(id: id, author: .assistant, text: "",
                                          isStreaming: false, failure: message))
            }
            onTranscriptSettled?()
            return
        }

        guard !Task.isCancelled else { return }
        isThinking = false
        if let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].isStreaming = false
        }
        onTranscriptSettled?()
        #endif
    }

    /// What the assistant is told about itself, once per session.
    ///
    /// It is deliberately narrow. A general chatbot in a messaging app is a novelty; one
    /// that knows what a Space is and refuses to invent your messages is a feature. The
    /// honesty clause matters most — the model cannot actually read the transcript yet, and
    /// an assistant that cheerfully makes up what your friends said is worse than useless.
    private static let instructions = """
        You are Voiid AI, the assistant built into Voiid — a private, end-to-end-encrypted \
        messaging app. You run entirely on this device; nothing the user tells you is sent \
        to a server.

        Help with the things people use a messaging app for: summarising conversations they \
        paste in, drafting and rewriting replies, planning with a group, translating, and \
        explaining. Voiid's own vocabulary: a Space is a community, Clips are short videos, \
        Memories are disappearing posts.

        Be concise and concrete — a few sentences unless asked for more. Write in plain \
        prose without markdown headers or bullet symbols; this is a chat bubble, not a \
        document.

        Never invent the contents of the user's chats, messages, or contacts. You cannot see \
        them. If you are asked about something specific in their conversations, say plainly \
        that you cannot read them and ask them to paste the part they mean.
        """

    private static func describe(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return "This conversation got too long for me to hold in memory. Start a new one and I'll be fresh."
            case .guardrailViolation:
                return "I can't help with that one."
            case .unsupportedLanguageOrLocale:
                return "I can't work in that language on-device yet."
            default:
                break
            }
        }
        #endif
        return "Something went wrong while I was answering. Try again."
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isThinking = false
        if let i = messages.indices.last, messages[i].isStreaming {
            messages[i].isStreaming = false
            // A stop before the first word leaves an empty bubble, which reads as a bug.
            if messages[i].text.isEmpty { messages.remove(at: i) }
        }
        onTranscriptSettled?()
    }

    // MARK: Fallback

    /// The reference app's engine, unchanged: word-by-word emission of a keyword-matched
    /// reply. Used whenever the on-device model is unavailable.
    private func streamScripted(_ prompt: String) async {
        // The reference paused 650ms total; 320ms of it has already elapsed above.
        try? await Task.sleep(for: .milliseconds(330))
        guard !Task.isCancelled else { return }

        isThinking = false
        let id = UUID().uuidString
        messages.append(AIMessage(id: id, author: .assistant, text: "", isStreaming: true))

        // Word by word, not character by character. Characters look like a teletype;
        // words look like something composing a thought.
        let reply = ScriptedReplies.reply(for: prompt)
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 28...62)))
            guard !Task.isCancelled else { return }
            guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[i].text += (messages[i].text.isEmpty ? "" : " ") + word
        }

        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].isStreaming = false
        onTranscriptSettled?()
    }
}

/// Holds the live model session. A tiny box so `AIConversation` can be compiled and tested
/// on an SDK without FoundationModels, where the property simply never gets set.
private final class AIBackend {
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    var session: LanguageModelSession? {
        get { _session as? LanguageModelSession }
        set { _session = newValue }
    }
    private var _session: Any?

    @available(iOS 26.0, *)
    init(session: LanguageModelSession) { self._session = session }
    #else
    init() {}
    #endif
}

private extension AIMessage {
    /// Assigns a streamed snapshot. Isolated here so the FoundationModels import stays out
    /// of the model's own declaration.
    var content: String {
        get { text }
        set { text = newValue }
    }
}

// MARK: - The script

/// The reference app's canned replies, kept verbatim as the no-model fallback.
///
/// Deliberately about Voiid rather than the world at large: an assistant tab that answers
/// trivia could be any app's; one that knows what a Space is belongs to this one.
enum ScriptedReplies {

    static func reply(for prompt: String) -> String {
        let p = prompt.lowercased()

        if p.contains("catch me up") || p.contains("missed") || p.contains("summar") {
            return """
            I can summarise a conversation for you — paste the part you want condensed and \
            I'll pull out what was decided, what's still open, and anything that needs you. \
            I can't read your chats directly, so I only ever work from what you show me.
            """
        }
        if p.contains("draft") || p.contains("reply") || p.contains("write") {
            return """
            Tell me what you're replying to and roughly what you want to say — the gist is \
            enough. I'll write it so it's honest without being blunt, and you can ask for it \
            warmer, shorter, or more formal from there.
            """
        }
        if p.contains("plan") || p.contains("trip") || p.contains("event") {
            return """
            Let's start with the constraints: how many people, and what does everyone's week \
            look like? Once I know when people genuinely can't make it, the options usually \
            narrow to one or two — and then it's just a matter of who confirms first.
            """
        }
        if p.contains("translate") {
            return """
            Paste the message and tell me the language you want. I'll keep the tone rather \
            than translating word for word — a formal message shouldn't come out casual just \
            because the vocabulary matched.
            """
        }
        if p.contains("image") || p.contains("generate") || p.contains("picture") {
            return """
            I can't make images yet. Describe what you're after and I'll write you a prompt \
            precise enough to use elsewhere — subject, mood, framing and where it'll be used, \
            since a profile picture and a Space header want quite different shapes.
            """
        }
        if p.contains("transcribe") || p.contains("voice") {
            return """
            I can't listen to audio yet. If you have a transcript already, paste it and I'll \
            clean it up, summarise it, or pull out the actions.
            """
        }
        if p.contains("hello") || p.contains("hi ") || p == "hi" || p.contains("hey") {
            return "Hey. What are we working on?"
        }

        return """
        I can work with that. Give me a bit more to go on — what you're trying to achieve, \
        and who it's for. The more specific you are, the less I have to guess.
        """
    }
}
