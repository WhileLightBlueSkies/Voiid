//
//  AIChatView.swift
//  Voiid AI — the conversation.
//
//  Ported from the reference app's `AI/AIChatScreen.swift`. The layout is the reference's;
//  what streams into it is a real on-device model (see AIModels.swift).
//
//  ── THE ASSISTANT'S MESSAGES ARE NOT BUBBLES ────────────────────────────────────
//  Yours are; the assistant's are plain text on the ground. That asymmetry is deliberate and
//  it is what every good assistant UI does: a bubble frames a message as one side of an
//  exchange between equals, and a wall of them makes long replies claustrophobic. Unframed
//  text reads as a document being written for you, which is what a reply actually is.
//
//  ── STOP IS ALWAYS REACHABLE WHILE STREAMING ────────────────────────────────────
//  The send button becomes a stop button the moment a reply starts. An assistant you cannot
//  interrupt is one you have to wait out, and the wait is exactly when you realise you asked
//  the wrong thing.
//

import SwiftUI

struct AIChatView: View {

    /// What to open with: a prompt to send on arrival, or a stored thread to restore.
    let opening: AIOpening
    /// Called when the transcript changes, so the hub can refresh its Recent list.
    var onFinish: () -> Void = {}

    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @StateObject private var chat: AIConversation
    @State private var draft = ""
    @FocusState private var writing: Bool

    private let bottomAnchor = "ai-bottom"

    init(opening: AIOpening, onFinish: @escaping () -> Void = {}) {
        self.opening = opening
        self.onFinish = onFinish
        // Restoring a thread has to happen HERE, not in `onAppear`: the id is what ties the
        // conversation to its stored row, and a conversation that started life with a fresh
        // UUID would save itself as a second thread on the first reply.
        if let threadID = opening.threadID {
            _chat = StateObject(wrappedValue: AIConversation(
                id: threadID,
                messages: AIStore.messages(in: threadID)))
        } else {
            _chat = StateObject(wrappedValue: AIConversation())
        }
    }

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if chat.messages.isEmpty && !chat.isThinking {
                    empty
                } else {
                    transcript
                }

