//
//  LudoChatSheet.swift
//  Voiid
//
//  In-game chat + emotes (§11.4): a 45%-height sheet with the current conversation's last 20
//  game-context messages and one row of eight text emoji reactions.
//
//  THE SHEET NEVER PAUSES THE CLOCK. Messages ride the EXISTING E2EE chat pipe — ChatEngine
//  holds only decrypted local copies — and carry a compact `gameContext` marker (match id)
//  inside the encrypted body; the games server never receives their plaintext. Closed-state
//  unread is a small accent dot, not a coin badge. Emote sends are rate-limited to ONE per
//  second locally (the chat service enforces its own floor).
//

import SwiftUI

enum LudoGameContextMarker {
    static let prefix = "\nvoiid:gamework/"

    static func embed(_ body: String, matchId: String) -> String { body + prefix + matchId }
    static func strip(_ text: String) -> String {
        if let range = text.range(of: prefix) { return String(text[..<range.lowerBound]) }
        return text
    }
}

struct LudoChatSheet: View {
    let matchId: String
    let conversationId: String
    let onDismiss: () -> Void

    @State private var lastSendAt: Date = .distantPast

    /// Last 20 REAL messages of THIS conversation, straight from the local decrypted store.
    private var messages: [DecryptedMessage] {
        ChatEngine.shared.messages(conversationId: conversationId).suffix(20)
    }

    private let emojis = ["👏", "😂", "😮", "😢", "🔥", "🍀", "🎲", "🏆"]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Chat")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Spacer()
                Button("Done") { onDismiss() }
                    .font(VoiidFont.rounded(14, .semibold))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages, id: \.id) { m in
                        Text(LudoGameContextMarker.strip(m.text))
                            .font(VoiidFont.rounded(13))
                            .lineLimit(4)
                            .truncationMode(.tail)
                            .foregroundStyle(VoiidColor.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Eight text emoji reactions — no gifts, no animated sticker economy (§11.4).
            HStack(spacing: 0) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        send(emoji)
                    } label: {
                        Text(emoji).font(.system(size: 20))
                            .frame(maxWidth: .infinity, minHeight: 44)   // 44pt targets (§8.2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedCorners(radius: 20)
                .fill(VoiidColor.surfaceCard)
                .ignoresSafeArea(edges: .bottom))
        .presentationDetentsCompat(heightFraction: 0.45)
    }

    private func send(_ emoji: String) {
        // ONE per second locally (§11.4); the chat service enforces its own rate.
        guard Date().timeIntervalSince(lastSendAt) >= 1 else { return }
        lastSendAt = Date()
        Task.detached {
            _ = try? await ChatEngine.shared.sendText(
                LudoGameContextMarker.embed(emoji, matchId: matchId),
                conversationId: conversationId,
                peerUserId: "")
        }
    }
}

private struct RoundedCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect,
                          byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

extension View {
    @ViewBuilder
    func presentationDetentsCompat(heightFraction: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.fraction(heightFraction)])
        } else {
            self
        }
    }
}
