//
//  MessageActionsOverlay.swift
//  Voiid
//
//  iMessage/WhatsApp-style long-press overlay: dim+blur backdrop, the bubble
//  lifts, a floating reaction pill appears above it and an action list below.
//  Spring animation + haptics.
//

import SwiftUI

struct MessageAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var destructive = false
    let run: () -> Void
}

struct MessageActionsOverlay<Bubble: View>: View {
    let isMine: Bool
    let reactions: [String]
    let onReact: (String) -> Void
    let actions: [MessageAction]
    let bubble: Bubble
    let onDismiss: () -> Void

    @State private var appear = false

    init(isMine: Bool, reactions: [String], onReact: @escaping (String) -> Void,
         actions: [MessageAction], onDismiss: @escaping () -> Void,
         @ViewBuilder bubble: () -> Bubble) {
        self.isMine = isMine; self.reactions = reactions; self.onReact = onReact
        self.actions = actions; self.onDismiss = onDismiss; self.bubble = bubble()
    }

    var body: some View {
        ZStack {
            // Dim + blur backdrop
            Rectangle().fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(appear ? 1 : 0)
                .onTapGesture { close() }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 12) {
                reactionPill
                    .scaleEffect(appear ? 1 : 0.6, anchor: .bottom)
                    .opacity(appear ? 1 : 0)

                bubble
                    .scaleEffect(appear ? 1 : 0.96)
                    .shadow(color: .black.opacity(appear ? 0.18 : 0), radius: 18, y: 8)

                actionCard
                    .scaleEffect(appear ? 1 : 0.9, anchor: .top)
                    .opacity(appear ? 1 : 0)
            }
            .frame(maxWidth: 320, alignment: isMine ? .trailing : .leading)
            .padding(.horizontal, VoiidSpacing.lg)
        }
        .onAppear {
            Haptics.rigid()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { appear = true }
        }
    }

    private var reactionPill: some View {
        HStack(spacing: 10) {
            ForEach(reactions, id: \.self) { e in
                Button {
                    Haptics.tap(); onReact(e); close()
                } label: { Text(e).font(.system(size: 30)) }
                .buttonStyle(BouncyEmoji())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(VoiidColor.surfaceCard)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var actionCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                Button {
                    Haptics.tap(); a.run(); close()
                } label: {
                    HStack {
                        Text(a.title).font(VoiidFont.rounded(16, .regular))
                        Spacer()
                        Image(systemName: a.icon).font(.system(size: 17))
                    }
                    .foregroundColor(a.destructive ? VoiidColor.error : VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                if i < actions.count - 1 {
                    Divider().background(VoiidColor.divider.opacity(0.3)).padding(.leading, VoiidSpacing.md)
                }
            }
        }
        .frame(width: 230)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDismiss() }
    }
}

private struct BouncyEmoji: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.4 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}