                composer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            session.requestHideTabBar()
            // Persist whenever a turn settles, so a thread survives being backgrounded and
            // killed mid-conversation. Not per token: that would be a write per word.
            chat.onTranscriptSettled = {
                AIStore.save(chat)
                onFinish()
            }
            if !opening.prompt.isEmpty && chat.messages.isEmpty {
                chat.send(opening.prompt)
            }
        }
        .onDisappear {
            session.releaseHideTabBar()
            // Cancels any live stream and settles the last message, which triggers the save
            // above — so leaving mid-reply keeps what was written rather than losing it.
            chat.stop()
            AIStore.save(chat)
            onFinish()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(SoftPressStyle(scale: 0.97))
            .accessibilityLabel("Back")

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                Text("Voiid AI")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("New conversation", systemImage: "square.and.pencil") {
                    Haptics.tap()
                    // Save what is there before clearing it, or the thread the user just
                    // walked away from vanishes instead of landing in Recent.
                    AIStore.save(chat)
                    chat.reset()
                    onFinish()
                    dismiss()
                }
                Button("Copy transcript", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = chat.messages
                        .map { ($0.author == .user ? "You: " : "Voiid AI: ") + $0.text }
                        .joined(separator: "\n\n")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Conversation options")
        }
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.top, VoiidSpacing.sm)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: VoiidSpacing.md) {
            Spacer(minLength: 0)

            Image(systemName: "sparkles")
                .font(.system(size: 38))
                .foregroundColor(VoiidColor.accentInk)

            Text("Ask me anything")
                .font(VoiidFont.rounded(20, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("I run on your device. Nothing you type is sent anywhere.")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                // Suggestions the assistant can genuinely act on, unlike the reference's
                // ("Draft a reply to Kunal"), which assumed it could read the chat list.
                ForEach(["Help me write a message",
                         "Explain something to me",
                         "Plan my week"], id: \.self) { suggestion in
                    Button {
                        Haptics.tap()
                        chat.send(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(VoiidFont.rounded(14))
                            .foregroundColor(VoiidColor.textPrimary)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 42)
                            .background(Capsule().fill(VoiidColor.surfaceCard))
                            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                    }
                    .buttonStyle(SoftPressStyle(scale: 0.97))
                }
            }
            .padding(.top, VoiidSpacing.sm)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    ForEach(chat.messages) { message in
                        if message.author == .user {
                            userBubble(message)
                        } else {
                            assistantBlock(message)
                        }
                    }

                    if chat.isThinking { thinking }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.md)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            // Follows the stream. Without this a long reply types itself off the bottom
            // of the screen and you read the first line while it writes the fifth.
            .onChange(of: chat.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.count) {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private func userBubble(_ message: AIMessage) -> some View {
        HStack {
            Spacer(minLength: 48)

            Text(message.text)
                .font(VoiidFont.rounded(15))
                .foregroundColor(VoiidColor.textOnBubble)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VoiidSpacing.md - 2)
                .padding(.vertical, 11)
                .background(VoiidColor.bubbleSent)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                    bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous))
                .textSelection(.enabled)
        }
    }

    /// Unframed, with a small mark above it — see the file note on why this is not a bubble.
    private func assistantBlock(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                Text("Voiid AI")
                    .font(VoiidFont.rounded(11.5, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }

            if let failure = message.failure {
                // A failure is stated plainly, not dressed as an answer.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    Text(failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
            } else {
                Text(message.text)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !message.isStreaming {
                HStack(spacing: VoiidSpacing.md) {
                    if message.failure == nil {
                        action("doc.on.doc", "Copy") {
                            UIPasteboard.general.string = message.text
                        }
                    }
                    // Only on the LAST reply. Retrying an answer from the middle of a
                    // conversation would have to discard everything after it, which is not
                    // what a retry button appears to promise.
                    if message.id == chat.messages.last?.id {
                        action("arrow.clockwise", "Retry") { chat.retryLast() }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ icon: String, _ label: String,
                        _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            run()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(VoiidColor.textSecondary)
                .frame(width: 30, height: 26)
        }
        .buttonStyle(SoftPressStyle(scale: 0.97))
        .accessibilityLabel(label)
    }

    /// Three dots that breathe. Deliberately not a spinner: a spinner says "loading",
    /// these say "composing", and the difference sets the right expectation about the wait.
    private var thinking: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(VoiidColor.accentInk)
                    .frame(width: 6, height: 6)
                    .opacity(0.35)
                    .phaseAnimator([false, true]) { dot, on in
                        dot.opacity(on ? 1 : 0.3).scaleEffect(on ? 1.2 : 0.85)
                    } animation: { _ in
                        .easeInOut(duration: 0.45).delay(Double(i) * 0.13)
                    }
            }
        }
        .frame(height: 20)
        .accessibilityLabel("Voiid AI is composing a reply")
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                TextField("Ask anything", text: $draft, axis: .vertical)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .lineLimit(1...5)
                    .focused($writing)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 12)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(VoiidColor.fieldBorder, lineWidth: 1))

            // Send becomes Stop while a reply streams — see the file note.
            Button {
                Haptics.tap()
                if chat.isBusy {
                    chat.stop()
                } else {
                    chat.send(draft)
                    draft = ""
                }
            } label: {
                Image(systemName: chat.isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: chat.isBusy ? 14 : 16, weight: .bold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(VoiidColor.accent))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SoftPressStyle(scale: 0.97))
            .disabled(!chat.isBusy && trimmedDraft.isEmpty)
            .opacity(chat.isBusy || !trimmedDraft.isEmpty ? 1 : 0.4)
            .accessibilityLabel(chat.isBusy ? "Stop" : "Send")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.bar)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
