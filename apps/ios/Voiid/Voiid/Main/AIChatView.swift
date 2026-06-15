//
//  AIChatView.swift
//  Voiid
//
//  In-app AI assistant (Figma Screen-8). ChatGPT-style conversation on dummy responses.
//  User bubbles right (#C8C8C8), AI bubbles left (#FCF4F8), with a "thinking" indicator.
//

import SwiftUI

struct AIChatView: View {
    @EnvironmentObject var ai: AIStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: VoiidSpacing.sm) {
                        ForEach(ai.messages) { m in
                            aiBubble(m).id(m.id)
                        }
                        if ai.thinking { TypingBubble().id("thinking") }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, VoiidSpacing.md)
                }
                .onChange(of: ai.messages.count) { _, _ in withAnimation { proxy.scrollTo(ai.messages.last?.id, anchor: .bottom) } }
                .onChange(of: ai.thinking) { _, v in if v { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } } }
            }
            inputBar
        }
        .background(VoiidColor.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundColor(VoiidColor.primary)
            Text("Voiid AI").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
        .background(.ultraThinMaterial).overlay(Divider(), alignment: .bottom)
    }

    private func aiBubble(_ m: VAIMessage) -> some View {
        HStack {
            if m.isUser { Spacer(minLength: 40) }
            Text(m.text)
                .font(VoiidFont.body).foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                .background(m.isUser ? VoiidColor.bubbleSent : VoiidColor.bubbleReceived)
                .clipShape(BubbleShape(isMine: m.isUser))
            if !m.isUser { Spacer(minLength: 40) }
        }
        .transition(.scale(scale: 0.85, anchor: m.isUser ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: VoiidSpacing.sm) {
                TextField("Ask Voiid AI…", text: $draft, axis: .vertical)
                    .font(VoiidFont.body).lineLimit(1...4)
                    .padding(.horizontal, VoiidSpacing.md).frame(minHeight: 44)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.pill).stroke(VoiidColor.fieldBorder))
                Button {
                    let t = draft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    Haptics.tap(); ai.send(t); draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundColor(VoiidColor.primary)
                }
            }
            .padding(.horizontal, VoiidSpacing.sm).padding(.vertical, VoiidSpacing.sm)
            .padding(.bottom, 80)
            .background(.ultraThinMaterial)
        }
    }
}
